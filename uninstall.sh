#!/bin/bash
#
# Remove the Brother DCP-T420W driver and its queue.
#
#   sudo ./uninstall.sh [--name QUEUE] [--keep-queue]
#

set -euo pipefail

FILTER_DIR="/usr/libexec/cups/filter"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
PPD_NAME="Brother DCP-T420W.ppd"
QUEUE="Brother_DCP_T420W"
DROP_QUEUE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --name)       QUEUE="$2"; shift 2 ;;
    --keep-queue) DROP_QUEUE=0; shift ;;
    *)            echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Re-run as: sudo $0 $*" >&2
  exit 1
fi

if [ "$DROP_QUEUE" -eq 1 ] && lpstat -p "$QUEUE" >/dev/null 2>&1; then
  lpadmin -x "$QUEUE"
  echo "  Removed queue $QUEUE"
fi

PLIST="/Library/LaunchDaemons/com.hwisu.dcp-t420w.airprint.plist"
if [ -f "$PLIST" ]; then
  launchctl bootout system/com.hwisu.dcp-t420w.airprint >/dev/null 2>&1 || true
  rm -f "$PLIST"
  echo "  Removed the AirPrint daemon"
fi
rm -f /usr/local/libexec/brairprint

rm -f "$FILTER_DIR/rastertobrother" && echo "  Removed $FILTER_DIR/rastertobrother"
rm -f "$PPD_DIR/$PPD_NAME"          && echo "  Removed $PPD_DIR/$PPD_NAME"

# Dropping the queue stops it being advertised, but the daemon-wide switch is
# not ours to flip back: other printers on this Mac may be relying on it.
if cupsctl 2>/dev/null | grep -q '^_share_printers=1'; then
  echo
  echo "Note: macOS printer sharing is still on for this Mac."
  echo "      Turn it off with:  sudo cupsctl --no-share-printers"
fi

echo "Done."
