#!/usr/bin/env python3
"""Offline regression tests. Build filter/ and scanner/ before running.

Rasters are tiny synthetic CUPS streams; scanners are loopback HTTP servers.
No test discovers, installs, scans from or prints to a physical device.
Set BROTHER_FILTER / BROTHER_SCANNER to test sanitizer or packaged binaries.
"""

import contextlib
import http.server
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest

from pwgdump import FIELDS, HEADER_LEN, parse_header
from pwg2png import decode_page, write_png


ROOT = Path(__file__).resolve().parents[1]
FILTER = os.environ.get("BROTHER_FILTER", str(ROOT / "filter/rastertobrother"))
SCANNER = os.environ.get("BROTHER_SCANNER", str(ROOT / "scanner/brscan"))
CLIENTS = [[SCANNER], [sys.executable, str(ROOT / "scanner/brscan.py")]]


def raster(**overrides):
    values = dict(HWResolution=[72, 72], cupsPageSize=[4, 4],
                  PageSize=[4, 4], cupsImagingBBox=[1, 1, 3, 3],
                  cupsWidth=2, cupsHeight=2, cupsBitsPerColor=8,
                  cupsBitsPerPixel=24, cupsBytesPerLine=6,
                  cupsColorSpace=19, cupsNumColors=3, NumCopies=1)
    values.update(overrides)
    header = bytearray()
    for name, kind, count in FIELDS:
        if kind in ("s", "S"):
            header.extend(bytes(64 * count))
        else:
            value = values.get(name, 0 if count == 1 else [0] * count)
            args = [value] if count == 1 else value
            header.extend(struct.pack(">" + ("I" if kind == "u" else "f") * count, *args))
    assert len(header) == HEADER_LEN
    # Uncompressed, big-endian CUPS v3, with red/green then blue/black pixels.
    return b"RaS3" + header + bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0])


class RasterTests(unittest.TestCase):
    def convert(self, data, options=""):
        return subprocess.run([FILTER, "1", "test", "test", "1", options],
                              input=data, capture_output=True, timeout=10,
                              env={**os.environ, "PPD": str(ROOT / "ppd/Brother-DCP-T420W.ppd")})

    def test_padding_and_pixels(self):
        result = self.convert(raster())
        self.assertEqual(result.returncode, 0, result.stderr)
        h = parse_header(result.stdout[4:4 + HEADER_LEN])
        rows, end = decode_page(result.stdout, 4 + HEADER_LEN, h)
        self.assertEqual((h["cupsWidth"], h["cupsHeight"]), (4, 4))
        self.assertEqual(rows, [b"\xff" * 12,
                               b"\xff" * 3 + bytes([255, 0, 0, 0, 255, 0]) + b"\xff" * 3,
                               b"\xff" * 3 + bytes([0, 0, 255, 0, 0, 0]) + b"\xff" * 3,
                               b"\xff" * 12])
        self.assertEqual(end, len(result.stdout))

    def test_gray_conversion(self):
        result = self.convert(raster(), "ColorModel=Gray")
        self.assertEqual(result.returncode, 0, result.stderr)
        h = parse_header(result.stdout[4:4 + HEADER_LEN])
        rows, _ = decode_page(result.stdout, 4 + HEADER_LEN, h)
        self.assertEqual(h["cupsColorSpace"], 18)
        self.assertEqual(rows[1:3], [bytes([255, 76, 150, 255]), bytes([255, 27, 0, 255])])

    def test_rejects_invalid_geometry(self):
        cases = [dict(cupsImagingBBox=[0, 0, 2, float("nan")]),
                 dict(cupsImagingBBox=[0, 0, 2, float("-inf")]),
                 dict(cupsImagingBBox=[1e20, 0, 2e20, 2]),
                 dict(cupsPageSize=[1e8, 4], HWResolution=[1, 72]),
                 dict(cupsPageSize=[float("nan"), 4]),
                 dict(cupsBytesPerLine=5)]
        for case in cases:
            with self.subTest(case=case):
                result = self.convert(raster(**case))
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(b"ERROR:", result.stderr)
                self.assertNotIn(b"runtime error:", result.stderr)
                self.assertNotIn(b"AddressSanitizer", result.stderr)

    def test_truncated_pixels_fail(self):
        result = self.convert(raster()[:-1])
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"Truncated", result.stderr)


CAPS = b'''<scan:ScannerCapabilities xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03"
 xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"><pwg:Version>2.63</pwg:Version>
 <scan:Platen><scan:PlatenInputCaps><scan:MaxWidth>2550</scan:MaxWidth>
 <scan:MaxHeight>3507</scan:MaxHeight></scan:PlatenInputCaps></scan:Platen>
 </scan:ScannerCapabilities>'''
STATUS = b'<ScannerStatus xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"><pwg:State>Idle</pwg:State></ScannerStatus>'


@contextlib.contextmanager
def scanner_server(pages, location="/eSCL/ScanJobs/job", caps=CAPS):
    requests = []
    replies = iter(pages)
    disconnected = False

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, code, data=b"", headers=None):
            self.send_response(code)
            self.send_header("Content-Length", str(len(data)))
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            nonlocal disconnected
            requests.append(("GET", self.path))
            if self.path.endswith("ScannerCapabilities"):
                self.reply(200, caps)
            elif self.path.endswith("ScannerStatus"):
                self.reply(200, STATUS)
            elif self.path.endswith("NextDocument"):
                response = None if disconnected else next(replies, (404, b""))
                if response is None:
                    disconnected = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                else:
                    self.reply(*response)
            else:
                self.reply(404)

        def do_POST(self):
            requests.append(("POST", self.path))
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            self.reply(201, headers={"Location": location})

        def do_DELETE(self):
            requests.append(("DELETE", self.path))
            self.reply(200)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_port, requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class ScannerTests(unittest.TestCase):
    def run_client(self, client, port, output, *args):
        return subprocess.run(client + ["--host", "127.0.0.1", "--port", str(port),
                                       "--out", str(output), *args],
                              capture_output=True, text=True, timeout=15)

    def test_invalid_options_fail_before_network(self):
        cases = [["--port", "0"], ["--port", "65536"], ["--port", "oops"],
                 ["--dpi", "0"], ["--dpi", "oops"], ["--rotate", "45"],
                 ["--threshold", "255"], ["--crop", "nanx10"],
                 ["--crop", "infx10"], ["--crop", "0x10"],
                 ["--crop", "bad"], ["--intent", "bad"],
                 ["--out"], ["--host"], ["--path"], ["--crop"], ["--dpi"]]
        for client in CLIENTS:
            for args in cases:
                with self.subTest(client=client, args=args):
                    result = subprocess.run(client + ["--host", "127.0.0.1", *args],
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertNotIn("Scanning", result.stderr)

    def test_job_locations_and_cleanup(self):
        for client in CLIENTS:
            for location in ["/eSCL/ScanJobs/job", "ScanJobs/job",
                             "http://unreachable.invalid/eSCL/ScanJobs/job%20id"]:
                with self.subTest(client=client, location=location), tempfile.TemporaryDirectory() as tmp:
                    with scanner_server([(200, b"scan bytes"), (410, b"")], location) as (port, requests):
                        output = Path(tmp) / "scan.raw"
                        result = self.run_client(client, port, output, "--raw")
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(output.read_bytes(), b"scan bytes")
                        expected = "/eSCL/ScanJobs/" + ("job%20id" if "%20" in location else "job")
                        self.assertIn(("GET", expected + "/NextDocument"), requests)
                        self.assertIn(("DELETE", expected), requests)

    def test_transfer_errors_fail_and_delete_job(self):
        for client in CLIENTS:
            for pages in [[(500, b"")], [(200, b"page 1"), (500, b"")],
                          [(200, b"page 1"), None], [(200, b"")]]:
                with self.subTest(client=client, pages=pages), tempfile.TemporaryDirectory() as tmp:
                    with scanner_server(pages, "http://127.0.0.1/eSCL/ScanJobs/job") as (port, requests):
                        output = Path(tmp) / "scan.raw"
                        result = self.run_client(client, port, output, "--raw")
                        self.assertEqual(result.returncode, 1, result.stderr)
                        self.assertFalse(output.exists())
                        self.assertIn(("DELETE", "/eSCL/ScanJobs/job"), requests)

    def test_invalid_platen_fails_before_scanning(self):
        for client in CLIENTS:
            with self.subTest(client=client), tempfile.TemporaryDirectory() as tmp:
                with scanner_server([], caps=CAPS.replace(b">2550<", b">0<")) as (port, requests):
                    result = self.run_client(client, port, Path(tmp) / "scan.png", "--crop", "a6")
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertFalse(any(method == "POST" for method, _ in requests))

    def test_native_image_processing(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp) / "source.png", Path(tmp) / "scan.png"
            write_png(source, [bytes([0, 255]), bytes([64, 128]), bytes([192, 32])], 2, 3, 1)
            for crop, expected in [("a6", (1, 1)), ("9" * 308 + "x" + "9" * 308, (3, 2))]:
                with self.subTest(crop=crop), scanner_server([(200, source.read_bytes())]) as (port, _):
                    result = self.run_client([SCANNER], port, output, "--rotate", "90",
                                             "--mode", "gray", "--crop", crop)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(struct.unpack(">II", output.read_bytes()[16:24]), expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
