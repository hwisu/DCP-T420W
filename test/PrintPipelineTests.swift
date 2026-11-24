// Exercise macOS PDF rendering through the driver without submitting a job.

import Foundation

private func threePagePDF() -> Data {
    var objects: [Data] = [
        Data("<</Type/Catalog/Pages 2 0 R>>".utf8),
        Data("<</Type/Pages/Kids[3 0 R 5 0 R 7 0 R]/Count 3>>".utf8),
    ]
    for i in 0..<3 {
        let pageObj =
            "<</Type/Page/Parent 2 0 R/MediaBox[0 0 595.2756 841.8898]"
            + "/Resources<<>>/Contents \(4 + 2 * i) 0 R>>"
        objects.append(Data(pageObj.utf8))
        let red = Double(i) / 2.0
        let content = Data("\(red) 0 0 rg 50 50 100 100 re f".utf8)
        var stream = Data("<</Length \(content.count)>>\nstream\n".utf8)
        stream.append(content)
        stream.append(Data("\nendstream".utf8))
        objects.append(stream)
    }

    var data = Data("%PDF-1.4\n".utf8)
    var offsets: [Int] = []
    for (idx, obj) in objects.enumerated() {
        offsets.append(data.count)
        data.append(Data("\(idx + 1) 0 obj\n".utf8))
        data.append(obj)
        data.append(Data("\nendobj\n".utf8))
    }
    let xref = data.count
    data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
    for off in offsets {
        data.append(Data(String(format: "%010d 00000 n \n", off).utf8))
    }
    data.append(
        Data("trailer\n<</Size \(objects.count + 1)/Root 1 0 R>>\nstartxref\n\(xref)\n%%EOF\n".utf8)
    )
    return data
}

private func checkPipeline(
    options: String,
    dimensions: (UInt32, UInt32),
    space: UInt32,
    pages: Int = 1,
    multiple: Bool = false,
    copies: Int = 1,
    media: String = "iso_a4_210x297mm",
    renderType: String? = nil,
    pageIDs: [Int]? = nil,
    dpi: UInt32? = nil,
    mediaType: String? = nil,
    quality: Int? = nil
) throws {
    try withTempDir { tmp in
        let source: URL
        if multiple {
            source = tmp.appendingPathComponent("three-pages.pdf")
            try threePagePDF().write(to: source)
        } else {
            source = TestConfig.root.appendingPathComponent("test/testpage-a4.pdf")
        }
        let raster = tmp.appendingPathComponent("input.cups")
        var env = ProcessInfo.processInfo.environment
        env["PPD"] = TestConfig.ppd
        if let renderType {
            env["CONTENT_TYPE"] = "application/pdf"
            env["FINAL_CONTENT_TYPE"] = renderType
        }
        let args = ["1", "test", "test", "\(copies)", options]
        let rendered = try runProcess(
            "/usr/libexec/cups/filter/cgpdftoraster", args + [source.path],
            stdoutFile: raster, env: env, timeout: 90)
        try expectEqual(rendered.returncode, 0, rendered.stderrText)

        if renderType == "image/urf" {
            let prefix = try Data(contentsOf: raster).prefix(8)
            try expectEqual(prefix, Data("UNIRAST\0".utf8))
            // Treat the generated fixture as a direct AirPrint job.
            env["CONTENT_TYPE"] = "image/urf"
        }

        let converted = try runProcess(
            TestConfig.filter, args + [raster.path], env: env, timeout: 90)
        try expectEqual(converted.returncode, 0, converted.stderrText)
        if let quality {
            try expectTrue(
                converted.stderrText.contains("quality=\(quality)"), converted.stderrText)
        }

        let accounting = converted.stderrText
            .split(separator: "\n")
            .filter { $0.hasPrefix("PAGE:") }
        if renderType == "image/pwg-raster" {
            try expectTrue(accounting.isEmpty)
            let upstreamTotal = rendered.stderrText
                .split(separator: "\n")
                .filter { $0.hasPrefix("PAGE:") }
                .compactMap { Int($0.split(separator: " ")[2]) }
                .reduce(0, +)
            try expectEqual(upstreamTotal, pages)
        } else {
            try expectEqual(accounting.count, pages)
        }

        let data = converted.stdout
        try expectEqual(data.prefix(4), Data("RaS2".utf8))
        var offset = 4
        var count = 0
        var actualIDs: [Int] = []
        while offset < data.count {
            let header = try parsePWGHeader(data, offset: offset)
            try expectEqual(header.uint("cupsWidth"), dimensions.0)
            try expectEqual(header.uint("cupsHeight"), dimensions.1)
            try expectEqual(header.uint("cupsColorSpace"), space)
            try expectEqual(header.string("cupsPageSizeName"), media)
            if let dpi {
                try expectEqual(header.uints("HWResolution"), [dpi, dpi])
            }
            if let mediaType {
                try expectEqual(header.string("MediaType"), mediaType)
            }
            try expectEqual(header.uint("NumCopies"), 1)
            try expectEqual(header.uints("ImagingBoundingBox"), [0, 0, 0, 0])

            let (rows, nextOffset) = try decodePWGPage(
                data, offset: offset + pwgHeaderLength, header: header)
            offset = nextOffset
            let expectedHeight = Int(header.uint("cupsHeight"))
            let expectedRowLen = Int(header.uint("cupsBytesPerLine"))
            try expectEqual(rows.count, expectedHeight)
            try expectTrue(rows.allSatisfy { $0.count == expectedRowLen })

            if pageIDs != nil {
                // The three-page fixture paints a 100pt square at (50,50),
                // with red = 0, 0.5, 1 identifying pages 1, 2 and 3.
                let sampleRow = rows[rows.count - 420]
                let x = 420 * 3
                try expectEqual(sampleRow[x + 1], 0)
                try expectEqual(sampleRow[x + 2], 0)
                let red = Double(sampleRow[x])
                let best = (0..<3).min {
                    abs(red - Double($0) * 127.5) < abs(red - Double($1) * 127.5)
                }!
                actualIDs.append(best + 1)
            }
            count += 1
        }
        try expectEqual(count, pages)
        try expectEqual(offset, data.count)
        if let pageIDs {
            try expectEqual(actualIDs, pageIDs)
        }
    }
}

func printPipelineTests() -> [TestCase] {
    [
        TestCase(name: "PrintPipelineTests.test_default_reverse_and_explicit_page_order") {
            let modes: [(String?, (UInt32, UInt32))] = [
                (nil, (2480, 3508)),
                ("image/pwg-raster", (2480, 3507)),
            ]
            let orders: [(String, [Int])] = [
                ("", [3, 2, 1]),
                ("outputorder=normal", [1, 2, 3]),
                ("outputorder=reverse", [3, 2, 1]),
                ("page-set=odd", [3, 1]),
                ("page-set=even", [2]),
            ]
            for (renderType, size) in modes {
                for (option, expected) in orders {
                    try checkPipeline(
                        options: "cupsPrintQuality=Draft ColorModel=RGB \(option)",
                        dimensions: size, space: 19, pages: expected.count,
                        multiple: true, renderType: renderType, pageIDs: expected)
                }
            }
        },
        TestCase(name: "PrintPipelineTests.test_copies_are_not_multiplied") {
            for copies in [1, 10, 11] {
                try checkPipeline(
                    options: "cupsPrintQuality=Draft ColorModel=Gray",
                    dimensions: (2480, 3508), space: 18, pages: copies, copies: copies)
            }
        },
        TestCase(name: "PrintPipelineTests.test_landscape_keeps_feed_geometry") {
            try checkPipeline(
                options: "orientation-requested=4 cupsPrintQuality=Draft ColorModel=Gray",
                dimensions: (2480, 3508), space: 18)
        },
        TestCase(name: "PrintPipelineTests.test_cups_pwg_path_and_page_accounting") {
            for copies in [1, 10, 11] {
                try checkPipeline(
                    options: "cupsPrintQuality=Draft ColorModel=Gray",
                    dimensions: (2480, 3507), space: 18, pages: copies,
                    copies: copies, renderType: "image/pwg-raster")
            }
            try checkPipeline(
                options: "cupsPrintQuality=Normal ColorModel=RGB",
                dimensions: (4960, 7015), space: 19, renderType: "image/pwg-raster")
        },
        TestCase(name: "PrintPipelineTests.test_airprint_urf_input") {
            try checkPipeline(
                options: "cupsPrintQuality=Draft ColorModel=Gray",
                dimensions: (2480, 3507), space: 18, renderType: "image/urf")
        },
        TestCase(name: "PrintPipelineTests.test_supported_media") {
            let result = try runProcess(TestConfig.genppd, ["--media"], timeout: 10)
            try expectEqual(result.returncode, 0, result.stderrText)
            for line in result.stdoutText.split(separator: "\n") {
                let cols = line.split(separator: "\t").map(String.init)
                try expectEqual(cols.count, 4, String(line))
                let name = cols[0]
                let media = cols[1]
                guard let width = Double(cols[2]), let height = Double(cols[3]) else {
                    try fail("Bad media dimensions in \(line)")
                }
                for renderType: String? in [nil, "image/pwg-raster"] {
                    let rounding = renderType == nil ? 0.5 : 0.0
                    let dims = (
                        UInt32(width / 2540.0 * 300.0 + rounding),
                        UInt32(height / 2540.0 * 300.0 + rounding)
                    )
                    try checkPipeline(
                        options: "PageSize=\(name) cupsPrintQuality=Draft ColorModel=Gray",
                        dimensions: dims, space: 18, media: media, renderType: renderType)
                }
            }
        },
        TestCase(name: "PrintPipelineTests.test_quality_and_colour") {
            let cases: [(String, (UInt32, UInt32), UInt32)] = [
                ("cupsPrintQuality=Draft ColorModel=Gray", (2480, 3508), 18),
                ("cupsPrintQuality=Normal ColorModel=RGB", (4961, 7016), 19),
                ("cupsPrintQuality=High ColorModel=RGB", (4961, 7016), 19),
                ("PageSize=A4.Borderless MediaType=PhotographicGlossy", (4961, 7016), 19),
            ]
            for (options, size, space) in cases {
                try checkPipeline(options: options, dimensions: size, space: space)
            }
        },
        TestCase(name: "PrintPipelineTests.test_native_quality_presets") {
            let colors: [(String, UInt32)] = [("RGB", 19), ("Gray", 18)]
            let qualities: [(String, UInt32, Int)] = [
                ("Draft", 300, 3), ("Normal", 600, 4), ("High", 600, 5),
            ]
            for (color, space) in colors {
                for (quality, dpi, value) in qualities {
                    try checkPipeline(
                        options: "APPrinterPreset=\(color)_\(quality) PageSize=3.5x5",
                        dimensions: (UInt32(3.5 * Double(dpi)), 5 * dpi), space: space,
                        media: "oe_photo-l_3.5x5in", dpi: dpi,
                        mediaType: "stationery", quality: value)
                }
            }
            for (preset, paper) in [
                ("PhotoGlossy", "photographic-glossy"), ("PhotoBP71", "com.brother-bp71"),
            ] {
                try checkPipeline(
                    options: "APPrinterPreset=\(preset) PageSize=3.5x5.Borderless",
                    dimensions: (2100, 3000), space: 19,
                    media: "oe_photo-l_3.5x5in", dpi: 600, mediaType: paper, quality: 5)
            }
        },
        TestCase(name: "PrintPipelineTests.test_odd_even_selection") {
            for (selection, pages) in [("odd", 2), ("even", 1)] {
                try checkPipeline(
                    options: "page-set=\(selection) cupsPrintQuality=Draft ColorModel=Gray",
                    dimensions: (2480, 3508), space: 18, pages: pages, multiple: true)
            }
        },
    ]
}
