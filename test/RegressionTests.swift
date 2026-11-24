// Offline regression tests for PWG tools, rastertobrother filter, and brscan client.

import CoreGraphics
import Darwin
import Foundation

// MARK: - Synthetic fixtures

func makeRaster(overrides: [String: PWGFieldValue] = [:]) -> Data {
    // A 2x2 image offset by one pixel on 3.5x5 inch paper at 300 dpi.
    var values: [String: PWGFieldValue] = [
        "HWResolution": .uints([300, 300]),
        "cupsPageSize": .floats([252, 360]),
        "PageSize": .uints([252, 360]),
        "cupsImagingBBox": .floats([0.24, 359.28, 0.72, 359.76]),
        "cupsWidth": .uint(2),
        "cupsHeight": .uint(2),
        "cupsBitsPerColor": .uint(8),
        "cupsBitsPerPixel": .uint(24),
        "cupsBytesPerLine": .uint(6),
        "cupsColorSpace": .uint(19),
        "cupsNumColors": .uint(3),
        "NumCopies": .uint(1),
    ]
    for (key, value) in overrides {
        values[key] = value
    }
    var out = Data("RaS3".utf8)
    out.append(buildPWGHeader(overrides: values))
    // Uncompressed, big-endian CUPS v3, with red/green then blue/black pixels.
    out.append(contentsOf: [255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0])
    return out
}

func makeURF() -> Data {
    // A blank 3.5x5 inch W8 page: row repetition plus clear-to-end packets.
    var header = Data(count: 32)
    header[0] = 8
    let values: [UInt32] = [1050, 1500, 300]
    for (idx, v) in values.enumerated() {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { bytes in
            header.replaceSubrange((12 + idx * 4)..<(16 + idx * 4), with: bytes)
        }
    }
    var out = Data("UNIRAST\0".utf8)
    out.append(Data(count: 4))
    out.append(header)
    for _ in 0..<5 {
        out.append(contentsOf: [0xff, 0x80])
    }
    out.append(contentsOf: [0xdb, 0x80])
    return out
}

func pdfPageSize(at url: URL) throws -> (Double, Double) {
    guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) else {
        throw TestFailure("Could not open PDF page: \(url.path)")
    }
    let box = page.getBoxRect(.mediaBox)
    return (Double(box.width), Double(box.height))
}

private func repeatingBytes(_ bytes: [UInt8], count: Int) -> Data {
    var out = Data()
    out.reserveCapacity(bytes.count * count)
    for _ in 0..<count {
        out.append(contentsOf: bytes)
    }
    return out
}

// MARK: - PWGToolTests

func pwgToolTests() -> [TestCase] {
    [
        TestCase(name: "PWGToolTests.test_white_fill_and_page_boundaries") {
            let header = makeRaster().subdata(in: 4..<(4 + pwgHeaderLength))
            let first = header + Data([0x01, 0x00, 0x12, 0x34, 0x56, 0x80])
            let second = header + Data([0x01, 0x80])
            let data = Data("RaS2".utf8) + first + second
            try withTempDir { tmp in
                let path = tmp.appendingPathComponent("two-pages.pwg")
                try data.write(to: path)
                let pages = try readPWGHeaders(path: path.path)
                try expectEqual(pages.count, 2)
                let (rows1, end1) = try decodePWGPage(
                    data, offset: 4 + pwgHeaderLength, header: pages[0].header)
                try expectEqual(
                    rows1,
                    [
                        Data([0x12, 0x34, 0x56, 0xff, 0xff, 0xff]),
                        Data([0x12, 0x34, 0x56, 0xff, 0xff, 0xff]),
                    ])
                try expectEqual(end1, 4 + first.count)
                let (rows2, end2) = try decodePWGPage(
                    data, offset: end1 + pwgHeaderLength, header: pages[1].header)
                let allWhite = Data(repeating: 0xff, count: 6)
                try expectEqual(rows2, [allWhite, allWhite])
                try expectEqual(end2, data.count)
            }
        },
        TestCase(name: "PWGToolTests.test_truncated_packets") {
            let header = try parsePWGHeader(makeRaster(), offset: 4)
            let bands: [Data] = [
                Data(),
                Data([0x01]),
                Data([0x01, 0x01, 0x12]),
                Data([0x01, 0xff, 0x12, 0x34, 0x56]),
            ]
            for band in bands {
                try expectThrows(PWGError.self, "band=\([UInt8](band))") {
                    _ = try decodePWGPage(band, offset: 0, header: header)
                }
            }
        },
    ]
}

// MARK: - RasterTests

private func convertRaster(_ data: Data, options: String = "") throws -> ProcessResult {
    var env = ProcessInfo.processInfo.environment
    env["PPD"] = TestConfig.ppd
    return try runProcess(
        TestConfig.filter, ["1", "test", "test", "1", options],
        stdin: data, env: env, timeout: 10)
}

func rasterTests() -> [TestCase] {
    [
        TestCase(name: "RasterTests.test_padding_and_pixels") {
            let result = try convertRaster(makeRaster())
            try expectEqual(result.returncode, 0, result.stderrText)
            let h = try parsePWGHeader(result.stdout, offset: 4)
            let (rows, end) = try decodePWGPage(
                result.stdout, offset: 4 + pwgHeaderLength, header: h)
            try expectEqual(h.uint("cupsWidth"), 1050)
            try expectEqual(h.uint("cupsHeight"), 1500)
            let blank = Data(repeating: 0xff, count: 3150)
            var expected = Array(repeating: blank, count: 1500)
            expected[1] =
                Data([0xff, 0xff, 0xff, 255, 0, 0, 0, 255, 0])
                + Data(repeating: 0xff, count: 3141)
            expected[2] =
                Data([0xff, 0xff, 0xff, 0, 0, 255, 0, 0, 0])
                + Data(repeating: 0xff, count: 3141)
            try expectEqual(rows, expected)
            try expectEqual(end, result.stdout.count)
        },
        TestCase(name: "RasterTests.test_gray_conversion") {
            let result = try convertRaster(makeRaster(), options: "ColorModel=Gray")
            try expectEqual(result.returncode, 0, result.stderrText)
            let h = try parsePWGHeader(result.stdout, offset: 4)
            let (rows, _) = try decodePWGPage(
                result.stdout, offset: 4 + pwgHeaderLength, header: h)
            try expectEqual(h.uint("cupsColorSpace"), 18)
            try expectEqual(
                rows[1], Data([255, 76, 150]) + Data(repeating: 0xff, count: 1047))
            try expectEqual(
                rows[2], Data([255, 27, 0]) + Data(repeating: 0xff, count: 1047))
        },
        TestCase(name: "RasterTests.test_aligned_rows_and_gray_input") {
            // Exercise every 32-bit alignment remainder with nonwhite padding.
            // Neither alignment bytes nor the last image row may leak into margins.
            for (channels, space) in [(1, UInt32(18)), (3, UInt32(19))] {
                for width in 1...4 {
                    let pixels: [Data] = (0..<2).map { y in
                        Data((0..<(width * channels)).map { i in UInt8((i * 53 + y * 79) % 255) })
                    }
                    let rawLen = width * channels
                    let alignedLen = (rawLen + 3) & ~3
                    let strides = rawLen == alignedLen ? [rawLen] : [rawLen, alignedLen]
                    for stride in strides where stride % channels == 0 {
                        var source = makeRaster(overrides: [
                            "cupsWidth": .uint(UInt32(width)),
                            "cupsBytesPerLine": .uint(UInt32(stride)),
                            "cupsBitsPerPixel": .uint(UInt32(channels * 8)),
                            "cupsColorSpace": .uint(space),
                            "cupsNumColors": .uint(UInt32(channels)),
                            "cupsImagingBBox": .floats([
                                0.24, 359.28, Float(width + 1) * 0.24, 359.76,
                            ]),
                        ]).prefix(4 + pwgHeaderLength)
                        for row in pixels {
                            source.append(row)
                            source.append(Data(repeating: 0x7f, count: stride - row.count))
                        }
                        let grayModes = channels == 3 ? [false, true] : [false]
                        for gray in grayModes {
                            let options = gray ? "ColorModel=Gray" : ""
                            let result = try convertRaster(source, options: options)
                            try expectEqual(result.returncode, 0, result.stderrText)
                            let h = try parsePWGHeader(result.stdout, offset: 4)
                            let (rows, end) = try decodePWGPage(
                                result.stdout, offset: 4 + pwgHeaderLength, header: h)
                            let outChannels = gray ? 1 : channels
                            try expectEqual(
                                h.uint("cupsColorSpace"), outChannels == 1 ? 18 : 19)
                            let blank = Data(repeating: 0xff, count: 1050 * outChannels)
                            var expected = Array(repeating: blank, count: 1500)
                            for (idx, row) in pixels.enumerated() {
                                let transformed: Data
                                if gray {
                                    var gRow = Data()
                                    gRow.reserveCapacity(width)
                                    for x in 0..<width {
                                        let r = Int(row[x * 3])
                                        let g = Int(row[x * 3 + 1])
                                        let b = Int(row[x * 3 + 2])
                                        gRow.append(UInt8((77 * r + 151 * g + 28 * b) >> 8))
                                    }
                                    transformed = gRow
                                } else {
                                    transformed = row
                                }
                                expected[idx + 1] =
                                    Data(repeating: 0xff, count: outChannels)
                                    + transformed
                                    + Data(repeating: 0xff, count: (1049 - width) * outChannels)
                            }
                            try expectEqual(rows, expected)
                            try expectEqual(end, result.stdout.count)

                            let truncated = try convertRaster(source.dropLast(), options: options)
                            try expectEqual(truncated.returncode, 1, truncated.stderrText)
                            try expectTrue(truncated.stderrText.contains("Truncated"))
                            try expectFalse(truncated.stderrText.contains("PAGE:"))
                        }
                    }
                }
            }
        },
        TestCase(name: "RasterTests.test_media_choices_and_legacy_bp71") {
            let pairs = [
                ("Stationery", "stationery"),
                ("StationeryInkjet", "stationery-inkjet"),
                ("PhotographicGlossy", "photographic-glossy"),
                ("com.brother-bp71", "com.brother-bp71"),
                ("Com.brotherBp71", "com.brother-bp71"),
            ]
            for (choice, keyword) in pairs {
                let result = try convertRaster(makeRaster(), options: "MediaType=\(choice)")
                try expectEqual(result.returncode, 0, result.stderrText)
                let h = try parsePWGHeader(result.stdout, offset: 4)
                try expectEqual(h.string("MediaType"), keyword, choice)
            }
        },
        TestCase(name: "RasterTests.test_cups_backend_media_mapping") {
            guard let handle = dlopen("/usr/lib/libcups.2.dylib", RTLD_LAZY) else {
                try fail("Failed to dlopen libcups.2.dylib")
            }
            defer { dlclose(handle) }

            typealias OpenPPD = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
            typealias ClosePPD = @convention(c) (UnsafeMutableRawPointer?) -> Void
            typealias CreateCache =
                @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
            typealias DestroyCache = @convention(c) (UnsafeMutableRawPointer?) -> Void
            typealias GetType =
                @convention(c) (
                    UnsafeMutableRawPointer?, UnsafePointer<CChar>?
                ) -> UnsafePointer<CChar>?

            func sym<T>(_ name: String, as type: T.Type) throws -> T {
                guard let ptr = dlsym(handle, name) else {
                    try fail("Missing CUPS symbol \(name)")
                }
                return unsafeBitCast(ptr, to: type)
            }

            let ppdOpenFile = try sym("ppdOpenFile", as: OpenPPD.self)
            let ppdClose = try sym("ppdClose", as: ClosePPD.self)
            let cacheCreate = try sym("_ppdCacheCreateWithPPD", as: CreateCache.self)
            let cacheDestroy = try sym("_ppdCacheDestroy", as: DestroyCache.self)
            let cacheGetType = try sym("_ppdCacheGetType", as: GetType.self)

            let ppd = TestConfig.ppd.withCString { ppdOpenFile($0) }
            try expectTrue(ppd != nil, "ppdOpenFile failed")
            defer { ppdClose(ppd) }

            let cache = cacheCreate(ppd)
            try expectTrue(cache != nil, "_ppdCacheCreateWithPPD failed")
            defer { cacheDestroy(cache) }

            let checks = [
                ("Stationery", "stationery"),
                ("StationeryInkjet", "stationery-inkjet"),
                ("PhotographicGlossy", "photographic-glossy"),
                ("com.brother-bp71", "com.brother-bp71"),
            ]
            for (choice, expected) in checks {
                let actualPtr = choice.withCString { cacheGetType(cache, $0) }
                try expectTrue(actualPtr != nil, "null media type for \(choice)")
                try expectEqual(String(cString: actualPtr!), expected, choice)
            }
        },
        TestCase(name: "RasterTests.test_rejects_invalid_geometry") {
            let cases: [[String: PWGFieldValue]] = [
                ["cupsImagingBBox": .floats([0, 0, 2, .nan])],
                ["cupsImagingBBox": .floats([0, 0, 2, -.infinity])],
                ["cupsImagingBBox": .floats([1e20, 0, 2e20, 2])],
                ["cupsPageSize": .floats([1e8, 4]), "HWResolution": .uints([1, 72])],
                ["cupsPageSize": .floats([.nan, 4])],
                ["cupsBytesPerLine": .uint(5)],
                ["cupsPageSize": .floats([-252, 360])],
                ["cupsPageSize": .floats([0, 360])],
                ["cupsImagingBBox": .floats([-10, 0, 2, 2])],
                ["cupsImagingBBox": .floats([0, 0, 253, 360])],
                ["cupsImagingBBox": .floats([0, 360, 2, 359])],
                ["cupsWidth": .uint(1052), "cupsBytesPerLine": .uint(3156)],
                ["cupsHeight": .uint(1502)],
                ["cupsBytesPerLine": .uint(0xffff_ffff)],
                ["cupsImagingBBox": .floats([252, 0, 252.24, 0.24])],
            ]
            for (idx, overrides) in cases.enumerated() {
                let result = try convertRaster(makeRaster(overrides: overrides))
                try expectEqual(result.returncode, 1, "case \(idx): \(result.stderrText)")
                try expectTrue(result.stderrText.contains("ERROR:"), "case \(idx)")
                try expectFalse(result.stderrText.contains("runtime error:"), "case \(idx)")
                try expectFalse(result.stderrText.contains("AddressSanitizer"), "case \(idx)")
                try expectFalse(result.stderrText.contains("PAGE:"), "case \(idx)")
                try expectTrue(
                    result.stdout.count <= 4, "case \(idx) stdout=\(result.stdout.count)")
            }
        },
        TestCase(name: "RasterTests.test_rejects_unsupported_device_settings") {
            let cases: [[String: PWGFieldValue]] = [
                ["HWResolution": .uints([1200, 1200])],
                ["HWResolution": .uints([300, 600])],
                ["HWResolution": .uints([0, 0])],
                ["HWResolution": .uints([1, 1])],
                ["cupsPageSize": .floats([2834.6457, 360])],
                ["cupsPageSize": .floats([252, 1100])],
                ["cupsPageSize": .floats([250, 360])],
                ["cupsPageSize": .floats([252, 350])],
                ["NumCopies": .uint(10)],
            ]
            for (idx, overrides) in cases.enumerated() {
                let result = try convertRaster(makeRaster(overrides: overrides))
                try expectEqual(result.returncode, 1, "case \(idx): \(result.stderrText)")
                try expectTrue(result.stderrText.contains("ERROR:"), "case \(idx)")
                try expectTrue(result.stdout.count <= 4, "case \(idx)")
            }
        },
        TestCase(name: "RasterTests.test_integer_page_size_fallback") {
            let result = try convertRaster(
                makeRaster(overrides: ["cupsPageSize": .floats([0, 0])]))
            try expectEqual(result.returncode, 0, result.stderrText)
            let h = try parsePWGHeader(result.stdout, offset: 4)
            try expectEqual(h.uint("cupsWidth"), 1050)
            try expectEqual(h.uint("cupsHeight"), 1500)
        },
        TestCase(name: "RasterTests.test_conflicting_borderless_plain_paper_fails") {
            let result = try convertRaster(
                makeRaster(), options: "PageSize=A4.Borderless MediaType=Stationery")
            try expectEqual(result.returncode, 1, result.stderrText)
            try expectTrue(result.stderrText.contains("Conflicting print options"))
            try expectEqual(result.stdout, Data())
        },
        TestCase(name: "RasterTests.test_closed_output_pipe_fails_without_sigpipe") {
            var fds: [Int32] = [0, 0]
            try expectEqual(Darwin.pipe(&fds), 0)
            Darwin.close(fds[0])
            let writeHandle = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
            defer { Darwin.close(fds[1]) }

            var env = ProcessInfo.processInfo.environment
            env["PPD"] = TestConfig.ppd
            let result = try runProcess(
                TestConfig.filter, ["1", "test", "test", "1", ""],
                stdin: makeRaster(), stdoutHandle: writeHandle, env: env, timeout: 10)
            try expectNotEqual(result.returncode, -SIGPIPE)
            try expectEqual(result.returncode, 1, result.stderrText)
            try expectTrue(result.stderrText.contains("ERROR:"))
        },
        TestCase(name: "RasterTests.test_cancel_while_waiting_for_pixels") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: TestConfig.filter)
            process.arguments = ["1", "test", "test", "1", ""]
            var env = ProcessInfo.processInfo.environment
            env["PPD"] = TestConfig.ppd
            process.environment = env

            let inPipe = Pipe()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = errPipe

            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            defer {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = done.wait(timeout: .now() + 2)
                }
            }

            // Hold the input open after the header, as a slow upstream renderer would.
            try inPipe.fileHandleForWriting.write(
                contentsOf: makeRaster().prefix(4 + pwgHeaderLength))

            var pollFd = pollfd(
                fd: outPipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&pollFd, 1, 5000)
            try expectTrue(ready > 0, "filter did not start writing the page")
            _ = try outPipe.fileHandleForReading.read(upToCount: 4)

            kill(process.processIdentifier, SIGTERM)
            let exited = done.wait(timeout: .now() + 5)
            try? inPipe.fileHandleForWriting.close()
            try expectEqual(exited, .success, "filter did not exit after SIGTERM")

            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(decoding: stderrData, as: UTF8.self)
            try expectEqual(process.terminationStatus, 0, stderrText)
            try expectTrue(stderrText.contains("Job canceled"), stderrText)
            try expectFalse(stderrText.contains("PAGE:"), stderrText)
        },
        TestCase(name: "RasterTests.test_pwg_input_round_trip") {
            let first = try convertRaster(makeRaster())
            try expectEqual(first.returncode, 0, first.stderrText)
            let second = try convertRaster(first.stdout)
            try expectEqual(second.returncode, 0, second.stderrText)
            try expectEqual(first.stdout, second.stdout)
        },
        TestCase(name: "RasterTests.test_truncated_pixels_fail") {
            let result = try convertRaster(makeRaster().dropLast())
            try expectEqual(result.returncode, 1, result.stderrText)
            try expectTrue(result.stderrText.contains("Truncated"))
            try expectFalse(result.stderrText.contains("PAGE:"))
        },
        TestCase(name: "RasterTests.test_page_boundaries_and_truncated_headers") {
            let cups = makeRaster()
            let compressed =
                Data("RaS2".utf8)
                + cups.subdata(in: 4..<(4 + pwgHeaderLength))
                + Data([0, 0xff]) + cups.subdata(in: (cups.count - 12)..<(cups.count - 6))
                + Data([0, 0xff]) + cups.suffix(6)
            let pwg = try convertRaster(cups)
            try expectEqual(pwg.returncode, 0, pwg.stderrText)

            let formats: [(String, Data, Int, Int)] = [
                ("CUPS", cups, 4, pwgHeaderLength),
                ("compressed CUPS", compressed, 4, pwgHeaderLength),
                ("PWG", pwg.stdout, 4, pwgHeaderLength),
                ("URF", makeURF(), 12, 32),
            ]
            for (name, data, prefix, headerLen) in formats {
                let pageBody = data.dropFirst(prefix)
                for pages in [1, 2] {
                    var stream = data
                    if pages == 2 { stream.append(pageBody) }
                    let result = try convertRaster(stream)
                    try expectEqual(
                        result.returncode, 0, "\(name) pages=\(pages): \(result.stderrText)")
                    let pageCount = result.stderrText.components(separatedBy: "PAGE:").count - 1
                    try expectEqual(pageCount, pages, "\(name) pages=\(pages)")
                }
                for cut in [1, headerLen / 2, headerLen - 1, headerLen] {
                    for completePages in [0, 1] {
                        let partial: Data =
                            if cut < headerLen {
                                data.subdata(in: prefix..<(prefix + cut))
                            } else {
                                Data(count: cut)
                            }
                        let input = (completePages == 1 ? data : data.prefix(prefix)) + partial
                        let result = try convertRaster(input)
                        try expectEqual(
                            result.returncode, 1, "\(name) cut=\(cut) complete=\(completePages)")
                        try expectTrue(result.stderrText.contains("ERROR:"), name)
                        if cut < headerLen {
                            try expectTrue(result.stderrText.contains("raster page header"), name)
                        }
                        let pageCount = result.stderrText.components(separatedBy: "PAGE:").count - 1
                        try expectEqual(pageCount, completePages, name)
                    }
                }
            }
        },
        TestCase(name: "RasterTests.test_compressed_packets_and_truncation") {
            let width = 128
            let height = 200
            let row = Data((0..<256).map { UInt8($0) }) + Data((0..<128).map { UInt8($0) })
            let header = makeRaster(overrides: [
                "cupsWidth": .uint(UInt32(width)),
                "cupsHeight": .uint(UInt32(height)),
                "cupsBytesPerLine": .uint(UInt32(row.count)),
                "cupsImagingBBox": .floats([0, 0, 0, 0]),
            ]).prefix(4 + pwgHeaderLength)
            var raw = header
            for _ in 0..<(height - 1) { raw.append(row) }
            raw.append(Data(repeating: 255, count: row.count))

            var packed = Data("RaS2".utf8) + header.dropFirst(4)
            let packedRow = Data([0, 0x81]) + row
            for _ in 0..<(height - 1) { packed.append(packedRow) }
            packed.append(contentsOf: [0, 0x80])

            let expected = try convertRaster(raw)
            try expectEqual(expected.returncode, 0, expected.stderrText)
            let result = try convertRaster(packed)
            try expectEqual(result.returncode, 0, result.stderrText)
            try expectEqual(result.stdout, expected.stdout)

            for cut in [1, 20, 385] {
                let truncated = try convertRaster(packed.dropLast(cut))
                try expectEqual(truncated.returncode, 1, "cut=\(cut): \(truncated.stderrText)")
                try expectTrue(truncated.stderrText.contains("Truncated"), "cut=\(cut)")
                try expectFalse(truncated.stderrText.contains("PAGE:"), "cut=\(cut)")
            }
        },
    ]
}

// MARK: - Loopback eSCL mock server

private let defaultCapsXML = Data(
    """
    <scan:ScannerCapabilities xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03"
     xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"><pwg:Version>2.63</pwg:Version>
     <scan:Platen><scan:PlatenInputCaps><scan:MaxWidth>2550</scan:MaxWidth>
     <scan:MaxHeight>3507</scan:MaxHeight></scan:PlatenInputCaps></scan:Platen>
     </scan:ScannerCapabilities>
    """.utf8)

private let defaultStatusXML = Data(
    """
    <ScannerStatus xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"><pwg:State>Idle</pwg:State></ScannerStatus>
    """.utf8)

enum MockPage {
    case reply(Int, Data)
    case disconnect
    case dynamic(@Sendable () -> MockPage)
}

final class MockScannerServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let location: String
    private let caps: Data
    private let capsStatus: Int
    private let createStatus: Int

    private let lock = NSLock()
    private var pages: [MockPage]
    private var pageIndex = 0
    private var disconnected = false
    private var recordedRequests: [(String, String)] = []
    private let acceptStopped = DispatchSemaphore(value: 0)
    private let clientGroup = DispatchGroup()

    init(
        pages: [MockPage],
        location: String = "/eSCL/ScanJobs/job",
        caps: Data = defaultCapsXML,
        capsStatus: Int = 200,
        createStatus: Int = 201
    ) throws {
        self.pages = pages
        self.location = location
        self.caps = caps
        self.capsStatus = capsStatus
        self.createStatus = createStatus

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestFailure("socket() failed: \(errno)") }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw TestFailure("bind() failed: \(errno)")
        }

        var actual = sockaddr_in()
        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &actualLen)
            }
        }
        guard named == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw TestFailure("listen() failed: \(errno)")
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: actual.sin_port)

        DispatchQueue.global().async { [weak self] in
            self?.acceptLoop()
        }
    }

    var requests: [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func stop() {
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        acceptStopped.wait()
        clientGroup.wait()
    }

    private func acceptLoop() {
        defer { acceptStopped.signal() }
        while true {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFD, $0, &len)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            var noSigPipe: Int32 = 1
            setsockopt(
                clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            clientGroup.enter()
            DispatchQueue.global().async { [weak self] in
                defer { self?.clientGroup.leave() }
                self?.handleClient(clientFD)
            }
        }
    }

    private func nextPageReply() -> MockPage {
        let chosen: MockPage = lock.withLock {
            if disconnected { return .disconnect }
            guard pageIndex < pages.count else { return .reply(404, Data()) }
            let item = pages[pageIndex]
            pageIndex += 1
            return item
        }
        if case .dynamic(let generator) = chosen {
            return generator()
        }
        return chosen
    }

    private func handleClient(_ fd: Int32) {
        var closed = false
        defer { if !closed { Darwin.close(fd) } }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Data.Index?

        while headerEnd == nil {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            headerEnd = buffer.range(of: separator)?.upperBound
        }

        guard let split = headerEnd else { return }
        let headerText = String(decoding: buffer[..<split], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        let requestParts = lines[0].split(separator: " ", maxSplits: 2)
        guard requestParts.count >= 2 else { return }
        let method = String(requestParts[0])
        let path = String(requestParts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                if name == "content-length",
                    let parsed = Int(
                        line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                {
                    contentLength = parsed
                }
            }
        }
        while buffer.count - split < contentLength {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }

        lock.withLock { recordedRequests.append((method, path)) }

        switch method {
        case "GET":
            if path.hasSuffix("ScannerCapabilities") {
                sendResponse(fd, status: capsStatus, body: caps)
            } else if path.hasSuffix("ScannerStatus") {
                sendResponse(fd, status: 200, body: defaultStatusXML)
            } else if path.hasSuffix("NextDocument") {
                switch nextPageReply() {
                case .disconnect:
                    lock.withLock { disconnected = true }
                    Darwin.shutdown(fd, SHUT_RDWR)
                    Darwin.close(fd)
                    closed = true
                case .reply(let code, let body):
                    sendResponse(fd, status: code, body: body)
                case .dynamic:
                    break
                }
            } else {
                sendResponse(fd, status: 404, body: Data())
            }
        case "POST":
            sendResponse(fd, status: createStatus, body: Data(), headers: ["Location": location])
        case "DELETE":
            sendResponse(fd, status: 200, body: Data())
        default:
            sendResponse(fd, status: 405, body: Data())
        }
    }

    private func sendResponse(
        _ fd: Int32, status: Int, body: Data, headers: [String: String] = [:]
    ) {
        var head = "HTTP/1.1 \(status) OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
        Darwin.shutdown(fd, SHUT_WR)
    }
}

private func withScannerServer(
    pages: [MockPage],
    location: String = "/eSCL/ScanJobs/job",
    caps: Data = defaultCapsXML,
    capsStatus: Int = 200,
    createStatus: Int = 201,
    _ body: (MockScannerServer) throws -> Void
) throws {
    let server = try MockScannerServer(
        pages: pages, location: location, caps: caps,
        capsStatus: capsStatus, createStatus: createStatus)
    defer { server.stop() }
    try body(server)
}

private func runScanner(port: UInt16, output: URL, _ args: [String]) throws -> ProcessResult {
    try runProcess(
        TestConfig.scanner,
        ["--host", "127.0.0.1", "--port", "\(port)", "--out", output.path] + args,
        timeout: 15)
}

// MARK: - ScannerTests

func scannerTests() -> [TestCase] {
    [
        TestCase(name: "ScannerTests.test_invalid_options_fail_before_network") {
            let cases = [
                ["--port", "0"], ["--port", "65536"], ["--port", "oops"],
                ["--dpi", "0"], ["--dpi", "oops"], ["--rotate", "45"],
                ["--threshold", "255"], ["--crop", "nanx10"],
                ["--crop", "infx10"], ["--crop", "0x10"],
                ["--crop", "bad"], ["--intent", "bad"], ["--format", "bad"], ["--mode", "bad"],
                ["--out"], ["--host"], ["--path"], ["--crop"], ["--dpi"],
            ]
            for args in cases {
                let result = try runProcess(
                    TestConfig.scanner, ["--host", "127.0.0.1"] + args, timeout: 5)
                try expectEqual(result.returncode, 2, "\(args): \(result.stderrText)")
                try expectFalse(result.stderrText.contains("Scanning"), "\(args)")
            }
        },
        TestCase(name: "ScannerTests.test_job_locations_and_cleanup") {
            let locations = [
                "/eSCL/ScanJobs/job",
                "ScanJobs/job",
                "http://unreachable.invalid/eSCL/ScanJobs/job%20id",
            ]
            for location in locations {
                try withTempDir { tmp in
                    try withScannerServer(
                        pages: [.reply(200, Data("scan bytes".utf8)), .reply(410, Data())],
                        location: location
                    ) { server in
                        let output = tmp.appendingPathComponent("scan.raw")
                        let result = try runScanner(port: server.port, output: output, ["--raw"])
                        try expectEqual(result.returncode, 0, result.stderrText)
                        try expectEqual(try Data(contentsOf: output), Data("scan bytes".utf8))
                        let expected =
                            "/eSCL/ScanJobs/" + (location.contains("%20") ? "job%20id" : "job")
                        try expectTrue(
                            server.requests.contains { $0 == ("GET", expected + "/NextDocument") })
                        try expectTrue(server.requests.contains { $0 == ("DELETE", expected) })
                    }
                }
            }
        },
        TestCase(name: "ScannerTests.test_transfer_errors_fail_and_delete_job") {
            let pageCases: [[MockPage]] = [
                [.reply(500, Data())],
                [.reply(200, Data("page 1".utf8)), .reply(500, Data())],
                [.reply(200, Data("page 1".utf8)), .disconnect],
                [.reply(200, Data())],
            ]
            for pages in pageCases {
                try withTempDir { tmp in
                    try withScannerServer(
                        pages: pages, location: "http://127.0.0.1/eSCL/ScanJobs/job"
                    ) { server in
                        let output = tmp.appendingPathComponent("scan.raw")
                        let result = try runScanner(port: server.port, output: output, ["--raw"])
                        try expectEqual(result.returncode, 1, result.stderrText)
                        try expectFalse(FileManager.default.fileExists(atPath: output.path))
                        try expectTrue(
                            server.requests.contains { $0 == ("DELETE", "/eSCL/ScanJobs/job") })
                    }
                }
            }
        },
        TestCase(name: "ScannerTests.test_invalid_platen_fails_before_scanning") {
            let capsText = String(decoding: defaultCapsXML, as: UTF8.self)
            var cases = ["0", "-1", "oops", "", "2147483648"].map {
                Data(capsText.replacingOccurrences(of: ">2550<", with: ">\($0)<").utf8)
            }
            cases.append(
                Data(
                    capsText.replacingOccurrences(of: "PlatenInputCaps", with: "AdfInputCaps").utf8)
            )
            cases.append(Data("not xml".utf8))

            for caps in cases {
                for args in [[], ["--caps"]] {
                    try withTempDir { tmp in
                        try withScannerServer(pages: [], caps: caps) { server in
                            let output = tmp.appendingPathComponent("scan.png")
                            let result = try runScanner(port: server.port, output: output, args)
                            try expectEqual(result.returncode, 1, result.stderrText)
                            try expectFalse(result.stderrText.contains("Traceback"))
                            try expectFalse(FileManager.default.fileExists(atPath: output.path))
                            try expectFalse(server.requests.contains { $0.0 == "POST" })
                        }
                    }
                }
            }
        },
        TestCase(name: "ScannerTests.test_capabilities_http_error_fails_before_scanning") {
            try withTempDir { tmp in
                try withScannerServer(pages: [], capsStatus: 500) { server in
                    let result = try runScanner(
                        port: server.port, output: tmp.appendingPathComponent("scan.raw"), ["--raw"]
                    )
                    try expectEqual(result.returncode, 1, result.stderrText)
                    try expectTrue(result.stderrText.contains("HTTP 500"))
                    try expectFalse(server.requests.contains { $0.0 == "POST" })
                }
            }
        },
        TestCase(name: "ScannerTests.test_unexpected_job_status_fails_before_downloading") {
            try withTempDir { tmp in
                try withScannerServer(
                    pages: [.reply(200, Data("page".utf8))], createStatus: 202
                ) { server in
                    let output = tmp.appendingPathComponent("scan.raw")
                    let result = try runScanner(port: server.port, output: output, ["--raw"])
                    try expectEqual(result.returncode, 1, result.stderrText)
                    try expectTrue(result.stderrText.contains("HTTP 202"))
                    try expectFalse(FileManager.default.fileExists(atPath: output.path))
                    try expectFalse(server.requests.contains { $0.1.contains("NextDocument") })
                }
            }
        },
        TestCase(name: "ScannerTests.test_multiple_pages_keep_distinct_output_names") {
            let names = [("scan", "scan-2"), ("scan.raw", "scan-2.raw"), (".scan", ".scan-2")]
            for (name, secondName) in names {
                try withTempDir(suffix: ".scans") { tmp in
                    try withScannerServer(
                        pages: [.reply(200, Data("page 1".utf8)), .reply(200, Data("page 2".utf8))]
                    ) { server in
                        let output = tmp.appendingPathComponent(name)
                        let result = try runScanner(port: server.port, output: output, ["--raw"])
                        try expectEqual(result.returncode, 0, result.stderrText)
                        try expectEqual(try Data(contentsOf: output), Data("page 1".utf8))
                        try expectEqual(
                            try Data(contentsOf: tmp.appendingPathComponent(secondName)),
                            Data("page 2".utf8))
                        try expectTrue(
                            server.requests.contains { $0 == ("DELETE", "/eSCL/ScanJobs/job") })
                    }
                }
            }
        },
        TestCase(name: "ScannerTests.test_native_pdf_passthrough") {
            let pdf = try Data(
                contentsOf: TestConfig.root.appendingPathComponent("test/testpage-a4.pdf"))
            try withTempDir { tmp in
                try withScannerServer(pages: [.reply(200, pdf)]) { server in
                    let output = tmp.appendingPathComponent("scan.pdf")
                    let result = try runScanner(
                        port: server.port, output: output, ["--rotate", "90"])
                    try expectEqual(result.returncode, 0, result.stderrText)
                    try expectEqual(try Data(contentsOf: output), pdf)
                }
            }
        },
        TestCase(name: "ScannerTests.test_native_image_processing") {
            try withTempDir { tmp in
                let source = tmp.appendingPathComponent("source.png")
                let output = tmp.appendingPathComponent("scan.png")
                try writePNG(
                    to: source,
                    rows: [Data([0, 255]), Data([64, 128]), Data([192, 32])],
                    width: 2, height: 3, bpp: 1)
                let sourceBytes = try Data(contentsOf: source)
                let bigCrop =
                    String(repeating: "9", count: 308) + "x" + String(repeating: "9", count: 308)
                for (crop, expectedW, expectedH) in [("a6", UInt32(1), UInt32(1)), (bigCrop, 3, 2)]
                {
                    try withScannerServer(pages: [.reply(200, sourceBytes)]) { server in
                        let result = try runScanner(
                            port: server.port, output: output,
                            ["--rotate", "90", "--mode", "gray", "--crop", crop])
                        try expectEqual(result.returncode, 0, result.stderrText)
                        let png = try Data(contentsOf: output)
                        let w = png[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                        let h = png[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                        try expectEqual(w, expectedW)
                        try expectEqual(h, expectedH)
                    }
                }
            }
        },
        TestCase(name: "ScannerTests.test_pdf_physical_dimensions") {
            try withTempDir { tmp in
                let source = tmp.appendingPathComponent("source.png")
                let output = tmp.appendingPathComponent("scan.pdf")
                let row = repeatingBytes([64, 128, 192], count: 1680)
                let rows = Array(repeating: row, count: 2195)
                try writePNG(to: source, rows: rows, width: 1680, height: 2195, bpp: 3)
                let sourceBytes = try Data(contentsOf: source)

                let cases: [([String], (Double, Double))] = [
                    ([], (215.9, 296.926)),
                    (["--dpi", "600"], (215.9, 296.926)),
                    (["--crop", "a6"], (105, 148)),
                    (["--crop", "a6", "--rotate", "90", "--mode", "gray"], (148, 105)),
                    (["--rotate", "270", "--mode", "lineart"], (296.926, 215.9)),
                    (["--crop", "999x999", "--rotate", "180"], (215.9, 296.926)),
                ]
                for (args, expectedMM) in cases {
                    try withScannerServer(pages: [.reply(200, sourceBytes)]) { server in
                        let result = try runScanner(port: server.port, output: output, args)
                        try expectEqual(result.returncode, 0, result.stderrText)
                    }
                    let (actualW, actualH) = try pdfPageSize(at: output)
                    try expectAlmostEqual(actualW * 25.4 / 72, expectedMM.0, delta: 0.15)
                    try expectAlmostEqual(actualH * 25.4 / 72, expectedMM.1, delta: 0.15)
                }
            }
        },
        TestCase(name: "ScannerTests.test_native_cancellation_releases_job") {
            for signum in [SIGINT, SIGTERM] {
                for firstPage in [false, true] {
                    try withTempDir { tmp in
                        let started = DispatchSemaphore(value: 0)
                        let release = DispatchSemaphore(value: 0)
                        let stalled = MockPage.dynamic {
                            started.signal()
                            _ = release.wait(timeout: .now() + 10)
                            return .reply(200, Data("late page".utf8))
                        }
                        var pages: [MockPage] =
                            firstPage ? [.reply(200, Data("first page".utf8))] : []
                        pages.append(stalled)

                        try withScannerServer(pages: pages) { server in
                            let output = tmp.appendingPathComponent("scan.raw")
                            let process = Process()
                            process.executableURL = URL(fileURLWithPath: TestConfig.scanner)
                            process.arguments = [
                                "--host", "127.0.0.1", "--port", "\(server.port)",
                                "--raw", "--out", output.path,
                            ]
                            let outPipe = Pipe()
                            let errPipe = Pipe()
                            process.standardOutput = outPipe
                            process.standardError = errPipe
                            let done = DispatchSemaphore(value: 0)
                            process.terminationHandler = { _ in done.signal() }
                            try process.run()
                            defer {
                                release.signal()
                                if process.isRunning {
                                    kill(process.processIdentifier, SIGKILL)
                                    _ = done.wait(timeout: .now() + 2)
                                }
                            }

                            try expectEqual(
                                started.wait(timeout: .now() + 5), .success,
                                "scan transfer did not start")
                            kill(process.processIdentifier, signum)
                            let exited = done.wait(timeout: .now() + 5)
                            release.signal()
                            try expectEqual(exited, .success, "brscan did not exit on signal")

                            let stdoutText = String(
                                decoding: outPipe.fileHandleForReading.readDataToEndOfFile(),
                                as: UTF8.self)
                            let stderrText = String(
                                decoding: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                as: UTF8.self)
                            try expectEqual(process.terminationStatus, 128 + signum, stderrText)
                            try expectTrue(stderrText.contains("interrupted"), stderrText)
                            try expectFalse(stdoutText.contains("Wrote"), stdoutText)
                            try expectFalse(FileManager.default.fileExists(atPath: output.path))
                            let deletes = server.requests.filter {
                                $0 == ("DELETE", "/eSCL/ScanJobs/job")
                            }.count
                            try expectEqual(deletes, 1)
                        }
                    }
                }
            }
        },
    ]
}
