#!/bin/bash
#
# Build the double-clickable installer, DCP-T420W-<version>.pkg.
#
# This is a build tool, not the installer: what ships to users is the .pkg it
# produces. Everything is compiled universal (arm64 + x86_64) so one package
# works on both Apple Silicon and Intel.
#
#   ./packaging/build-pkg.sh [version]
#
set -euo pipefail

VERSION="${1:-1.3.0}"
IDENTIFIER="com.hwisu.dcp-t420w"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HERE/build"

# Stage the payload on the boot volume rather than in the repo, so build output
# never lands in the working tree and ownership behaves on volumes mounted
# "noowners".
#
# lsbom will show "._" siblings for every file. Those are AppleDouble encodings
# of com.apple.provenance, which macOS attaches to executables and will not let
# you delete. They are not installed as files -- `installer` merges them back
# into extended attributes. Verified with `pkgutil --expand-full`, which yields
# exactly the three payload files and no "._" entries.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dcpt420w.XXXXXX")"
PAYLOAD="$STAGE/payload"
trap 'rm -rf "$STAGE"' EXIT

echo "Building Brother DCP-T420W driver $VERSION"

rm -rf "$BUILD"
mkdir -p "$BUILD"
mkdir -p "$PAYLOAD/usr/libexec/cups/filter" \
         "$PAYLOAD/usr/local/bin" \
         "$PAYLOAD/usr/local/libexec" \
         "$PAYLOAD/Library/Printers/PPDs/Contents/Resources"

# The sharing component has its own payload: the LaunchDaemon plist, installed
# only when the box is ticked so that an unticked install leaves nothing behind
# in /Library/LaunchDaemons.
SHARE_PAYLOAD="$STAGE/share-payload"
mkdir -p "$SHARE_PAYLOAD/Library/LaunchDaemons"

# --- 1. Print filter -------------------------------------------------------
echo "  building rastertobrother (universal)"
make -s -C "$HERE/filter" clean >/dev/null
make -s -C "$HERE/filter" >/dev/null
ditto --norsrc --noextattr --noacl \
    "$HERE/filter/rastertobrother" "$PAYLOAD/usr/libexec/cups/filter/rastertobrother"

# --- 2. Scanner client -----------------------------------------------------
echo "  building brscan (universal)"
swiftc -O -target arm64-apple-macos11  "$HERE/scanner/brscan.swift" -o "$STAGE/brscan-arm64"
swiftc -O -target x86_64-apple-macos11 "$HERE/scanner/brscan.swift" -o "$STAGE/brscan-x86_64"
lipo -create -output "$PAYLOAD/usr/local/bin/brscan" \
     "$STAGE/brscan-arm64" "$STAGE/brscan-x86_64"
rm -f "$STAGE/brscan-arm64" "$STAGE/brscan-x86_64"

# --- 3. AirPrint advertiser ------------------------------------------------
echo "  building brairprint (universal)"
make -s -C "$HERE/airprint" clean >/dev/null
make -s -C "$HERE/airprint" >/dev/null
ditto --norsrc --noextattr --noacl \
    "$HERE/airprint/brairprint" "$PAYLOAD/usr/local/libexec/brairprint"
ditto --norsrc --noextattr --noacl \
    "$HERE/packaging/launchd/com.hwisu.dcp-t420w.airprint.plist" \
    "$SHARE_PAYLOAD/Library/LaunchDaemons/com.hwisu.dcp-t420w.airprint.plist"

# --- 4. PPD ----------------------------------------------------------------
echo "  generating PPD"
python3 "$HERE/scripts/genppd.py" > "$PAYLOAD/Library/Printers/PPDs/Contents/Resources/Brother DCP-T420W.ppd"

chmod 0755 "$PAYLOAD/usr/libexec/cups/filter/rastertobrother" \
           "$PAYLOAD/usr/local/bin/brscan" \
           "$PAYLOAD/usr/local/libexec/brairprint"
chmod 0644 "$SHARE_PAYLOAD/Library/LaunchDaemons/com.hwisu.dcp-t420w.airprint.plist"
chmod 0644 "$PAYLOAD/Library/Printers/PPDs/Contents/Resources/Brother DCP-T420W.ppd"

# Drop what extended attributes we can (quarantine in particular).
# com.apple.provenance is system-managed and survives this; see the note above.
/usr/bin/xattr -rc "$PAYLOAD" "$SHARE_PAYLOAD" 2>/dev/null || true
find "$PAYLOAD" "$SHARE_PAYLOAD" -name '._*' -delete 2>/dev/null || true

# --- 5. Package ------------------------------------------------------------
echo "  pkgbuild"
pkgbuild --root "$PAYLOAD" \
         --scripts "$HERE/packaging/scripts" \
         --identifier "$IDENTIFIER" \
         --version "$VERSION" \
         --install-location / \
         --ownership recommended \
         "$STAGE/component.pkg" >/dev/null

# A second component, carrying the LaunchDaemon plist and the script that
# switches sharing on. It is separate so the installer can offer it as a tick
# box: unticked, neither the plist nor the CUPS settings are touched, which is
# why none of this can live in the main postinstall.
pkgbuild --root "$SHARE_PAYLOAD" \
         --scripts "$HERE/packaging/scripts-sharing" \
         --identifier "$IDENTIFIER.sharing" \
         --version "$VERSION" \
         --install-location / \
         --ownership recommended \
         "$STAGE/sharing.pkg" >/dev/null

sed "s/VERSION/$VERSION/" "$HERE/packaging/distribution.xml" > "$STAGE/distribution.xml"

echo "  productbuild"
productbuild --distribution "$STAGE/distribution.xml" \
             --resources "$HERE/packaging/resources" \
             --package-path "$STAGE" \
             "$BUILD/DCP-T420W-$VERSION.pkg" >/dev/null


echo
echo "Built $BUILD/DCP-T420W-$VERSION.pkg"
echo
echo "The package is unsigned (that needs a paid Developer ID Installer"
echo "certificate), so Gatekeeper will object to a double-click. Either:"
echo "  right-click the .pkg > Open,  or"
echo "  sudo installer -pkg \"$BUILD/DCP-T420W-$VERSION.pkg\" -target /"
