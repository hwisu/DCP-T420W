#!/usr/bin/env python3
"""Dump PWG Raster page headers.

PWG Raster is a 4-byte sync word followed, per page, by a 1796-byte header and
the compressed band data. This decodes the header so driver output can be
checked field by field instead of by eyeball.

    python3 test/pwgdump.py file.pwg [file2.pwg ...]
"""

import struct
import sys

HEADER_LEN = 1796

# (name, kind, count) in on-the-wire order. kind: s=string64, u=uint32, f=float32
FIELDS = [
    ("MediaClass", "s", 1), ("MediaColor", "s", 1),
    ("MediaType", "s", 1), ("OutputType", "s", 1),
    ("AdvanceDistance", "u", 1), ("AdvanceMedia", "u", 1), ("Collate", "u", 1),
    ("CutMedia", "u", 1), ("Duplex", "u", 1), ("HWResolution", "u", 2),
    ("ImagingBoundingBox", "u", 4), ("InsertSheet", "u", 1), ("Jog", "u", 1),
    ("LeadingEdge", "u", 1), ("Margins", "u", 2), ("ManualFeed", "u", 1),
    ("MediaPosition", "u", 1), ("MediaWeight", "u", 1), ("MirrorPrint", "u", 1),
    ("NegativePrint", "u", 1), ("NumCopies", "u", 1), ("Orientation", "u", 1),
    ("OutputFaceUp", "u", 1), ("PageSize", "u", 2), ("Separations", "u", 1),
    ("TraySwitch", "u", 1), ("Tumble", "u", 1), ("cupsWidth", "u", 1),
    ("cupsHeight", "u", 1), ("cupsMediaType", "u", 1),
    ("cupsBitsPerColor", "u", 1), ("cupsBitsPerPixel", "u", 1),
    ("cupsBytesPerLine", "u", 1), ("cupsColorOrder", "u", 1),
    ("cupsColorSpace", "u", 1), ("cupsCompression", "u", 1),
    ("cupsRowCount", "u", 1), ("cupsRowFeed", "u", 1), ("cupsRowStep", "u", 1),
    ("cupsNumColors", "u", 1), ("cupsBorderlessScalingFactor", "f", 1),
    ("cupsPageSize", "f", 2), ("cupsImagingBBox", "f", 4),
    ("cupsInteger", "u", 16), ("cupsReal", "f", 16), ("cupsString", "S", 16),
    ("cupsMarkerType", "s", 1), ("cupsRenderingIntent", "s", 1),
    ("cupsPageSizeName", "s", 1),
]

CSPACE = {0: "W", 1: "RGB", 3: "K", 18: "sgray_8", 19: "srgb_8", 20: "AdobeRGB"}


def parse_header(buf):
    out, off = {}, 0
    for name, kind, count in FIELDS:
        if kind in ("s", "S"):
            vals = []
            for _ in range(count):
                vals.append(buf[off:off + 64].split(b"\0")[0].decode("utf-8", "replace"))
                off += 64
            out[name] = vals[0] if kind == "s" else vals
        else:
            fmt = ">" + ("I" if kind == "u" else "f") * count
            vals = struct.unpack_from(fmt, buf, off)
            off += 4 * count
            out[name] = vals[0] if count == 1 else list(vals)
    assert off == HEADER_LEN, f"header walk ended at {off}, expected {HEADER_LEN}"
    return out


def headers(path):
    data = open(path, "rb").read()
    sync = data[:4]
    if sync not in (b"RaS2", b"2SaR"):
        raise SystemExit(f"{path}: not PWG Raster (sync {sync!r})")

    pages, off = [], 4
    while off + HEADER_LEN <= len(data):
        h = parse_header(data[off:off + HEADER_LEN])
        off += HEADER_LEN
        # Skip the page's band data: each line is a repeat count plus packbits.
        lines = 0
        while lines < h["cupsHeight"] and off < len(data):
            off += 1                      # line repeat count
            lines += 1
            written = 0
            while written < h["cupsBytesPerLine"] and off < len(data):
                ctrl = data[off]; off += 1
                if ctrl < 128:
                    n = (ctrl + 1) * (h["cupsBitsPerPixel"] // 8)
                    off += h["cupsBitsPerPixel"] // 8
                else:
                    n = (257 - ctrl) * (h["cupsBitsPerPixel"] // 8)
                    off += n
                written += n
        pages.append((h, sync))
    return pages


INTERESTING = [
    "MediaType", "cupsPageSizeName", "cupsWidth", "cupsHeight",
    "cupsBitsPerPixel", "cupsBytesPerLine", "cupsColorSpace", "cupsNumColors",
    "HWResolution", "PageSize", "cupsPageSize", "cupsImagingBBox",
    "ImagingBoundingBox", "Margins", "Duplex", "NumCopies", "OutputFaceUp",
    "cupsBorderlessScalingFactor", "cupsMediaType", "cupsRenderingIntent",
    "MediaPosition", "cupsCompression", "cupsInteger",
]


def main(paths):
    dumps = []
    for p in paths:
        pages = headers(p)
        print(f"== {p}: {len(pages)} page(s), sync {pages[0][1].decode()}")
        h = pages[0][0]
        for k in INTERESTING:
            v = h[k]
            extra = f"  ({CSPACE.get(v, '?')})" if k == "cupsColorSpace" else ""
            print(f"   {k:30s} {v}{extra}")
        dumps.append(h)
        print()

    if len(dumps) == 2:
        print("== differences (page 1)")
        a, b = dumps
        for name, _kind, _count in FIELDS:
            if a[name] != b[name]:
                print(f"   {name:30s} {a[name]!r:38s} -> {b[name]!r}")


if __name__ == "__main__":
    main(sys.argv[1:] or ["-"])
