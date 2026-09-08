#!/usr/bin/env python3
"""Decode a PWG Raster stream back to PNG, so driver output can be checked
without printing it.

PWG Raster lines are run-length encoded: a repeat count for the whole line,
then control bytes selecting either a repeated pixel or a literal run. This
reverses that and writes a PNG (no third-party modules involved).

    python3 test/pwg2png.py out.pwg page.png [--scale 8]
"""

import struct
import sys
import zlib

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from pwgdump import HEADER_LEN, parse_header  # noqa: E402


def decode_page(data, off, h):
    """Return (rows, off) where rows is a list of bytes objects."""
    width, height = h["cupsWidth"], h["cupsHeight"]
    bpp = h["cupsBitsPerPixel"] // 8
    line_len = h["cupsBytesPerLine"]
    rows = []

    while len(rows) < height:
        repeat = data[off] + 1
        off += 1
        line = bytearray()
        while len(line) < line_len:
            ctrl = data[off]
            off += 1
            if ctrl < 128:
                line += data[off:off + bpp] * (ctrl + 1)
                off += bpp
            else:
                n = 257 - ctrl
                line += data[off:off + n * bpp]
                off += n * bpp
        line = bytes(line[:line_len])
        rows.extend([line] * min(repeat, height - len(rows)))

    return rows, off


def write_png(path, rows, width, height, bpp, scale=1):
    color_type = 0 if bpp == 1 else 2          # 0 = grey, 2 = truecolour

    if scale > 1:
        step = scale
        out_rows = []
        for y in range(0, height, step):
            src = rows[y]
            out_rows.append(b"".join(src[x * bpp:(x + 1) * bpp]
                                     for x in range(0, width, step)))
        rows = out_rows
        width = len(range(0, width, step))
        height = len(out_rows)

    raw = b"".join(b"\0" + r for r in rows)

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as output:
        output.write(png)
    return width, height


def main(argv):
    src, dst = argv[0], argv[1]
    scale = 1
    if "--scale" in argv:
        scale = int(argv[argv.index("--scale") + 1])

    data = open(src, "rb").read()
    if data[:4] != b"RaS2":
        raise SystemExit(f"{src}: not big-endian PWG Raster")

    h = parse_header(data[4:4 + HEADER_LEN])
    rows, _off = decode_page(data, 4 + HEADER_LEN, h)
    bpp = h["cupsBitsPerPixel"] // 8

    if len(rows) != h["cupsHeight"]:
        raise SystemExit(f"decoded {len(rows)} rows, header says {h['cupsHeight']}")
    bad = [i for i, r in enumerate(rows) if len(r) != h["cupsBytesPerLine"]]
    if bad:
        raise SystemExit(f"{len(bad)} row(s) have the wrong length, first at {bad[0]}")

    w, ht = write_png(dst, rows, h["cupsWidth"], h["cupsHeight"], bpp, scale)
    print(f"{src}: {h['cupsWidth']}x{h['cupsHeight']} "
          f"{'grey' if bpp == 1 else 'rgb'} -> {dst} ({w}x{ht}), all rows well-formed")


if __name__ == "__main__":
    main(sys.argv[1:])
