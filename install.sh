#!/bin/bash
#
# Install the Brother DCP-T420W driver: the rastertobrother filter, the PPD,
# and (unless --no-queue) a print queue pointing at the printer.
#
# Run as root:  sudo ./install.sh
#
# Options:
#   --uri URI     device URI to use instead of auto-discovery
#   --name NAME   queue name (default Brother_DCP_T420W)
#   --no-queue    install the driver files only
#

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FILTER_DIR="/usr/libexec/cups/filter"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
PPD_NAME="Brother DCP-T420W.ppd"

QUEUE="Brother_DCP_T420W"
URI=""
MAKE_QUEUE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --uri)      URI="$2"; shift 2 ;;
    --name)     QUEUE="$2"; shift 2 ;;
    --no-queue) MAKE_QUEUE=0; shift ;;
    -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
    *)          echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "This installer needs root to write to $FILTER_DIR." >&2
  echo "Re-run it as: sudo $0 $*" >&2
  exit 1
fi

say() { printf '  %s\n' "$1"; }

echo "Brother DCP-T420W driver installer"

# ---------------------------------------------------------------------------
# 1. Filter
# ---------------------------------------------------------------------------
if [ ! -x "$HERE/filter/rastertobrother" ]; then
  say "Building rastertobrother..."
  make -C "$HERE/filter" >/dev/null || make -C "$HERE/filter" native >/dev/null
fi

install -o root -g wheel -m 0755 \
        "$HERE/filter/rastertobrother" "$FILTER_DIR/rastertobrother"
say "Filter  -> $FILTER_DIR/rastertobrother"

# ---------------------------------------------------------------------------
# 2. PPD
# ---------------------------------------------------------------------------
install -d -o root -g wheel -m 0755 "$PPD_DIR"
install -o root -g wheel -m 0644 \
        "$HERE/ppd/Brother-DCP-T420W.ppd" "$PPD_DIR/$PPD_NAME"
say "PPD     -> $PPD_DIR/$PPD_NAME"

# cupstestppd now resolves the filter, so this should come back clean.
if ! cupstestppd -q "$PPD_DIR/$PPD_NAME"; then
  echo "WARNING: cupstestppd reported problems with the PPD." >&2
fi

# ---------------------------------------------------------------------------
# 3. Queue
# ---------------------------------------------------------------------------
if [ "$MAKE_QUEUE" -eq 0 ]; then
  echo "Driver files installed. Skipping queue creation (--no-queue)."
  exit 0
fi

if [ -z "$URI" ]; then
  say "Looking for the printer on the network..."
  # Prefer the Bonjour URI: it survives DHCP changes.
  URI="$(lpinfo -v 2>/dev/null | awk '/dnssd:.*DCP-T420W/ {print $2; exit}')"
fi

if [ -z "$URI" ]; then
  echo "Could not find a DCP-T420W via Bonjour." >&2
  echo "Pass the address explicitly, e.g.:" >&2
  echo "  sudo $0 --uri ipp://192.0.2.25:631/ipp/print" >&2
  exit 1
fi

say "Device  -> $URI"

lpadmin -p "$QUEUE" \
        -D "Brother DCP-T420W" \
        -L "" \
        -v "$URI" \
        -P "$PPD_DIR/$PPD_NAME" \
        -o printer-is-shared=false \
        -E

cupsenable "$QUEUE" 2>/dev/null || true
cupsaccept "$QUEUE" 2>/dev/null || true

# Only claim the default if the machine does not already have one.
if ! lpstat -d 2>/dev/null | grep -q ':'; then
  lpadmin -d "$QUEUE"
  say "Set as the default printer."
fi

echo
echo "Done. Queue \"$QUEUE\" is ready."
echo "Test it with:  lp -d $QUEUE '$HERE/test/testpage-a4.pdf'"
