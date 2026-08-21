#!/usr/bin/env python3
"""Build a printer test page as a self-contained PDF (no dependencies).

The page is designed to prove the driver's geometry rather than just to make
marks: the outer rule sits exactly on the PPD's *ImageableArea, so if
rastertobrother pads the page correctly the rule lands 3 mm inside every paper
edge, square and unclipped. Everything else exercises colour, greys and
resolution.

    python3 test/make_testpage.py > test/testpage-a4.pdf
"""

import sys
import zlib

MM = 72.0 / 25.4

# A4 at the printer's reported size, and its 3 mm hardware margin.
PAGE_W, PAGE_H = 210 * MM, 297 * MM
MARGIN = 3 * MM


def esc(text):
    return text.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")


class Content:
    """Tiny PDF content-stream builder."""

    def __init__(self):
        self.ops = []

    def __call__(self, op):
        self.ops.append(op)

    def rgb_stroke(self, r, g, b):
        self(f"{r:.3f} {g:.3f} {b:.3f} RG")

    def rgb_fill(self, r, g, b):
        self(f"{r:.3f} {g:.3f} {b:.3f} rg")

    def rect(self, x, y, w, h, mode="S"):
        self(f"{x:.3f} {y:.3f} {w:.3f} {h:.3f} re {mode}")

    def line(self, x1, y1, x2, y2):
        self(f"{x1:.3f} {y1:.3f} m {x2:.3f} {y2:.3f} l S")

    def text(self, x, y, size, string, font="F1"):
        self("BT")
        self(f"/{font} {size:.2f} Tf")
        self(f"1 0 0 1 {x:.3f} {y:.3f} Tm")
        self(f"({esc(string)}) Tj")
        self("ET")

    def render(self):
        return "\n".join(self.ops).encode("latin-1")


def build_page():
    c = Content()
    c("0.6 w")

    # -- Imageable-area rule: the geometry check --------------------------
    c.rgb_stroke(0, 0, 0)
    c.rect(MARGIN, MARGIN, PAGE_W - 2 * MARGIN, PAGE_H - 2 * MARGIN)

    # Corner brackets, 12 mm arms, sitting on the same boundary.
    arm = 12 * MM
    for cx, cy, dx, dy in (
        (MARGIN, MARGIN, 1, 1),
        (PAGE_W - MARGIN, MARGIN, -1, 1),
        (MARGIN, PAGE_H - MARGIN, 1, -1),
        (PAGE_W - MARGIN, PAGE_H - MARGIN, -1, -1),
    ):
        c("1.4 w")
        c.line(cx, cy, cx + dx * arm, cy)
        c.line(cx, cy, cx, cy + dy * arm)
    c("0.6 w")

    top = PAGE_H - MARGIN
    y = top - 22 * MM

    c.rgb_fill(0, 0, 0)
    c.text(MARGIN + 8 * MM, y, 18, "Brother DCP-T420W")
    y -= 7 * MM
    c.text(MARGIN + 8 * MM, y, 10, "macOS PWG Raster driver - test page")
    y -= 5 * MM
    c.text(MARGIN + 8 * MM, y, 8,
           "Outer rule = imageable area (3 mm inset). It must be unclipped and "
           "square on all four sides.")

    # -- Process colour bars ----------------------------------------------
    y -= 12 * MM
    c.text(MARGIN + 8 * MM, y, 9, "Process colours")
    y -= 3 * MM
    bars = [
        ("C", 0.0, 1.0, 1.0), ("M", 1.0, 0.0, 1.0), ("Y", 1.0, 1.0, 0.0),
        ("R", 1.0, 0.0, 0.0), ("G", 0.0, 1.0, 0.0), ("B", 0.0, 0.0, 1.0),
        ("K", 0.0, 0.0, 0.0),
    ]
    bw = (PAGE_W - 2 * MARGIN - 16 * MM) / len(bars)
    bh = 16 * MM
    for i, (label, r, g, b) in enumerate(bars):
        x = MARGIN + 8 * MM + i * bw
        c.rgb_fill(r, g, b)
        c.rect(x, y - bh, bw - 1.5, bh, "f")
        c.rgb_fill(0, 0, 0)
        c.text(x + bw / 2 - 3, y - bh - 4 * MM, 8, label)

    # -- Grey ramp ---------------------------------------------------------
    y -= bh + 14 * MM
    c.rgb_fill(0, 0, 0)
    c.text(MARGIN + 8 * MM, y, 9, "Grey ramp (0-100%)")
    y -= 3 * MM
    steps = 11
    sw = (PAGE_W - 2 * MARGIN - 16 * MM) / steps
    sh = 12 * MM
    for i in range(steps):
        v = 1.0 - i / (steps - 1)
        c.rgb_fill(v, v, v)
        c.rect(MARGIN + 8 * MM + i * sw, y - sh, sw, sh, "f")
    c.rgb_stroke(0, 0, 0)
    c("0.4 w")
    c.rect(MARGIN + 8 * MM, y - sh, sw * steps, sh)

    # -- Resolution / fine-line block -------------------------------------
    y -= sh + 14 * MM
    c.rgb_fill(0, 0, 0)
    c.text(MARGIN + 8 * MM, y, 9,
           "Fine lines - hairline to 1 pt (600 dpi renders the 0.12 pt rule)")
    y -= 5 * MM
    x = MARGIN + 8 * MM
    for width in (0.12, 0.24, 0.35, 0.5, 0.75, 1.0):
        c(f"{width:.2f} w")
        c.rgb_stroke(0, 0, 0)
        for k in range(6):
            c.line(x + k * 1.6, y, x + k * 1.6, y - 14 * MM)
        c.text(x - 1, y - 17 * MM, 6, f"{width:g}")
        x += 22 * MM

    # -- Text ladder -------------------------------------------------------
    y -= 26 * MM
    c("0.6 w")
    c.rgb_fill(0, 0, 0)
    c.text(MARGIN + 8 * MM, y, 9, "Text rendering")
    y -= 6 * MM
    for size in (12, 10, 8, 6, 5, 4):
        c.text(MARGIN + 8 * MM, y, size,
               f"{size} pt - The quick brown fox jumps over the lazy dog 0123456789")
        y -= (size + 3.5)

    # -- Centre crosshair --------------------------------------------------
    cx, cy = PAGE_W / 2, PAGE_H / 2
    c("0.4 w")
    c.rgb_stroke(0.7, 0.7, 0.7)
    c.line(cx - 8 * MM, cy, cx + 8 * MM, cy)
    c.line(cx, cy - 8 * MM, cx, cy + 8 * MM)

    # -- Footer ------------------------------------------------------------
    c.rgb_fill(0.3, 0.3, 0.3)
    c.text(MARGIN + 8 * MM, MARGIN + 6 * MM, 7,
           "rastertobrother / image-pwg-raster / A4 210x297mm / 3 mm margins")

    return c.render()


def build_pdf(content):
    stream = zlib.compress(content)
    objects = [
        b"<</Type/Catalog/Pages 2 0 R>>",
        b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
        (f"<</Type/Page/Parent 2 0 R/MediaBox[0 0 {PAGE_W:.4f} {PAGE_H:.4f}]"
         f"/Resources<</Font<</F1 5 0 R>>>>/Contents 4 0 R>>").encode("latin-1"),
        b"<</Length " + str(len(stream)).encode() + b"/Filter/FlateDecode>>\nstream\n"
        + stream + b"\nendstream",
        b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>",
    ]

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + body + b"\nendobj\n"

    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n".encode()
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += (f"trailer\n<</Size {len(objects) + 1}/Root 1 0 R>>\n"
            f"startxref\n{xref}\n%%EOF\n").encode()
    return bytes(out)


if __name__ == "__main__":
    sys.stdout.buffer.write(build_pdf(build_page()))
