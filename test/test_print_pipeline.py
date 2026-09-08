#!/usr/bin/env python3
"""Exercise macOS PDF rendering through the driver without submitting a job."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from pwgdump import HEADER_LEN, parse_header
from pwg2png import decode_page
from test_regressions import FILTER, ROOT


def three_page_pdf():
    objects = [b"<</Type/Catalog/Pages 2 0 R>>",
               b"<</Type/Pages/Kids[3 0 R 5 0 R 7 0 R]/Count 3>>"]
    for i in range(3):
        objects.append((f"<</Type/Page/Parent 2 0 R/MediaBox[0 0 595.2756 841.8898]"
                        f"/Resources<<>>/Contents {4 + 2 * i} 0 R>>").encode())
        content = f"{i / 2} 0 0 rg 50 50 100 100 re f".encode()
        objects.append(f"<</Length {len(content)}>>\nstream\n".encode()
                       + content + b"\nendstream")
    data, offsets = bytearray(b"%PDF-1.4\n"), []
    for i, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f"{i} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(data)
    data.extend(f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode())
    for offset in offsets:
        data.extend(f"{offset:010d} 00000 n \n".encode())
    data.extend((f"trailer\n<</Size {len(objects) + 1}/Root 1 0 R>>\n"
                 f"startxref\n{xref}\n%%EOF\n").encode())
    return data


class PrintPipelineTests(unittest.TestCase):
    def check_pipeline(self, options, dimensions, space, pages=1, multiple=False):
        with tempfile.TemporaryDirectory() as tmp:
            source = ROOT / "test/testpage-a4.pdf"
            if multiple:
                source = Path(tmp) / "three-pages.pdf"
                source.write_bytes(three_page_pdf())
            raster = Path(tmp) / "input.cups"
            env = {**os.environ, "PPD": str(ROOT / "ppd/Brother-DCP-T420W.ppd")}
            args = ["1", "test", "test", "1", options]
            with raster.open("wb") as output:
                rendered = subprocess.run(["/usr/libexec/cups/filter/cgpdftoraster", *args, str(source)],
                                          stdout=output, stderr=subprocess.PIPE, env=env, timeout=90)
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            converted = subprocess.run([FILTER, *args, str(raster)], capture_output=True,
                                       env=env, timeout=90)
            self.assertEqual(converted.returncode, 0, converted.stderr)
            data, offset, count = converted.stdout, 4, 0
            self.assertEqual(data[:4], b"RaS2")
            while offset < len(data):
                header = parse_header(data[offset:offset + HEADER_LEN])
                self.assertEqual((header["cupsWidth"], header["cupsHeight"]), dimensions)
                self.assertEqual(header["cupsColorSpace"], space)
                self.assertEqual(header["cupsPageSizeName"], "iso_a4_210x297mm")
                self.assertEqual(header["ImagingBoundingBox"], [0, 0, 0, 0])
                rows, offset = decode_page(data, offset + HEADER_LEN, header)
                self.assertEqual(len(rows), header["cupsHeight"])
                self.assertTrue(all(len(row) == header["cupsBytesPerLine"] for row in rows))
                count += 1
            self.assertEqual(count, pages)
            self.assertEqual(offset, len(data))

    def test_quality_and_colour(self):
        for options, size, space in [
            ("cupsPrintQuality=Draft ColorModel=Gray", (2480, 3508), 18),
            ("cupsPrintQuality=Normal ColorModel=RGB", (4961, 7016), 19),
            ("cupsPrintQuality=High ColorModel=RGB", (4961, 7016), 19),
            ("PageSize=A4.Borderless MediaType=PhotographicGlossy", (4961, 7016), 19),
        ]:
            with self.subTest(options=options):
                self.check_pipeline(options, size, space)

    def test_odd_even_selection(self):
        for selection, pages in [("odd", 2), ("even", 1)]:
            with self.subTest(selection=selection):
                self.check_pipeline(f"page-set={selection} cupsPrintQuality=Draft ColorModel=Gray",
                                    (2480, 3508), 18, pages, multiple=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
