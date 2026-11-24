// Build a printer test page as a self-contained PDF.
//
// The page is designed to prove the driver's geometry rather than just to make
// marks: the outer rule sits exactly on the PPD's *ImageableArea, so if
// rastertobrother pads the page correctly the rule lands 3 mm inside every paper
// edge, square and unclipped. Everything else exercises colour, greys and
// resolution.
//
//     ./build/make_testpage > test/testpage-a4.pdf

import Foundation
import zlib

private let mm = 72.0 / 25.4
private let pageWidth = 210.0 * mm
private let pageHeight = 297.0 * mm
private let margin = 3.0 * mm

private func escapePDF(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "(", with: "\\(")
        .replacingOccurrences(of: ")", with: "\\)")
}

private func f3(_ value: Double) -> String { String(format: "%.3f", value) }
private func f2(_ value: Double) -> String { String(format: "%.2f", value) }

private struct Content {
    private var ops: [String] = []

    mutating func op(_ line: String) { ops.append(line) }
    mutating func rgbStroke(_ r: Double, _ g: Double, _ b: Double) {
        op("\(f3(r)) \(f3(g)) \(f3(b)) RG")
    }
    mutating func rgbFill(_ r: Double, _ g: Double, _ b: Double) {
        op("\(f3(r)) \(f3(g)) \(f3(b)) rg")
    }
    mutating func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, mode: String = "S") {
        op("\(f3(x)) \(f3(y)) \(f3(w)) \(f3(h)) re \(mode)")
    }
    mutating func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        op("\(f3(x1)) \(f3(y1)) m \(f3(x2)) \(f3(y2)) l S")
    }
    mutating func text(
        _ x: Double, _ y: Double, size: Double, _ string: String, font: String = "F1"
    ) {
        op("BT")
        op("/\(font) \(f2(size)) Tf")
        op("1 0 0 1 \(f3(x)) \(f3(y)) Tm")
        op("(\(escapePDF(string))) Tj")
        op("ET")
    }
    func render() -> Data { Data(ops.joined(separator: "\n").utf8) }
}

private func buildPage() -> Data {
    var c = Content()
    c.op("0.6 w")

    // Imageable-area rule: the geometry check.
    c.rgbStroke(0, 0, 0)
    c.rect(margin, margin, pageWidth - 2 * margin, pageHeight - 2 * margin)

    // Corner brackets, 12 mm arms, sitting on the same boundary.
    let arm = 12.0 * mm
    let corners: [(Double, Double, Double, Double)] = [
        (margin, margin, 1, 1),
        (pageWidth - margin, margin, -1, 1),
        (margin, pageHeight - margin, 1, -1),
        (pageWidth - margin, pageHeight - margin, -1, -1),
    ]
    for (cx, cy, dx, dy) in corners {
        c.op("1.4 w")
        c.line(cx, cy, cx + dx * arm, cy)
        c.line(cx, cy, cx, cy + dy * arm)
    }
    c.op("0.6 w")

    let top = pageHeight - margin
    var y = top - 22 * mm

    c.rgbFill(0, 0, 0)
    c.text(margin + 8 * mm, y, size: 18, "Brother DCP-T420W")
    y -= 7 * mm
    c.text(margin + 8 * mm, y, size: 10, "macOS PWG Raster driver - test page")
    y -= 5 * mm
    c.text(
        margin + 8 * mm, y, size: 8,
        "Outer rule = imageable area (3 mm inset). It must be unclipped and square on all four sides."
    )

    // Process colour bars.
    y -= 12 * mm
    c.text(margin + 8 * mm, y, size: 9, "Process colours")
    y -= 3 * mm
    let bars: [(String, Double, Double, Double)] = [
        ("C", 0.0, 1.0, 1.0), ("M", 1.0, 0.0, 1.0), ("Y", 1.0, 1.0, 0.0),
        ("R", 1.0, 0.0, 0.0), ("G", 0.0, 1.0, 0.0), ("B", 0.0, 0.0, 1.0),
        ("K", 0.0, 0.0, 0.0),
    ]
    let bw = (pageWidth - 2 * margin - 16 * mm) / Double(bars.count)
    let bh = 16 * mm
    for (i, bar) in bars.enumerated() {
        let x = margin + 8 * mm + Double(i) * bw
        c.rgbFill(bar.1, bar.2, bar.3)
        c.rect(x, y - bh, bw - 1.5, bh, mode: "f")
        c.rgbFill(0, 0, 0)
        c.text(x + bw / 2 - 3, y - bh - 4 * mm, size: 8, bar.0)
    }

    // Grey ramp.
    y -= bh + 14 * mm
    c.rgbFill(0, 0, 0)
    c.text(margin + 8 * mm, y, size: 9, "Grey ramp (0-100%)")
    y -= 3 * mm
    let steps = 11
    let sw = (pageWidth - 2 * margin - 16 * mm) / Double(steps)
    let sh = 12 * mm
    for i in 0..<steps {
        let v = 1.0 - Double(i) / Double(steps - 1)
        c.rgbFill(v, v, v)
        c.rect(margin + 8 * mm + Double(i) * sw, y - sh, sw, sh, mode: "f")
    }
    c.rgbStroke(0, 0, 0)
    c.op("0.4 w")
    c.rect(margin + 8 * mm, y - sh, sw * Double(steps), sh)

    // Resolution / fine-line block.
    y -= sh + 14 * mm
    c.rgbFill(0, 0, 0)
    c.text(
        margin + 8 * mm, y, size: 9,
        "Fine lines - hairline to 1 pt (600 dpi renders the 0.12 pt rule)")
    y -= 5 * mm
    var x = margin + 8 * mm
    for width in [0.12, 0.24, 0.35, 0.5, 0.75, 1.0] {
        c.op("\(f2(width)) w")
        c.rgbStroke(0, 0, 0)
        for k in 0..<6 {
            c.line(x + Double(k) * 1.6, y, x + Double(k) * 1.6, y - 14 * mm)
        }
        let label = width == 0.5 ? "0.5" : (width == 1.0 ? "1" : String(format: "%g", width))
        c.text(x - 1, y - 17 * mm, size: 6, label)
        x += 22 * mm
    }

    // Text ladder.
    y -= 26 * mm
    c.op("0.6 w")
    c.rgbFill(0, 0, 0)
    c.text(margin + 8 * mm, y, size: 9, "Text rendering")
    y -= 6 * mm
    for size in [12.0, 10.0, 8.0, 6.0, 5.0, 4.0] {
        c.text(
            margin + 8 * mm, y, size: size,
            "\(Int(size)) pt - The quick brown fox jumps over the lazy dog 0123456789")
        y -= size + 3.5
    }

    // Centre crosshair.
    let cx = pageWidth / 2
    let cy = pageHeight / 2
    c.op("0.4 w")
    c.rgbStroke(0.7, 0.7, 0.7)
    c.line(cx - 8 * mm, cy, cx + 8 * mm, cy)
    c.line(cx, cy - 8 * mm, cx, cy + 8 * mm)

    // Footer.
    c.rgbFill(0.3, 0.3, 0.3)
    c.text(
        margin + 8 * mm, margin + 6 * mm, size: 7,
        "rastertobrother / image-pwg-raster / A4 210x297mm / 3 mm margins")

    return c.render()
}

private func compress(_ input: Data) -> Data {
    let sourceLen = uLong(input.count)
    var destLen = compressBound(sourceLen)
    var output = Data(count: Int(destLen))
    let rc = output.withUnsafeMutableBytes { destPtr -> Int32 in
        guard let destBase = destPtr.bindMemory(to: Bytef.self).baseAddress else {
            return Z_MEM_ERROR
        }
        return input.withUnsafeBytes { srcPtr in
            let srcBase = srcPtr.bindMemory(to: Bytef.self).baseAddress
            return compress2(destBase, &destLen, srcBase, sourceLen, Z_DEFAULT_COMPRESSION)
        }
    }
    precondition(rc == Z_OK, "zlib compress2 failed: \(rc)")
    output.count = Int(destLen)
    return output
}

private func buildPDF(content: Data) -> Data {
    let stream = compress(content)
    let pageDict = String(
        format: "<</Type/Page/Parent 2 0 R/MediaBox[0 0 %.4f %.4f]"
            + "/Resources<</Font<</F1 5 0 R>>>>/Contents 4 0 R>>",
        pageWidth, pageHeight)
    var streamObj = Data("<</Length \(stream.count)/Filter/FlateDecode>>\nstream\n".utf8)
    streamObj.append(stream)
    streamObj.append(Data("\nendstream".utf8))

    let objects: [Data] = [
        Data("<</Type/Catalog/Pages 2 0 R>>".utf8),
        Data("<</Type/Pages/Kids[3 0 R]/Count 1>>".utf8),
        Data(pageDict.utf8),
        streamObj,
        Data("<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>".utf8),
    ]

    var out = Data("%PDF-1.4\n".utf8)
    out.append(contentsOf: [0x25, 0xe2, 0xe3, 0xcf, 0xd3, 0x0a])
    var offsets: [Int] = []
    for (idx, body) in objects.enumerated() {
        offsets.append(out.count)
        out.append(Data("\(idx + 1) 0 obj\n".utf8))
        out.append(body)
        out.append(Data("\nendobj\n".utf8))
    }

    let xref = out.count
    out.append(Data("xref\n0 \(objects.count + 1)\n".utf8))
    out.append(Data("0000000000 65535 f \n".utf8))
    for off in offsets {
        out.append(Data(String(format: "%010d 00000 n \n", off).utf8))
    }
    out.append(
        Data(
            "trailer\n<</Size \(objects.count + 1)/Root 1 0 R>>\nstartxref\n\(xref)\n%%EOF\n".utf8))
    return out
}

FileHandle.standardOutput.write(buildPDF(content: buildPage()))
