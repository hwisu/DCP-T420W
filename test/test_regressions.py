#!/usr/bin/env python3
"""Offline regression tests. Build filter/ and scanner/ before running.

Rasters contain a tiny image on supported media; scanners are loopback servers.
No test discovers, installs, scans from or prints to a physical device.
Set BROTHER_FILTER / BROTHER_SCANNER to test sanitizer or packaged binaries.
"""

import contextlib
import http.server
import os
from pathlib import Path
import re
import select
import socket
import signal
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
    # A 2x2 image offset by one pixel on 3.5x5 inch paper at 300 dpi.
    values = dict(HWResolution=[300, 300], cupsPageSize=[252, 360],
                  PageSize=[252, 360], cupsImagingBBox=[0.24, 359.28, 0.72, 359.76],
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


def urf():
    # A blank 3.5x5 inch W8 page: row repetition plus clear-to-end packets.
    header = bytearray(32)
    header[0] = 8
    header[12:24] = struct.pack(">III", 1050, 1500, 300)
    return b"UNIRAST\0" + bytes(4) + header + b"\xff\x80" * 5 + b"\xdb\x80"


def pdf_page_size(path):
    # Quartz emits ordinary page objects. Resolve inherited page boxes as
    # well as explicit ones without adding a third-party PDF dependency.
    objects = dict(re.findall(rb"(\d+)\s+0\s+obj\b(.*?)endobj", path.read_bytes(), re.S))
    page, = [obj for obj in objects.values() if re.search(rb"/Type\s*/Page\b", obj)]
    while (box := re.search(rb"/MediaBox\s*\[([^]]+)\]", page)) is None:
        parent = re.search(rb"/Parent\s+(\d+)\s+0\s+R", page)
        page = objects[parent[1]]
    x0, y0, x1, y1 = map(float, box[1].split())
    return x1 - x0, y1 - y0


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
        self.assertEqual((h["cupsWidth"], h["cupsHeight"]), (1050, 1500))
        expected = [b"\xff" * 3150] * 1500
        expected[1] = b"\xff" * 3 + bytes([255, 0, 0, 0, 255, 0]) + b"\xff" * 3141
        expected[2] = b"\xff" * 3 + bytes([0, 0, 255, 0, 0, 0]) + b"\xff" * 3141
        self.assertEqual(rows, expected)
        self.assertEqual(end, len(result.stdout))

    def test_gray_conversion(self):
        result = self.convert(raster(), "ColorModel=Gray")
        self.assertEqual(result.returncode, 0, result.stderr)
        h = parse_header(result.stdout[4:4 + HEADER_LEN])
        rows, _ = decode_page(result.stdout, 4 + HEADER_LEN, h)
        self.assertEqual(h["cupsColorSpace"], 18)
        self.assertEqual(rows[1:3], [bytes([255, 76, 150]) + b"\xff" * 1047,
                                    bytes([255, 27, 0]) + b"\xff" * 1047])

    def test_rejects_invalid_geometry(self):
        cases = [dict(cupsImagingBBox=[0, 0, 2, float("nan")]),
                 dict(cupsImagingBBox=[0, 0, 2, float("-inf")]),
                 dict(cupsImagingBBox=[1e20, 0, 2e20, 2]),
                 dict(cupsPageSize=[1e8, 4], HWResolution=[1, 72]),
                 dict(cupsPageSize=[float("nan"), 4]),
                 dict(cupsBytesPerLine=5),
                 dict(cupsPageSize=[-252, 360]),
                 dict(cupsPageSize=[0, 360]),
                 dict(cupsImagingBBox=[-10, 0, 2, 2]),
                 dict(cupsImagingBBox=[0, 0, 253, 360]),
                 dict(cupsImagingBBox=[0, 360, 2, 359]),
                 dict(cupsWidth=1052, cupsBytesPerLine=3156),
                 dict(cupsHeight=1502),
                 dict(cupsBytesPerLine=0xffffffff),
                 dict(cupsImagingBBox=[252, 0, 252.24, 0.24])]
        for case in cases:
            with self.subTest(case=case):
                result = self.convert(raster(**case))
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(b"ERROR:", result.stderr)
                self.assertNotIn(b"runtime error:", result.stderr)
                self.assertNotIn(b"AddressSanitizer", result.stderr)
                self.assertNotIn(b"PAGE:", result.stderr)
                self.assertLessEqual(len(result.stdout), 4)

    def test_rejects_unsupported_device_settings(self):
        cases = [dict(HWResolution=[1200, 1200]), dict(HWResolution=[300, 600]),
                 dict(HWResolution=[0, 0]), dict(HWResolution=[1, 1]),
                 dict(cupsPageSize=[2834.6457, 360]),
                 dict(cupsPageSize=[252, 1100]), dict(cupsPageSize=[250, 360]),
                 dict(cupsPageSize=[252, 350]), dict(NumCopies=10)]
        for case in cases:
            with self.subTest(case=case):
                result = self.convert(raster(**case))
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(b"ERROR:", result.stderr)
                self.assertLessEqual(len(result.stdout), 4)

    def test_integer_page_size_fallback(self):
        result = self.convert(raster(cupsPageSize=[0, 0]))
        self.assertEqual(result.returncode, 0, result.stderr)
        h = parse_header(result.stdout[4:4 + HEADER_LEN])
        self.assertEqual((h["cupsWidth"], h["cupsHeight"]), (1050, 1500))

    def test_conflicting_borderless_plain_paper_fails(self):
        result = self.convert(raster(), "PageSize=A4.Borderless MediaType=Stationery")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"Conflicting print options", result.stderr)
        self.assertEqual(result.stdout, b"")

    def test_closed_output_pipe_fails_without_sigpipe(self):
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        try:
            result = subprocess.run([FILTER, "1", "test", "test", "1", ""],
                                    input=raster(), stdout=write_fd, stderr=subprocess.PIPE,
                                    env={**os.environ, "PPD": str(ROOT / "ppd/Brother-DCP-T420W.ppd")},
                                    timeout=10)
        finally:
            os.close(write_fd)
        self.assertNotEqual(result.returncode, -signal.SIGPIPE)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"ERROR:", result.stderr)

    def test_cancel_while_waiting_for_pixels(self):
        env = {**os.environ, "PPD": str(ROOT / "ppd/Brother-DCP-T420W.ppd")}
        with subprocess.Popen([FILTER, "1", "test", "test", "1", ""],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env=env) as process:
            try:
                # Hold the input open after the header, as a slow upstream
                # renderer would. The filter must catch cancellation.
                process.stdin.write(raster()[:4 + HEADER_LEN])
                process.stdin.flush()
                ready, _, _ = select.select([process.stdout], [], [], 5)
                self.assertTrue(ready, "filter did not start writing the page")
                os.read(process.stdout.fileno(), 4)
                process.send_signal(signal.SIGTERM)
                _, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertIn(b"Job canceled", stderr)
                self.assertNotIn(b"PAGE:", stderr)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_pwg_input_round_trip(self):
        first = self.convert(raster())
        self.assertEqual(first.returncode, 0, first.stderr)
        second = self.convert(first.stdout)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(first.stdout, second.stdout)

    def test_truncated_pixels_fail(self):
        result = self.convert(raster()[:-1])
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"Truncated", result.stderr)
        self.assertNotIn(b"PAGE:", result.stderr)

    def test_page_boundaries_and_truncated_headers(self):
        cups = raster()
        compressed = (b"RaS2" + cups[4:4 + HEADER_LEN]
                      + b"\0\xff" + cups[-12:-6] + b"\0\xff" + cups[-6:])
        pwg = self.convert(cups)
        self.assertEqual(pwg.returncode, 0, pwg.stderr)
        # Small compressed pages deliberately fit in a single read buffer,
        # exposing any accidental prefetch of the following partial header.
        for name, data, prefix, header_len in [
            ("CUPS", cups, 4, HEADER_LEN),
            ("compressed CUPS", compressed, 4, HEADER_LEN),
            ("PWG", pwg.stdout, 4, HEADER_LEN),
            ("URF", urf(), 12, 32),
        ]:
            for pages in (1, 2):
                with self.subTest(format=name, pages=pages):
                    result = self.convert(data + data[prefix:] * (pages - 1))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stderr.count(b"PAGE:"), pages)
            for cut in (1, header_len // 2, header_len - 1, header_len):
                for complete_pages in (0, 1):
                    with self.subTest(format=name, cut=cut, complete_pages=complete_pages):
                        # The full-length case is an invalid all-zero header.
                        partial = data[prefix:prefix + cut] if cut < header_len else bytes(cut)
                        result = self.convert((data if complete_pages else data[:prefix]) + partial)
                        self.assertEqual(result.returncode, 1, result.stderr)
                        self.assertIn(b"ERROR:", result.stderr)
                        if cut < header_len:
                            self.assertIn(b"raster page header", result.stderr)
                        self.assertEqual(result.stderr.count(b"PAGE:"), complete_pages)

    def test_compressed_packets_and_truncation(self):
        # Mix literal/repeated pixels, repeated rows and the white-fill code.
        # Compare the pixels with uncompressed input, including packet payloads
        # crossing the reader's block boundary.
        width, height = 128, 200
        row = bytes(range(256)) + bytes(range(128))
        raw = raster(cupsWidth=width, cupsHeight=height, cupsBytesPerLine=len(row),
                     cupsImagingBBox=[0, 0, 0, 0])[:4 + HEADER_LEN]
        raw += row * (height - 1) + bytes([255]) * len(row)
        packed = b"RaS2" + raw[4:4 + HEADER_LEN]
        packed += (b"\0\x81" + row) * (height - 1) + b"\0\x80"
        expected = self.convert(raw)
        self.assertEqual(expected.returncode, 0, expected.stderr)
        result = self.convert(packed)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected.stdout)
        for cut in (1, 20, 385):
            with self.subTest(cut=cut):
                result = self.convert(packed[:-cut])
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(b"Truncated", result.stderr)
                self.assertNotIn(b"PAGE:", result.stderr)


CAPS = b'''<scan:ScannerCapabilities xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03"
 xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"><pwg:Version>2.63</pwg:Version>
 <scan:Platen><scan:PlatenInputCaps><scan:MaxWidth>2550</scan:MaxWidth>
 <scan:MaxHeight>3507</scan:MaxHeight></scan:PlatenInputCaps></scan:Platen>
 </scan:ScannerCapabilities>'''
STATUS = b'<ScannerStatus xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"><pwg:State>Idle</pwg:State></ScannerStatus>'


@contextlib.contextmanager
def scanner_server(pages, location="/eSCL/ScanJobs/job", caps=CAPS,
                   caps_status=200, create_status=201):
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
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass  # Cancellation can close a deliberately stalled transfer.

        def do_GET(self):
            nonlocal disconnected
            requests.append(("GET", self.path))
            if self.path.endswith("ScannerCapabilities"):
                self.reply(caps_status, caps)
            elif self.path.endswith("ScannerStatus"):
                self.reply(200, STATUS)
            elif self.path.endswith("NextDocument"):
                response = None if disconnected else next(replies, (404, b""))
                if callable(response):
                    response = response()
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
            self.reply(create_status, headers={"Location": location})

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
        cases = [CAPS.replace(b">2550<", b">" + value + b"<")
                 for value in (b"0", b"-1", b"oops", b"", b"2147483648")]
        cases += [CAPS.replace(b"PlatenInputCaps", b"AdfInputCaps"), b"not xml"]
        for client in CLIENTS:
            for caps in cases:
                for args in ([], ["--caps"]):
                    with self.subTest(client=client, caps=caps, args=args), tempfile.TemporaryDirectory() as tmp:
                        with scanner_server([], caps=caps) as (port, requests):
                            output = Path(tmp) / "scan.png"
                            result = self.run_client(client, port, output, *args)
                            self.assertEqual(result.returncode, 1, result.stderr)
                            self.assertNotIn("Traceback", result.stderr)
                            self.assertFalse(output.exists())
                            self.assertFalse(any(method == "POST" for method, _ in requests))

    def test_capabilities_http_error_fails_before_scanning(self):
        for client in CLIENTS:
            with self.subTest(client=client), tempfile.TemporaryDirectory() as tmp:
                with scanner_server([], caps_status=500) as (port, requests):
                    result = self.run_client(client, port, Path(tmp) / "scan.raw", "--raw")
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("HTTP 500", result.stderr)
                    self.assertFalse(any(method == "POST" for method, _ in requests))

    def test_unexpected_job_status_fails_before_downloading(self):
        for client in CLIENTS:
            with self.subTest(client=client), tempfile.TemporaryDirectory() as tmp:
                with scanner_server([(200, b"page")], create_status=202) as (port, requests):
                    output = Path(tmp) / "scan.raw"
                    result = self.run_client(client, port, output, "--raw")
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("HTTP 202", result.stderr)
                    self.assertFalse(output.exists())
                    self.assertFalse(any("NextDocument" in path for _, path in requests))

    def test_multiple_pages_keep_distinct_output_names(self):
        for client in CLIENTS:
            for name, second_name in [("scan", "scan-2"), ("scan.raw", "scan-2.raw"),
                                      (".scan", ".scan-2")]:
                with self.subTest(client=client, name=name), tempfile.TemporaryDirectory(suffix=".scans") as tmp:
                    with scanner_server([(200, b"page 1"), (200, b"page 2")]) as (port, requests):
                        output = Path(tmp) / name
                        result = self.run_client(client, port, output, "--raw")
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(output.read_bytes(), b"page 1")
                        self.assertEqual((Path(tmp) / second_name).read_bytes(), b"page 2")
                        self.assertIn(("DELETE", "/eSCL/ScanJobs/job"), requests)

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

    def test_pdf_physical_dimensions(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp) / "source.png", Path(tmp) / "scan.pdf"
            # The real device's fixed frame has different density on each axis.
            write_png(source, [bytes([64, 128, 192]) * 1680] * 2195, 1680, 2195, 3)
            cases = [([], (215.9, 296.926)),
                     (["--dpi", "600"], (215.9, 296.926)),
                     (["--crop", "a6"], (105, 148)),
                     (["--crop", "a6", "--rotate", "90", "--mode", "gray"], (148, 105)),
                     (["--rotate", "270", "--mode", "lineart"], (296.926, 215.9)),
                     (["--crop", "999x999", "--rotate", "180"], (215.9, 296.926))]
            for client in CLIENTS:
                for args, dimensions_mm in cases:
                    with self.subTest(client=client, args=args):
                        with scanner_server([(200, source.read_bytes())]) as (port, _):
                            result = self.run_client(client, port, output, *args)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        for actual, expected in zip(pdf_page_size(output), dimensions_mm):
                            # Cropping rounds to a physical source pixel.
                            self.assertAlmostEqual(actual * 25.4 / 72, expected, delta=0.15)

    def test_native_cancellation_releases_job(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            for first_page in (False, True):
                with self.subTest(signal=signum, first_page=first_page), tempfile.TemporaryDirectory() as tmp:
                    started, release = threading.Event(), threading.Event()

                    def stalled_page():
                        started.set()
                        release.wait(10)
                        return 200, b"late page"

                    pages = ([(200, b"first page")] if first_page else []) + [stalled_page]
                    with scanner_server(pages) as (port, requests):
                        output = Path(tmp) / "scan.raw"
                        with subprocess.Popen([SCANNER, "--host", "127.0.0.1", "--port", str(port),
                                               "--raw", "--out", str(output)],
                                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
                            try:
                                self.assertTrue(started.wait(5), "scan transfer did not start")
                                process.send_signal(signum)
                                stdout, stderr = process.communicate(timeout=5)
                                self.assertEqual(process.returncode, 128 + signum, stderr)
                                self.assertIn(b"interrupted", stderr)
                                self.assertNotIn(b"Wrote", stdout)
                                self.assertFalse(output.exists())
                                self.assertEqual(requests.count(("DELETE", "/eSCL/ScanJobs/job")), 1)
                            finally:
                                release.set()
                                if process.poll() is None:
                                    process.kill()
                                    process.communicate()


if __name__ == "__main__":
    unittest.main(verbosity=2)
