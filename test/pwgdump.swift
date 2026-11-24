// Dump PWG Raster page headers.
//
// PWG Raster is a 4-byte sync word followed, per page, by a 1796-byte header and
// the compressed band data. This decodes the header so driver output can be
// checked field by field instead of by eyeball.
//
//     ./build/pwgdump file.pwg [file2.pwg ...]

import Foundation

private let interestingFields = [
    "MediaType", "cupsPageSizeName", "cupsWidth", "cupsHeight",
    "cupsBitsPerPixel", "cupsBytesPerLine", "cupsColorSpace", "cupsNumColors",
    "HWResolution", "PageSize", "cupsPageSize", "cupsImagingBBox",
    "ImagingBoundingBox", "Margins", "Duplex", "NumCopies", "OutputFaceUp",
    "cupsBorderlessScalingFactor", "cupsMediaType", "cupsRenderingIntent",
    "MediaPosition", "cupsCompression", "cupsInteger",
]

@main
enum PWGDump {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let paths = args.isEmpty ? ["-"] : args
        do {
            var dumps: [PWGHeader] = []
            for path in paths {
                let pages = try readPWGHeaders(path: path)
                let syncText = String(decoding: pages[0].sync, as: UTF8.self)
                print("== \(path): \(pages.count) page(s), sync \(syncText)")
                let header = pages[0].header
                for key in interestingFields {
                    guard let value = header[key] else { continue }
                    let extra: String
                    if key == "cupsColorSpace", let code = value.uintValue {
                        extra = "  (\(pwgColorSpaceNames[code] ?? "?"))"
                    } else {
                        extra = ""
                    }
                    let padded = key.padding(toLength: 30, withPad: " ", startingAt: 0)
                    print("   \(padded) \(value)\(extra)")
                }
                dumps.append(header)
                print()
            }

            if dumps.count == 2 {
                print("== differences (page 1)")
                let a = dumps[0]
                let b = dumps[1]
                for field in pwgFields where a[field.name] != b[field.name] {
                    let paddedKey = field.name.padding(toLength: 30, withPad: " ", startingAt: 0)
                    let left = (a[field.name]?.debugRepresentation ?? "nil")
                        .padding(toLength: 38, withPad: " ", startingAt: 0)
                    let right = b[field.name]?.debugRepresentation ?? "nil"
                    print("   \(paddedKey) \(left) -> \(right)")
                }
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
