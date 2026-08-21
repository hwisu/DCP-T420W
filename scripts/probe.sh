#!/bin/bash
#
# Print the IPP capabilities the driver is built from.
#
# Use this to re-check a printer before regenerating the PPD, or to adapt the
# driver to a sibling model (DCP-T425W, DCP-T430W, ...). The fields that matter
# to scripts/genppd.py are media-supported, media-size-supported, the four
# media-*-margin-supported lists, print-quality-supported and
# pwg-raster-document-type-supported.
#
#   ./probe.sh                       # auto-discover over Bonjour
#   ./probe.sh ipp://host:631/ipp/print
#

set -euo pipefail

URI="${1:-}"
TMP="$(mktemp -d -t brprobe)"
trap 'rm -rf "$TMP"' EXIT

if [ -z "$URI" ]; then
  # Resolve the Bonjour service to the host:port ipptool needs. dns-sd never
  # exits on its own, so run it in the background and read what it printed.
  ( dns-sd -L "Brother DCP-T420W" _ipp._tcp local >"$TMP/resolve" 2>&1 & ) || true
  sleep 4
  pkill -f 'dns-sd -L' 2>/dev/null || true

  # The line reads "... can be reached at HOST.local.:631 (interface 5)", so
  # take the token right after "at" rather than the last field.
  HOSTPORT="$(awk '/can be reached at/ {
                     for (i = 1; i < NF; i++)
                       if ($i == "at") { print $(i + 1); exit }
                   }' "$TMP/resolve" 2>/dev/null || true)"
  HOSTPORT="${HOSTPORT/.:/:}"

  if [ -z "$HOSTPORT" ]; then
    echo "No Brother DCP-T420W found on the network." >&2
    echo "Pass its address explicitly, e.g.:" >&2
    echo "  $0 ipp://192.0.2.25:631/ipp/print" >&2
    exit 1
  fi

  URI="ipp://${HOSTPORT}/ipp/print"
  echo "Discovered: $URI" >&2
  echo >&2
fi

cat > "$TMP/req.test" <<'REQ'
{
	OPERATION Get-Printer-Attributes
	GROUP operation-attributes-tag
	ATTR charset attributes-charset utf-8
	ATTR language attributes-natural-language en
	ATTR uri printer-uri $uri
	ATTR keyword requested-attributes all
	STATUS successful-ok
}
REQ

ipptool -tv "$URI" "$TMP/req.test" | grep -E \
  "printer-make-and-model|document-format-supported|media-supported|\
media-size-supported|media-type-supported|media-.*-margin-supported|\
print-quality-supported|print-color-mode-supported|printer-resolution|\
pwg-raster-document|urf-supported|mopria|printer-device-id|marker-"
