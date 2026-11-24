// Decode a PWG Raster stream back to PNG, so driver output can be checked
// without printing it.
//
// PWG Raster lines are run-length encoded: a repeat count for the whole line,
// then control bytes selecting either a repeated pixel or a literal run. This
// reverses that and writes a PNG.
//
//     ./build/pwg2png out.pwg page.png [--scale 8]

import Foundation

@main
enum PWG2PNG {
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        guard argv.count >= 2 else {
            FileHandle.standardError.write(
                Data("usage: pwg2png src.pwg dst.png [--scale N]\n".utf8))
            exit(2)
        }
        let src = argv[0]
        let dst = argv[1]
        var scale = 1
        if let idx = argv.firstIndex(of: "--scale") {
            guard idx + 1 < argv.count, let parsed = Int(argv[idx + 1]), parsed >= 1 else {
                FileHandle.standardError.write(Data("Invalid --scale value\n".utf8))
                exit(2)
            }
            scale = parsed
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: src))
            guard data.prefix(4) == Data("RaS2".utf8) else {
                throw PWGError("\(src): not big-endian PWG Raster")
            }
            let header = try parsePWGHeader(data, offset: 4)
            let (rows, _) = try decodePWGPage(data, offset: 4 + pwgHeaderLength, header: header)
            let bpp = Int(header.uint("cupsBitsPerPixel")) / 8
            let width = Int(header.uint("cupsWidth"))
            let height = Int(header.uint("cupsHeight"))
            let (outWidth, outHeight) = try writePNG(
                to: URL(fileURLWithPath: dst), rows: rows,
                width: width, height: height, bpp: bpp, scale: scale)
            let kind = bpp == 1 ? "grey" : "rgb"
            print(
                "\(src): \(width)x\(height) \(kind) -> \(dst) (\(outWidth)x\(outHeight)), all rows well-formed"
            )
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
