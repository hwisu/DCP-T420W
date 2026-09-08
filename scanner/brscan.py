#!/usr/bin/env python3
"""brscan - scan from a Brother DCP-T420W (and other eSCL scanners) on macOS.

The DCP-T420W advertises _uscan._tcp and speaks eSCL (AirScan / Mopria Scan
1.3), a plain HTTP + XML protocol. This talks to it directly, so there is
nothing to install: no SANE, no ICA plugin, no Brother package.

    brscan                                  # full platen, colour, PDF
    brscan --mode gray --out receipt.pdf
    brscan --mode lineart --rotate 180 --out doc.pdf
    brscan --crop 105x148 --out photo.jpg
    brscan --caps                           # what the scanner claims
    brscan --list                           # find scanners

IMPORTANT - this firmware ignores scan settings
-----------------------------------------------
The DCP-T420W accepts an eSCL ScanJobs POST and then disregards the body. It
returns HTTP 201 even for a body of "this is not xml at all", and always scans
the same way: the full platen, colour, JPEG, at a fixed size. Asking for
Grayscale8 returns 3-channel colour; asking for application/pdf returns JPEG
with Content-Type: image/jpeg.

So resolution, colour mode, region and format cannot be set on the device.
brscan requests them anyway (harmless, and sibling models may honour them),
then applies whatever the device ignored locally with sips. Use --raw to keep
exactly what the scanner sent.

Requires only Python 3 and sips, both part of macOS.
"""

import argparse
import datetime
from http.client import HTTPException
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zlib

NS = {
    "scan": "http://schemas.hp.com/imaging/escl/2011/05/03",
    "pwg": "http://www.pwg.org/schemas/2010/12/sm",
}

UNITS_PER_INCH = 300          # eSCL regions are in three-hundredths of an inch
MM_PER_INCH = 25.4

COLOR_MODES = {"color": "RGB24", "gray": "Grayscale8", "lineart": "BlackAndWhite1"}
FORMATS = {"pdf": "pdf", "jpeg": "jpg", "jpg": "jpg", "png": "png"}

CROPS = {"a4": (210.0, 297.0), "letter": (215.9, 279.4), "a5": (148.0, 210.0),
         "a6": (105.0, 148.0), "4x6": (101.6, 152.4), "5x7": (127.0, 177.8)}


class ScanError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

def _dns_sd(args, timeout):
    try:
        res = subprocess.run(["dns-sd"] + args, capture_output=True,
                             text=True, timeout=timeout)
        return res.stdout
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout
        return out.decode() if isinstance(out, bytes) else (out or "")
    except FileNotFoundError:
        raise ScanError("dns-sd not found; pass --host explicitly.")


def discover(timeout=5):
    """Return [(name, host, port, rs)] for eSCL scanners on the LAN."""
    names = []
    for line in _dns_sd(["-B", "_uscan._tcp", "local"], timeout).splitlines():
        m = re.search(r"_uscan\._tcp\.\s+(.+?)\s*$", line)
        if m and " Add " in f" {line} " and m.group(1) not in names:
            names.append(m.group(1))

    found = []
    for name in names:
        text = _dns_sd(["-L", name, "_uscan._tcp", "local"], timeout)
        m = re.search(r"can be reached at\s+(\S+?):(\d+)", text)
        if not m:
            continue
        rs = re.search(r"\brs=(\S+)", text)
        found.append((name, m.group(1).rstrip("."), int(m.group(2)),
                      rs.group(1).strip() if rs else "eSCL"))
    return found


def base_url(host, port=80, rs="eSCL"):
    return f"http://{host}{'' if port == 80 else f':{port}'}/{rs.strip('/')}"


# ---------------------------------------------------------------------------
# eSCL protocol
# ---------------------------------------------------------------------------

def http(method, url, data=None, content_type=None, timeout=120):
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("User-Agent", "brscan/1.0")
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        return urllib.request.urlopen(req, timeout=timeout)
    except urllib.error.HTTPError as exc:
        exc.close()
        raise ScanError(f"{method} {url} -> HTTP {exc.code} {exc.reason}", exc.code) from exc
    except urllib.error.URLError as exc:
        raise ScanError(f"Cannot reach {url}: {exc.reason}") from exc


def text_of(root, path, default=None):
    el = root.find(path, NS)
    return el.text.strip() if el is not None and el.text else default


def get_caps(base):
    return ET.fromstring(http("GET", f"{base}/ScannerCapabilities", timeout=20).read())


def platen_caps(root):
    p = root.find("scan:Platen/scan:PlatenInputCaps", NS)
    if p is None:
        raise ScanError("Scanner reports no platen; brscan only drives the flatbed.")
    return p


def describe_caps(root):
    out = [f"Model        {text_of(root, 'pwg:MakeAndModel', '?')}",
           f"eSCL version {text_of(root, 'pwg:Version', '?')}"]
    has_adf = root.find("scan:Adf", NS) is not None
    out.append(f"Sources      Platen{' + ADF' if has_adf else ' only (no document feeder)'}")

    p = platen_caps(root)
    w = int(text_of(p, "scan:MaxWidth", "0"))
    h = int(text_of(p, "scan:MaxHeight", "0"))
    out.append(f"Max area     {w/UNITS_PER_INCH*MM_PER_INCH:.0f} x "
               f"{h/UNITS_PER_INCH*MM_PER_INCH:.0f} mm")
    prof = p.find("scan:SettingProfiles/scan:SettingProfile", NS)
    if prof is not None:
        out.append("Colour modes " + ", ".join(
            e.text for e in prof.findall("scan:ColorModes/scan:ColorMode", NS)))
        out.append("Formats      " + ", ".join(sorted(
            {e.text for e in prof.findall("scan:DocumentFormats/pwg:DocumentFormat", NS)})))
        out.append("Resolutions  " + ", ".join(
            e.text for e in prof.findall(
                "scan:SupportedResolutions/scan:DiscreteResolutions/"
                "scan:DiscreteResolution/scan:XResolution", NS)) + " dpi")
    intents = [e.text for e in p.findall("scan:SupportedIntents/scan:Intent", NS)]
    if intents:
        out.append("Intents      " + ", ".join(intents))
    ox = text_of(p, "scan:MaxOpticalXResolution")
    if ox:
        out.append(f"Optical      {ox} x {text_of(p, 'scan:MaxOpticalYResolution')} dpi")
    out.append("")
    out.append("Note: on the DCP-T420W these are claims only - the firmware")
    out.append("ignores the settings you send and always scans the full platen")
    out.append("in colour as JPEG. brscan applies the rest locally.")
    return "\n".join(out)


def build_settings(version, mode, mime, dpi, intent, width, height):
    """A well-formed ScanSettings request.

    Element order follows the eSCL schema sequence and the region carries
    MustHonor, because scanners that *do* read the body can be strict about
    both. The DCP-T420W reads none of it.
    """
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<scan:ScanSettings xmlns:pwg="{NS['pwg']}" xmlns:scan="{NS['scan']}">
  <pwg:Version>{version}</pwg:Version>
  <scan:Intent>{intent}</scan:Intent>
  <pwg:ScanRegions pwg:MustHonor="true">
    <pwg:ScanRegion>
      <pwg:Height>{height}</pwg:Height>
      <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
      <pwg:Width>{width}</pwg:Width>
      <pwg:XOffset>0</pwg:XOffset>
      <pwg:YOffset>0</pwg:YOffset>
    </pwg:ScanRegion>
  </pwg:ScanRegions>
  <pwg:InputSource>Platen</pwg:InputSource>
  <scan:ColorMode>{mode}</scan:ColorMode>
  <scan:XResolution>{dpi}</scan:XResolution>
  <scan:YResolution>{dpi}</scan:YResolution>
  <pwg:DocumentFormat>{mime}</pwg:DocumentFormat>
  <scan:DocumentFormatExt>{mime}</scan:DocumentFormatExt>
</scan:ScanSettings>
""".encode("utf-8")


def scanner_state(base):
    try:
        root = ET.fromstring(http("GET", f"{base}/ScannerStatus", timeout=15).read())
        return text_of(root, "pwg:State", "Unknown")
    except (ScanError, ET.ParseError):
        return "Unknown"


def run_scan(base, settings, verbose=False):
    resp = http("POST", f"{base}/ScanJobs", data=settings,
                content_type="text/xml", timeout=60)
    job = resp.headers.get("Location")
    if not job:
        raise ScanError("Scanner accepted the job but returned no Location header.")
    # Some firmwares put an unreachable host in Location; keep the one we used.
    origin = urllib.parse.urlsplit(base)
    target = urllib.parse.urlsplit(urllib.parse.urljoin(f"{base}/ScanJobs", job))
    job = urllib.parse.urlunsplit((origin.scheme, origin.netloc,
                                  target.path.rstrip("/"), target.query, ""))
    resp.close()
    if verbose:
        print(f"  job {job}", file=sys.stderr)

    pages = []
    try:
        while True:
            try:
                next_url = urllib.parse.urlsplit(job)
                next_url = next_url._replace(path=next_url.path + "/NextDocument").geturl()
                with http("GET", next_url, timeout=300) as doc:
                    if doc.status != 200:
                        raise ScanError(f"NextDocument returned HTTP {doc.status}.")
                    data = doc.read()
                    content_type = doc.headers.get("Content-Type", "")
            except ScanError as exc:
                if exc.status in (404, 410):
                    break
                raise
            if not data:
                raise ScanError("NextDocument returned an empty page.")
            pages.append((data, content_type))
    except (OSError, HTTPException) as exc:
        raise ScanError(f"Could not read NextDocument: {exc}") from exc
    finally:
        try:
            http("DELETE", job, timeout=15).close()
        except (ScanError, OSError, HTTPException):
            pass

    if not pages:
        raise ScanError("Scanner returned no pages.")
    return pages


# ---------------------------------------------------------------------------
# Minimal PNG codec, for the pixel work sips will not do
# ---------------------------------------------------------------------------

def png_read(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ScanError(f"{path}: not a PNG")
    off, idat, w = 8, b"", None
    while off < len(data):
        ln = struct.unpack(">I", data[off:off + 4])[0]
        tag, payload = data[off + 4:off + 8], data[off + 8:off + 8 + ln]
        if tag == b"IHDR":
            w, h, depth, ctype, _c, _f, interlace = struct.unpack(">IIBBBBB", payload[:13])
            if depth != 8 or interlace:
                raise ScanError("Only 8-bit non-interlaced PNG is supported.")
        elif tag == b"IDAT":
            idat += payload
        elif tag == b"IEND":
            break
        off += 12 + ln

    nch = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(idat)
    stride = w * nch
    rows, prev, i = [], bytearray(stride), 0

    for _y in range(h):
        f = raw[i]; i += 1
        line = bytearray(raw[i:i + stride]); i += stride
        if f:
            for x in range(stride):
                a = line[x - nch] if x >= nch else 0
                b = prev[x]
                c = prev[x - nch] if x >= nch else 0
                if f == 1:
                    line[x] = (line[x] + a) & 255
                elif f == 2:
                    line[x] = (line[x] + b) & 255
                elif f == 3:
                    line[x] = (line[x] + ((a + b) >> 1)) & 255
                elif f == 4:
                    pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                    pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                    line[x] = (line[x] + pred) & 255
        rows.append(bytes(line))
        prev = line
    return w, h, nch, rows


def png_write(path, w, h, nch, rows):
    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    ctype = {1: 0, 3: 2}[nch]
    raw = b"".join(b"\0" + r for r in rows)
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(raw, 6))
    out += chunk(b"IEND", b"")
    open(path, "wb").write(out)


def to_gray(path, threshold=None):
    """Convert a PNG to greyscale in place; threshold to pure B/W if given."""
    w, h, nch, rows = png_read(path)
    table = None if threshold is None else bytes(
        0 if i < threshold else 255 for i in range(256))
    out = []
    for r in rows:
        if nch == 1:
            line = r
        else:
            # Rec. 601 luma, one channel slice at a time.
            line = bytes((77 * a + 151 * b + 28 * c) >> 8
                         for a, b, c in zip(r[0::nch], r[1::nch], r[2::nch]))
        out.append(line.translate(table) if table else line)
    png_write(path, w, h, 1, out)


# ---------------------------------------------------------------------------
# sips helpers
# ---------------------------------------------------------------------------

def sips(*args):
    res = subprocess.run(["sips", *map(str, args)], capture_output=True, text=True)
    if res.returncode != 0:
        raise ScanError(f"sips failed: {res.stderr.strip() or res.stdout.strip()}")
    return res.stdout


def image_size(path):
    out = sips("-g", "pixelWidth", "-g", "pixelHeight", path)
    w = int(re.search(r"pixelWidth:\s*(\d+)", out).group(1))
    h = int(re.search(r"pixelHeight:\s*(\d+)", out).group(1))
    return w, h


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_crop(spec):
    if spec.lower() in CROPS:
        return CROPS[spec.lower()]
    m = re.fullmatch(r"(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)", spec.lower())
    if not m:
        raise ScanError(f"Cannot parse --crop {spec!r}; use a preset or WxH in mm.")
    w, h = float(m.group(1)), float(m.group(2))
    if not (math.isfinite(w) and math.isfinite(h) and w > 0 and h > 0):
        raise ScanError("--crop dimensions must be positive and finite.")
    return w, h


def main():
    p = argparse.ArgumentParser(
        prog="brscan", description=__doc__.split("IMPORTANT")[0].strip(),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="The DCP-T420W firmware ignores eSCL scan settings; brscan\n"
               "applies mode, crop and format locally instead. --raw keeps\n"
               "exactly what the scanner sent.")
    p.add_argument("--host", help="scanner hostname or IP (default: discover)")
    p.add_argument("--port", type=int, default=80)
    p.add_argument("--path", default="eSCL", help="eSCL root (TXT rs=, default eSCL)")
    p.add_argument("--out", help="output file (default scan-<timestamp>.<ext>)")
    p.add_argument("--format", choices=sorted(set(FORMATS)), help="default pdf")
    p.add_argument("--mode", choices=sorted(COLOR_MODES), default="color")
    p.add_argument("--threshold", type=int, default=128,
                   help="black/white cutoff 1-254 for --mode lineart (default 128)")
    p.add_argument("--dpi", type=int, default=300, help="requested of the device")
    p.add_argument("--intent", default="Document",
                   choices=["Document", "TextAndGraphic", "Photo", "Preview"],
                   help="Document, TextAndGraphic, Photo or Preview")
    p.add_argument("--crop", help="a4, letter, a5, a6, 4x6, 5x7 or WxH in mm, "
                                  "taken from the top-left of the glass")
    p.add_argument("--rotate", type=int, default=0, choices=[0, 90, 180, 270],
                   help="rotate clockwise after scanning")
    p.add_argument("--raw", action="store_true",
                   help="save the scanner's bytes untouched, no processing")
    p.add_argument("--caps", action="store_true")
    p.add_argument("--list", action="store_true")
    p.add_argument("--status", action="store_true")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()
    if not 1 <= args.port <= 65535:
        p.error("--port must be 1-65535")
    if not 1 <= args.dpi <= 2147483647:
        p.error("--dpi must be 1-2147483647")
    if not 1 <= args.threshold <= 254:
        p.error("--threshold must be 1-254")
    try:
        crop = parse_crop(args.crop) if args.crop else None
    except ScanError as exc:
        p.error(str(exc))

    try:
        if args.list:
            found = discover()
            if not found:
                print("No eSCL scanners found.")
                return 1
            for name, host, port, rs in found:
                print(f"{name}\n  http://{host}:{port}/{rs}")
            return 0

        host, port, rs = args.host, args.port, args.path
        if not host:
            found = discover()
            if not found:
                raise ScanError("No eSCL scanner found. Pass --host.")
            name, host, port, rs = found[0]
            if args.verbose:
                print(f"Using {name} at {host}:{port}", file=sys.stderr)

        base = base_url(host, port, rs)

        if args.status:
            print(scanner_state(base))
            return 0

        caps = get_caps(base)
        if args.caps:
            print(describe_caps(caps))
            return 0

        plat = platen_caps(caps)
        max_w = int(text_of(plat, "scan:MaxWidth", "2550"))
        max_h = int(text_of(plat, "scan:MaxHeight", "3507"))
        if max_w <= 0 or max_h <= 0:
            raise ScanError("ScannerCapabilities has invalid platen dimensions.")
        version = text_of(caps, "pwg:Version", "2.63")

        fmt = args.format
        if not fmt and args.out:
            fmt = {".pdf": "pdf", ".jpg": "jpeg", ".jpeg": "jpeg",
                   ".png": "png"}.get(os.path.splitext(args.out)[1].lower())
        fmt = fmt or "pdf"
        ext = FORMATS[fmt]

        out = args.out or (f"scan-{datetime.datetime.now():%Y%m%d-%H%M%S}."
                           f"{'jpg' if args.raw else ext}")

        state = scanner_state(base)
        if state not in ("Idle", "Unknown"):
            print(f"Scanner state is {state}; trying anyway...", file=sys.stderr)

        mime = "application/pdf" if fmt == "pdf" else "image/jpeg"
        settings = build_settings(version, COLOR_MODES[args.mode], mime,
                                  args.dpi, args.intent, max_w, max_h)
        if args.verbose:
            print(settings.decode(), file=sys.stderr)

        print("Scanning...", file=sys.stderr)
        started = time.time()
        pages = run_scan(base, settings, args.verbose)
        print(f"Scanner returned {len(pages)} page(s) in {time.time()-started:.1f}s",
              file=sys.stderr)

        written = []
        for idx, (data, ctype) in enumerate(pages):
            target = out if idx == 0 else re.sub(r"(\.[^.]+)$", f"-{idx+1}\\1", out)

            if args.raw:
                with open(target, "wb") as fh:
                    fh.write(data)
                written.append(target)
                continue

            with tempfile.TemporaryDirectory() as tmp:
                src = os.path.join(tmp, "scan.bin")
                with open(src, "wb") as fh:
                    fh.write(data)

                if data[:4] == b"%PDF":
                    # Nothing to post-process meaningfully; pass it through.
                    shutil.copyfile(src, target)
                    written.append(target)
                    continue

                work = os.path.join(tmp, "work.png")
                sips("-s", "format", "png", src, "--out", work)

                if crop:
                    cw_mm, ch_mm = crop
                    fw, fh_px = image_size(work)
                    # Map millimetres onto the frame using the platen size the
                    # scanner reports. Pixels are not square on this device, so
                    # each axis gets its own scale.
                    plat_w_mm = max_w / UNITS_PER_INCH * MM_PER_INCH
                    plat_h_mm = max_h / UNITS_PER_INCH * MM_PER_INCH
                    cw = max(1, round(min(1, cw_mm / plat_w_mm) * fw))
                    ch = max(1, round(min(1, ch_mm / plat_h_mm) * fh_px))
                    # sips crops centred, so offset back to the top-left origin.
                    sips("-c", ch, cw, "--cropOffset", 0, 0, work, "--out", work)
                    if args.verbose:
                        print(f"  cropped to {cw}x{ch}px "
                              f"({cw_mm}x{ch_mm}mm of {plat_w_mm:.0f}x{plat_h_mm:.0f})",
                              file=sys.stderr)

                if args.rotate:
                    sips("-r", args.rotate, work, "--out", work)

                if args.mode == "gray":
                    to_gray(work)
                elif args.mode == "lineart":
                    to_gray(work, threshold=max(1, min(254, args.threshold)))

                if fmt == "png":
                    shutil.copyfile(work, target)
                else:
                    sips("-s", "format", "pdf" if fmt == "pdf" else "jpeg",
                         work, "--out", target)

            written.append(target)

        for path in written:
            print(f"Wrote {path} ({os.path.getsize(path)/1024:.0f} KB)")
        return 0

    except ScanError as exc:
        print(f"brscan: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nbrscan: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
