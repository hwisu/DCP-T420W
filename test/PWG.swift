// Shared PWG Raster, PNG, and zlib helpers for the driver test suite and dev tools.

import Foundation
import zlib

let pwgHeaderLength = 1796

let pwgColorSpaceNames: [UInt32: String] = [
    0: "W",
    1: "RGB",
    3: "K",
    18: "sgray_8",
    19: "srgb_8",
    20: "AdobeRGB",
]

enum PWGFieldKind {
    case string
    case strings
    case uint
    case float
}

struct PWGFieldSpec {
    let name: String
    let kind: PWGFieldKind
    let count: Int
}

// Wire-order field table matching CUPS/PWG Raster's 1796-byte page header.
let pwgFields: [PWGFieldSpec] = [
    PWGFieldSpec(name: "MediaClass", kind: .string, count: 1),
    PWGFieldSpec(name: "MediaColor", kind: .string, count: 1),
    PWGFieldSpec(name: "MediaType", kind: .string, count: 1),
    PWGFieldSpec(name: "OutputType", kind: .string, count: 1),
    PWGFieldSpec(name: "AdvanceDistance", kind: .uint, count: 1),
    PWGFieldSpec(name: "AdvanceMedia", kind: .uint, count: 1),
    PWGFieldSpec(name: "Collate", kind: .uint, count: 1),
    PWGFieldSpec(name: "CutMedia", kind: .uint, count: 1),
    PWGFieldSpec(name: "Duplex", kind: .uint, count: 1),
    PWGFieldSpec(name: "HWResolution", kind: .uint, count: 2),
    PWGFieldSpec(name: "ImagingBoundingBox", kind: .uint, count: 4),
    PWGFieldSpec(name: "InsertSheet", kind: .uint, count: 1),
    PWGFieldSpec(name: "Jog", kind: .uint, count: 1),
    PWGFieldSpec(name: "LeadingEdge", kind: .uint, count: 1),
    PWGFieldSpec(name: "Margins", kind: .uint, count: 2),
    PWGFieldSpec(name: "ManualFeed", kind: .uint, count: 1),
    PWGFieldSpec(name: "MediaPosition", kind: .uint, count: 1),
    PWGFieldSpec(name: "MediaWeight", kind: .uint, count: 1),
    PWGFieldSpec(name: "MirrorPrint", kind: .uint, count: 1),
    PWGFieldSpec(name: "NegativePrint", kind: .uint, count: 1),
    PWGFieldSpec(name: "NumCopies", kind: .uint, count: 1),
    PWGFieldSpec(name: "Orientation", kind: .uint, count: 1),
    PWGFieldSpec(name: "OutputFaceUp", kind: .uint, count: 1),
    PWGFieldSpec(name: "PageSize", kind: .uint, count: 2),
    PWGFieldSpec(name: "Separations", kind: .uint, count: 1),
    PWGFieldSpec(name: "TraySwitch", kind: .uint, count: 1),
    PWGFieldSpec(name: "Tumble", kind: .uint, count: 1),
    PWGFieldSpec(name: "cupsWidth", kind: .uint, count: 1),
    PWGFieldSpec(name: "cupsHeight", kind: .uint, count: 1),
    PWGFieldSpec(name: "cupsMediaType", kind: .uint, count: 1),
    PWGFieldSpec(name: "cupsBitsPerColor", kind: .uint, count: 1),
    PWGFieldSpec(name: "cupsBitsPerPixel", kind: .uint, count: 1),
    PWGFieldSpec(name: "cupsBytesPerLine", kind: .uint, count: 1),
    PWGFieldSpec(name: "cupsColorOrder", kind: .uint, count: 1),
    PWGFieldSpec(name: "cupsColorSpace", kind: .uint, count: 1),
    PWGFieldSpec(name: "cupsCompression", kind: .uint, count: 1),
    PWGFieldSpec(name: "cupsRowCount", kind: .uint, count: 1),
    PWGFieldSpec(name: "cupsRowFeed", kind: .uint, count: 1),
    PWGFieldSpec(name: "cupsRowStep", kind: .uint, count: 1),
    PWGFieldSpec(name: "cupsNumColors", kind: .uint, count: 1),
    PWGFieldSpec(name: "cupsBorderlessScalingFactor", kind: .float, count: 1),
    PWGFieldSpec(name: "cupsPageSize", kind: .float, count: 2),
    PWGFieldSpec(name: "cupsImagingBBox", kind: .float, count: 4),
    PWGFieldSpec(name: "cupsInteger", kind: .uint, count: 16),
    PWGFieldSpec(name: "cupsReal", kind: .float, count: 16),
    PWGFieldSpec(name: "cupsString", kind: .strings, count: 16),
    PWGFieldSpec(name: "cupsMarkerType", kind: .string, count: 1),
    PWGFieldSpec(name: "cupsRenderingIntent", kind: .string, count: 1),
    PWGFieldSpec(name: "cupsPageSizeName", kind: .string, count: 1),
]

struct PWGError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

enum PWGFieldValue: Equatable, CustomStringConvertible {
    case string(String)
    case strings([String])
    case uint(UInt32)
    case uints([UInt32])
    case float(Float)
    case floats([Float])

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var uintValue: UInt32? {
        if case .uint(let value) = self { return value }
        return nil
    }

    var uintsValue: [UInt32]? {
        if case .uints(let values) = self { return values }
        return nil
    }

    var floatsValue: [Float]? {
        if case .floats(let values) = self { return values }
        return nil
    }

    var description: String {
        switch self {
        case .string(let s): s
        case .strings(let items): "[" + items.map { "'\($0)'" }.joined(separator: ", ") + "]"
        case .uint(let u): "\(u)"
        case .uints(let items): "[" + items.map { "\($0)" }.joined(separator: ", ") + "]"
        case .float(let f): "\(f)"
        case .floats(let items): "[" + items.map { "\($0)" }.joined(separator: ", ") + "]"
        }
    }

    var debugRepresentation: String {
        switch self {
        case .string(let s): "'\(s)'"
        default: description
        }
    }
}

struct PWGHeader {
    let values: [String: PWGFieldValue]

    subscript(_ key: String) -> PWGFieldValue? { values[key] }

    func string(_ key: String) -> String {
        values[key]?.stringValue ?? ""
    }

    func uint(_ key: String) -> UInt32 {
        values[key]?.uintValue ?? 0
    }

    func uints(_ key: String) -> [UInt32] {
        values[key]?.uintsValue ?? []
    }

    func floats(_ key: String) -> [Float] {
        values[key]?.floatsValue ?? []
    }
}

private func decodeCString(_ bytes: UnsafeRawBufferPointer, offset: Int, length: Int) -> String {
    var count = 0
    while count < length, bytes[offset + count] != 0 {
        count += 1
    }
    let slice = UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + count)])
    return String(decoding: slice, as: UTF8.self)
}

private func readUInt32(_ bytes: UnsafeRawBufferPointer, offset: Int, bigEndian: Bool) -> UInt32 {
    let b0 = UInt32(bytes[offset])
    let b1 = UInt32(bytes[offset + 1])
    let b2 = UInt32(bytes[offset + 2])
    let b3 = UInt32(bytes[offset + 3])
    if bigEndian {
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

private func appendUInt32(_ value: UInt32, to data: inout Data, bigEndian: Bool) {
    var encoded = bigEndian ? value.bigEndian : value.littleEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}

func parsePWGHeader(
    _ data: Data, offset: Int = 0, bigEndian: Bool = true
) throws -> PWGHeader {
    guard offset >= 0, offset + pwgHeaderLength <= data.count else {
        throw PWGError("Truncated raster page header")
    }
    var out: [String: PWGFieldValue] = [:]
    data.withUnsafeBytes { raw in
        var cursor = offset
        for field in pwgFields {
            switch field.kind {
            case .string:
                out[field.name] = .string(decodeCString(raw, offset: cursor, length: 64))
                cursor += 64
            case .strings:
                var items: [String] = []
                items.reserveCapacity(field.count)
                for _ in 0..<field.count {
                    items.append(decodeCString(raw, offset: cursor, length: 64))
                    cursor += 64
                }
                out[field.name] = .strings(items)
            case .uint:
                if field.count == 1 {
                    out[field.name] = .uint(readUInt32(raw, offset: cursor, bigEndian: bigEndian))
                    cursor += 4
                } else {
                    var items: [UInt32] = []
                    items.reserveCapacity(field.count)
                    for _ in 0..<field.count {
                        items.append(readUInt32(raw, offset: cursor, bigEndian: bigEndian))
                        cursor += 4
                    }
                    out[field.name] = .uints(items)
                }
            case .float:
                if field.count == 1 {
                    let bits = readUInt32(raw, offset: cursor, bigEndian: bigEndian)
                    out[field.name] = .float(Float(bitPattern: bits))
                    cursor += 4
                } else {
                    var items: [Float] = []
                    items.reserveCapacity(field.count)
                    for _ in 0..<field.count {
                        let bits = readUInt32(raw, offset: cursor, bigEndian: bigEndian)
                        items.append(Float(bitPattern: bits))
                        cursor += 4
                    }
                    out[field.name] = .floats(items)
                }
            }
        }
        precondition(cursor - offset == pwgHeaderLength, "PWG header size mismatch")
    }
    return PWGHeader(values: out)
}

func buildPWGHeader(overrides: [String: PWGFieldValue] = [:], bigEndian: Bool = true) -> Data {
    var out = Data()
    out.reserveCapacity(pwgHeaderLength)
    for field in pwgFields {
        let value = overrides[field.name]
        switch field.kind {
        case .string:
            var block = [UInt8](repeating: 0, count: 64)
            if case .string(let text)? = value {
                let utf8 = Array(text.utf8.prefix(63))
                block.replaceSubrange(0..<utf8.count, with: utf8)
            }
            out.append(contentsOf: block)
        case .strings:
            let items: [String]
            if case .strings(let list)? = value { items = list } else { items = [] }
            for idx in 0..<field.count {
                var block = [UInt8](repeating: 0, count: 64)
                if idx < items.count {
                    let utf8 = Array(items[idx].utf8.prefix(63))
                    block.replaceSubrange(0..<utf8.count, with: utf8)
                }
                out.append(contentsOf: block)
            }
        case .uint:
            if field.count == 1 {
                let u = value?.uintValue ?? 0
                appendUInt32(u, to: &out, bigEndian: bigEndian)
            } else {
                let items = value?.uintsValue ?? []
                for idx in 0..<field.count {
                    appendUInt32(idx < items.count ? items[idx] : 0, to: &out, bigEndian: bigEndian)
                }
            }
        case .float:
            if field.count == 1 {
                let f: Float = if case .float(let val)? = value { val } else { 0 }
                appendUInt32(f.bitPattern, to: &out, bigEndian: bigEndian)
            } else {
                let items = value?.floatsValue ?? []
                for idx in 0..<field.count {
                    let f: Float = idx < items.count ? items[idx] : 0
                    appendUInt32(f.bitPattern, to: &out, bigEndian: bigEndian)
                }
            }
        }
    }
    precondition(out.count == pwgHeaderLength, "Built header length mismatch")
    return out
}

func decodePWGPage(
    _ data: Data, offset: Int, header: PWGHeader, collectRows: Bool = true
) throws -> (rows: [Data], nextOffset: Int) {
    let bpp = (Int(header.uint("cupsBitsPerPixel")) + 7) / 8
    let lineLen = Int(header.uint("cupsBytesPerLine"))
    var rowsLeft = Int(header.uint("cupsHeight"))
    guard bpp > 0, lineLen > 0, rowsLeft > 0 else {
        throw PWGError("Invalid raster page geometry")
    }

    let whiteByte: UInt8 = header.uint("cupsColorSpace") == 3 ? 0x00 : 0xff
    var rows: [Data] = []
    if collectRows { rows.reserveCapacity(rowsLeft) }
    var off = offset

    try data.withUnsafeBytes { raw in
        let end = raw.count
        while rowsLeft > 0 {
            guard off < end else {
                throw PWGError("Missing raster row repeat count")
            }
            let repeatCount = Int(raw[off]) + 1
            off += 1
            if repeatCount > rowsLeft {
                throw PWGError("Raster rows exceed page height")
            }

            var line: [UInt8] = []
            if collectRows { line.reserveCapacity(lineLen) }
            var remaining = lineLen
            while remaining > 0 {
                guard off < end else {
                    throw PWGError("Missing raster packet")
                }
                let ctrl = Int(raw[off])
                off += 1
                if ctrl == 128 {
                    if collectRows {
                        line.append(contentsOf: repeatElement(whiteByte, count: remaining))
                    }
                    break
                }

                let copies = ctrl < 128 ? ctrl + 1 : 1
                let size = ctrl < 128 ? bpp : (257 - ctrl) * bpp
                if size * copies > remaining {
                    throw PWGError("Raster packet exceeds row length")
                }
                if off + size > end {
                    throw PWGError("Truncated raster packet")
                }
                if collectRows {
                    let packet = raw[off..<(off + size)]
                    for _ in 0..<copies {
                        line.append(contentsOf: packet)
                    }
                }
                off += size
                remaining -= size * copies
            }

            if collectRows {
                let rowData = Data(line)
                for _ in 0..<repeatCount {
                    rows.append(rowData)
                }
            }
            rowsLeft -= repeatCount
        }
    }
    return (rows, off)
}

func readPWGHeaders(path: String) throws -> [(header: PWGHeader, sync: Data)] {
    let data: Data
    if path == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    }
    let sync = Data(data.prefix(4))
    guard sync == Data("RaS2".utf8) || sync == Data("2SaR".utf8) else {
        throw PWGError("\(path): not PWG Raster (sync \(String(decoding: sync, as: UTF8.self)))")
    }

    var pages: [(PWGHeader, Data)] = []
    var off = 4
    let bigEndian = sync == Data("RaS2".utf8)
    while off < data.count {
        let header = try parsePWGHeader(data, offset: off, bigEndian: bigEndian)
        let (_, nextOffset) = try decodePWGPage(
            data, offset: off + pwgHeaderLength, header: header, collectRows: false)
        pages.append((header, sync))
        off = nextOffset
    }
    return pages
}

func zlibCompress(_ input: Data, level: Int32 = 6) throws -> Data {
    let sourceLength = uLong(input.count)
    var destLength = compressBound(sourceLength)
    var output = Data(count: Int(destLength))
    let status = output.withUnsafeMutableBytes { destPtr -> Int32 in
        guard let destBase = destPtr.bindMemory(to: Bytef.self).baseAddress else {
            return Z_MEM_ERROR
        }
        return input.withUnsafeBytes { srcPtr in
            let srcBase = srcPtr.bindMemory(to: Bytef.self).baseAddress
            return compress2(destBase, &destLength, srcBase, sourceLength, level)
        }
    }
    guard status == Z_OK else {
        throw PWGError("zlib compression failed (status \(status))")
    }
    output.count = Int(destLength)
    return output
}

func zlibCRC32(_ data: Data) -> UInt32 {
    data.withUnsafeBytes { raw in
        let ptr = raw.bindMemory(to: Bytef.self).baseAddress
        return UInt32(zlib.crc32(0, ptr, uInt(raw.count)))
    }
}

private func pngChunk(_ tag: String, payload: Data) -> Data {
    var chunk = Data()
    appendUInt32(UInt32(payload.count), to: &chunk, bigEndian: true)
    let tagData = Data(tag.utf8)
    chunk.append(tagData)
    chunk.append(payload)
    var crcInput = tagData
    crcInput.append(payload)
    appendUInt32(zlibCRC32(crcInput), to: &chunk, bigEndian: true)
    return chunk
}

@discardableResult
func writePNG(
    to url: URL, rows: [Data], width: Int, height: Int, bpp: Int, scale: Int = 1
) throws -> (width: Int, height: Int) {
    let colorType: UInt8 = bpp == 1 ? 0 : 2
    var outRows = rows
    var outWidth = width
    var outHeight = height

    if scale > 1 {
        var sampledRows: [Data] = []
        let xs = stride(from: 0, to: width, by: scale).map { $0 }
        let ys = stride(from: 0, to: height, by: scale)
        for y in ys {
            let src = rows[y]
            var row = Data()
            row.reserveCapacity(xs.count * bpp)
            for x in xs {
                let start = x * bpp
                row.append(src[start..<(start + bpp)])
            }
            sampledRows.append(row)
        }
        outRows = sampledRows
        outWidth = xs.count
        outHeight = sampledRows.count
    }

    var raw = Data()
    let expectedRowLen = outWidth * bpp
    raw.reserveCapacity(outRows.count * (1 + expectedRowLen))
    for row in outRows {
        raw.append(0)
        raw.append(row)
    }

    var ihdr = Data()
    appendUInt32(UInt32(outWidth), to: &ihdr, bigEndian: true)
    appendUInt32(UInt32(outHeight), to: &ihdr, bigEndian: true)
    ihdr.append(contentsOf: [8, colorType, 0, 0, 0])

    var png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    png.append(pngChunk("IHDR", payload: ihdr))
    png.append(pngChunk("IDAT", payload: try zlibCompress(raw, level: 6)))
    png.append(pngChunk("IEND", payload: Data()))
    try png.write(to: url)
    return (outWidth, outHeight)
}
