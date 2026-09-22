// brscan - scan from a Brother DCP-T420W (and other eSCL scanners) on macOS.
//
// A native rewrite of scanner/brscan.py with no runtime dependencies: no
// Python, no sips, no SANE, no ICA plugin. Discovery uses Bonjour, transport
// is URLSession, and the image work is ImageIO/CoreGraphics.
//
// Build:  make -C scanner        (or: swiftc -O -swift-version 6 brscan.swift -o brscan)
//
// The DCP-T420W firmware ignores eSCL scan settings entirely - it returns
// HTTP 201 even for a body of "this is not xml at all", and always scans the
// full platen in colour as JPEG. brscan sends a correct request anyway, then
// applies mode, crop, rotation and format locally.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Errors

struct ScanError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

// MARK: - Constants

let unitsPerInch = 300.0        // eSCL regions are three-hundredths of an inch
let mmPerInch = 25.4

enum ColorMode: String {
    case color, gray, lineart
    var escl: String {
        switch self {
        case .color: return "RGB24"
        case .gray: return "Grayscale8"
        case .lineart: return "BlackAndWhite1"
        }
    }
}

enum OutputFormat: String {
    case pdf, jpeg, png
    var ext: String { self == .jpeg ? "jpg" : rawValue }
}

let cropPresets: [String: (Double, Double)] = [
    "a4": (210, 297), "letter": (215.9, 279.4), "a5": (148, 210),
    "a6": (105, 148), "4x6": (101.6, 152.4), "5x7": (127, 177.8),
]

// MARK: - Bonjour discovery

final class Discovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Found { let name: String; let host: String; let port: Int; let rs: String }

    private let browser = NetServiceBrowser()
    private var pending: [NetService] = []
    private var results: [Found] = []
    private var done = false

    func run(timeout: TimeInterval) -> [Found] {
        browser.delegate = self
        browser.searchForServices(ofType: "_uscan._tcp.", inDomain: "local.")
        let deadline = Date().addingTimeInterval(timeout)
        while !done, Date() < deadline,
              RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2)) {}
        browser.stop()
        return results
    }

    func netServiceBrowser(_ b: NetServiceBrowser, didFind service: NetService,
                           moreComing: Bool) {
        service.delegate = self
        pending.append(service)
        service.resolve(withTimeout: 4.0)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        var rs = "eSCL"
        if let data = sender.txtRecordData() {
            let txt = NetService.dictionary(fromTXTRecord: data)
            if let v = txt["rs"], let s = String(data: v, encoding: .utf8), !s.isEmpty {
                rs = s
            }
        }
        var host = sender.hostName ?? ""
        if host.hasSuffix(".") { host.removeLast() }
        if !host.isEmpty {
            results.append(Found(name: sender.name, host: host,
                                 port: sender.port, rs: rs))
        }
        finish(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(sender)
    }

    private func finish(_ service: NetService) {
        pending.removeAll { $0 === service }
        // Stop early once the first batch has resolved.
        if pending.isEmpty && !results.isEmpty { done = true }
    }
}

// MARK: - HTTP

struct HTTPReply: Sendable {
    let status: Int
    let location: String?
    let data: Data
}

/// Hands the URLSession callback's result to the thread waiting on it.
private final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<HTTPReply, Error>?

    var result: Result<HTTPReply, Error>? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func finish(_ value: Result<HTTPReply, Error>) {
        lock.lock(); defer { lock.unlock() }
        stored = value
    }
}

@discardableResult
func http(_ method: String, _ url: URL, body: Data? = nil,
          contentType: String? = nil, timeout: TimeInterval = 300) throws -> HTTPReply {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = method
    req.httpBody = body
    req.setValue("brscan/1.0", forHTTPHeaderField: "User-Agent")
    if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }

    let sem = DispatchSemaphore(value: 0)
    let completion = Completion()
    let task = URLSession.shared.dataTask(with: req) { data, response, error in
        if let error {
            completion.finish(.failure(error))
        } else if let r = response as? HTTPURLResponse {
            completion.finish(.success(HTTPReply(
                status: r.statusCode,
                location: r.value(forHTTPHeaderField: "Location"),
                data: data ?? Data())))
        }
        sem.signal()
    }
    task.resume()

    if sem.wait(timeout: .now() + timeout + 5) == .timedOut {
        task.cancel()
        throw ScanError("\(method) \(url.path) timed out")
    }
    switch completion.result {
    case .success(let reply)?:
        return reply
    case .failure(let failure)?:
        throw ScanError("Cannot reach \(url.host ?? "scanner"): "
                        + failure.localizedDescription)
    case nil:
        throw ScanError("No response from \(url)")
    }
}

// MARK: - eSCL

struct PlatenCaps {
    var makeAndModel = "?"
    var version = "2.63"
    var maxWidth = 2550, maxHeight = 3507
    var colorModes: [String] = []
    var formats: [String] = []
    var resolutions: [String] = []
    var intents: [String] = []
    var opticalX = "", opticalY = ""
    var hasADF = false
}

/// Text of every element with this local name, optionally under an ancestor.
/// eSCL documents are small and regular, so matching by name is enough and
/// sidesteps namespace prefixes that vary between firmwares.
func values(in doc: XMLDocument, _ name: String, under ancestor: String? = nil) -> [String] {
    let path = (ancestor.map { "//*[local-name()='\($0)']" } ?? "")
        + "//*[local-name()='\(name)']"
    return ((try? doc.nodes(forXPath: path)) ?? []).compactMap {
        $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func parseCaps(_ data: Data) throws -> PlatenCaps {
    guard let doc = try? XMLDocument(data: data) else {
        throw ScanError("Could not parse ScannerCapabilities.")
    }
    func first(_ name: String) -> String? { values(in: doc, name).first }
    func platen(_ name: String) -> [String] {
        values(in: doc, name, under: "PlatenInputCaps")
    }

    var c = PlatenCaps()
    c.makeAndModel = first("MakeAndModel") ?? c.makeAndModel
    c.version = first("Version") ?? c.version
    if let n = platen("MaxWidth").first.flatMap({ Int($0) }) { c.maxWidth = n }
    if let n = platen("MaxHeight").first.flatMap({ Int($0) }) { c.maxHeight = n }
    guard c.maxWidth > 0, c.maxHeight > 0 else {
        throw ScanError("ScannerCapabilities has invalid platen dimensions.")
    }
    c.colorModes = platen("ColorMode")
    c.formats = Array(Set(platen("DocumentFormat"))).sorted()
    c.resolutions = platen("XResolution")
    c.intents = platen("Intent")
    c.opticalX = first("MaxOpticalXResolution") ?? ""
    c.opticalY = first("MaxOpticalYResolution") ?? ""
    c.hasADF = !values(in: doc, "Adf").isEmpty
    return c
}

func scanSettings(version: String, mode: ColorMode, mime: String, dpi: Int,
                  intent: String, width: Int, height: Int) -> Data {
    // Element order follows the eSCL schema sequence and the region carries
    // MustHonor, because scanners that do read the body can be strict about
    // both. The DCP-T420W reads none of it.
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <scan:ScanSettings xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm" \
    xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03">
      <pwg:Version>\(version)</pwg:Version>
      <scan:Intent>\(intent)</scan:Intent>
      <pwg:ScanRegions pwg:MustHonor="true">
        <pwg:ScanRegion>
          <pwg:Height>\(height)</pwg:Height>
          <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
          <pwg:Width>\(width)</pwg:Width>
          <pwg:XOffset>0</pwg:XOffset>
          <pwg:YOffset>0</pwg:YOffset>
        </pwg:ScanRegion>
      </pwg:ScanRegions>
      <pwg:InputSource>Platen</pwg:InputSource>
      <scan:ColorMode>\(mode.escl)</scan:ColorMode>
      <scan:XResolution>\(dpi)</scan:XResolution>
      <scan:YResolution>\(dpi)</scan:YResolution>
      <pwg:DocumentFormat>\(mime)</pwg:DocumentFormat>
      <scan:DocumentFormatExt>\(mime)</scan:DocumentFormatExt>
    </scan:ScanSettings>
    """.data(using: .utf8)!
}

func scannerState(base: URL) -> String {
    guard let reply = try? http("GET", base.appendingPathComponent("ScannerStatus"),
                                timeout: 15),
          let doc = try? XMLDocument(data: reply.data),
          let state = values(in: doc, "State").first
    else { return "Unknown" }
    return state
}

func runScan(base: URL, settings: Data, verbose: Bool) throws -> [Data] {
    let created = try http("POST", base.appendingPathComponent("ScanJobs"),
                           body: settings, contentType: "text/xml", timeout: 60)
    guard created.status == 200 || created.status == 201 else {
        throw ScanError("Scanner refused the job (HTTP \(created.status)).")
    }
    guard let location = created.location else {
        throw ScanError("Scanner accepted the job but returned no Location header.")
    }

    // Some firmwares put an unreachable host in Location; keep ours.
    guard let resolved = URL(string: location, relativeTo: base.appendingPathComponent("ScanJobs")),
          let target = URLComponents(url: resolved, resolvingAgainstBaseURL: true),
          var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
        throw ScanError("Bad job URL: \(location)")
    }
    comps.percentEncodedPath = target.percentEncodedPath
    while comps.percentEncodedPath.hasSuffix("/") { comps.percentEncodedPath.removeLast() }
    comps.percentEncodedQuery = target.percentEncodedQuery
    guard let job = comps.url else { throw ScanError("Bad job URL: \(location)") }
    if verbose { err("  job \(job)") }
    defer { _ = try? http("DELETE", job, timeout: 15) } // also release failed jobs

    let next = job.appendingPathComponent("NextDocument")
    var pages: [Data] = []
    while true {
        let page = try http("GET", next)
        // 404/410 is the documented end-of-pages signal.
        if page.status == 404 || page.status == 410 { break }
        guard page.status == 200 else {
            throw ScanError("NextDocument returned HTTP \(page.status).")
        }
        guard !page.data.isEmpty else { throw ScanError("NextDocument returned an empty page.") }
        pages.append(page.data)
    }

    if pages.isEmpty { throw ScanError("Scanner returned no pages.") }
    return pages
}

// MARK: - Image processing

func loadImage(_ data: Data) throws -> CGImage {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw ScanError("Scanner returned data that is not a readable image.")
    }
    return img
}

func cropped(_ img: CGImage, widthMM: Double, heightMM: Double,
             platenWmm: Double, platenHmm: Double) -> CGImage {
    // Pixels are not square on this scanner, so scale each axis separately.
    let w = max(1, Int((min(1, widthMM / platenWmm) * Double(img.width)).rounded()))
    let h = max(1, Int((min(1, heightMM / platenHmm) * Double(img.height)).rounded()))
    // Origin is the top-left of the glass.
    return img.cropping(to: CGRect(x: 0, y: 0, width: w, height: h)) ?? img
}

func rotated(_ img: CGImage, degreesClockwise: Int) throws -> CGImage {
    let d = ((degreesClockwise % 360) + 360) % 360
    if d == 0 { return img }
    let w = img.width, h = img.height
    let swap = (d == 90 || d == 270)
    let outW = swap ? h : w, outH = swap ? w : h

    guard let ctx = CGContext(data: nil, width: outW, height: outH,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: img.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw ScanError("Could not allocate a context for rotation.")
    }
    ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
    // CoreGraphics rotates counter-clockwise, so negate for clockwise.
    ctx.rotate(by: -CGFloat(d) * .pi / 180)
    ctx.draw(img, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2,
                             width: CGFloat(w), height: CGFloat(h)))
    guard let out = ctx.makeImage() else {
        throw ScanError("Rotation failed.")
    }
    return out
}

func toGray(_ img: CGImage, threshold: Int?) throws -> CGImage {
    let w = img.width, h = img.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
        throw ScanError("Could not allocate a greyscale context.")
    }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

    if let threshold {
        guard let buf = ctx.data else { throw ScanError("No pixel buffer to threshold.") }
        let cutoff = UInt8(max(1, min(254, threshold)))
        let pixels = buf.bindMemory(to: UInt8.self, capacity: w * h)
        for i in 0 ..< (w * h) {
            pixels[i] = pixels[i] < cutoff ? 0 : 255
        }
    }
    guard let out = ctx.makeImage() else { throw ScanError("Greyscale conversion failed.") }
    return out
}

func write(_ img: CGImage, to url: URL, format: OutputFormat) throws {
    if format == .pdf {
        var box = CGRect(x: 0, y: 0, width: CGFloat(img.width), height: CGFloat(img.height))
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw ScanError("Could not create \(url.lastPathComponent).")
        }
        ctx.beginPDFPage(nil)
        ctx.draw(img, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
        return
    }

    let type = (format == .png ? UTType.png : UTType.jpeg).identifier as CFString
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
        throw ScanError("Could not create \(url.lastPathComponent).")
    }
    let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
    CGImageDestinationAddImage(dest, img, opts as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        throw ScanError("Could not write \(url.lastPathComponent).")
    }
}

// MARK: - CLI

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func platenMM(_ units: Int) -> Double { Double(units) / unitsPerInch * mmPerInch }

func describe(_ caps: PlatenCaps) -> String {
    var lines = [
        "Model        \(caps.makeAndModel)",
        "eSCL version \(caps.version)",
        "Sources      Platen\(caps.hasADF ? " + ADF" : " only (no document feeder)")",
        String(format: "Max area     %.0f x %.0f mm",
               platenMM(caps.maxWidth), platenMM(caps.maxHeight)),
    ]
    func list(_ label: String, _ items: [String], _ suffix: String = "") {
        if !items.isEmpty { lines.append(label + items.joined(separator: ", ") + suffix) }
    }
    list("Colour modes ", caps.colorModes)
    list("Formats      ", caps.formats)
    list("Resolutions  ", caps.resolutions, " dpi")
    list("Intents      ", caps.intents)
    if !caps.opticalX.isEmpty { lines.append("Optical      \(caps.opticalX) x \(caps.opticalY) dpi") }
    lines += ["",
              "Note: on the DCP-T420W these are claims only - the firmware",
              "ignores the settings you send and always scans the full platen",
              "in colour as JPEG. brscan applies the rest locally."]
    return lines.joined(separator: "\n")
}

/// The output format a file name implies, if any.
func inferredFormat(of path: String) -> OutputFormat? {
    switch (path as NSString).pathExtension.lowercased() {
    case "pdf": return .pdf
    case "jpg", "jpeg": return .jpeg
    case "png": return .png
    default: return nil
    }
}

/// scan.pdf, scan-2.pdf, scan-3.pdf, ...
func pageName(_ base: String, index: Int) -> String {
    guard index > 0 else { return base }
    let ns = base as NSString
    return "\(ns.deletingPathExtension)-\(index + 1).\(ns.pathExtension)"
}

func parseCrop(_ spec: String) throws -> (Double, Double) {
    if let preset = cropPresets[spec.lowercased()] { return preset }
    let parts = spec.lowercased().split(separator: "x", omittingEmptySubsequences: false)
    guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]),
          w.isFinite, h.isFinite, w > 0, h > 0 else {
        throw ScanError("Cannot parse --crop \(spec); use a preset or positive, finite WxH in mm.")
    }
    return (w, h)
}

let usage = """
brscan - scan from a Brother DCP-T420W over eSCL

  brscan                                full platen, colour, PDF
  brscan --mode gray --out receipt.pdf
  brscan --mode lineart --rotate 180 --out doc.pdf
  brscan --crop a6 --out photo.jpg
  brscan --raw                          exactly what the scanner sent

Options
  --host HOST        scanner address (default: discover over Bonjour)
  --port N           default 80
  --path P           eSCL root, from the TXT rs= key (default eSCL)
  --out FILE         default scan-<timestamp>.<ext>
  --format F         pdf, jpeg or png (default pdf, or from --out)
  --mode M           color, gray or lineart (default color)
  --threshold N      black/white cutoff 1-254 for lineart (default 128)
  --crop C           a4, letter, a5, a6, 4x6, 5x7, or WxH in mm
  --rotate D         0, 90, 180 or 270 clockwise
  --dpi N            requested of the device (default 300)
  --intent I         Document, TextAndGraphic, Photo, Preview
  --raw              save the scanner's bytes untouched
  --caps             show what the scanner claims, and exit
  --list             list scanners, and exit
  --status           print scanner state, and exit
  -v, --verbose

The DCP-T420W firmware ignores eSCL scan settings, so --mode, --crop,
--rotate and --format are applied locally after the scan.
"""

func main() -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    var host: String?, outPath: String?, cropSize: (Double, Double)?
    var port = 80, path = "eSCL", dpi = 300, rotate = 0, threshold = 128
    var mode = ColorMode.color, format: OutputFormat?, intent = "Document"
    var raw = false, wantCaps = false, wantList = false, wantStatus = false
    var verbose = false

    func value(_ flag: String) throws -> String {
        guard let next = args.first, !next.isEmpty, !next.hasPrefix("--") else {
            throw ScanError("\(flag) requires a value.")
        }
        return args.removeFirst()
    }

    func integer(_ flag: String, in range: ClosedRange<Int>) throws -> Int {
        let text = try value(flag)
        guard let n = Int(text), range.contains(n) else {
            throw ScanError("Invalid \(flag): \(text) (expected \(range.lowerBound)-\(range.upperBound)).")
        }
        return n
    }

    do {
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--host": host = try value(a)
            case "--port": port = try integer(a, in: 1...65535)
            case "--path": path = try value(a)
            case "--out": outPath = try value(a)
            case "--format":
                let v = try value(a)
                guard let f = OutputFormat(rawValue: v == "jpg" ? "jpeg" : v)
                else { err("brscan: bad --format"); return 2 }
                format = f
            case "--mode":
                guard let m = ColorMode(rawValue: try value(a))
                else { err("brscan: bad --mode"); return 2 }
                mode = m
            case "--threshold": threshold = try integer(a, in: 1...254)
            case "--crop": cropSize = try parseCrop(value(a))
            case "--rotate":
                rotate = try integer(a, in: 0...270)
                guard rotate % 90 == 0 else { throw ScanError("--rotate must be 0, 90, 180 or 270.") }
            case "--dpi": dpi = try integer(a, in: 1...Int(Int32.max))
            case "--intent":
                intent = try value(a)
                guard ["Document", "TextAndGraphic", "Photo", "Preview"].contains(intent) else {
                    throw ScanError("--intent must be Document, TextAndGraphic, Photo or Preview.")
                }
            case "--raw": raw = true
            case "--caps": wantCaps = true
            case "--list": wantList = true
            case "--status": wantStatus = true
            case "-v", "--verbose": verbose = true
            case "-h", "--help": print(usage); return 0
            default: err("brscan: unknown option \(a)"); return 2
            }
        }
    } catch {
        err("brscan: \(error)")
        return 2
    }

    do {
        if wantList {
            let found = Discovery().run(timeout: 6)
            if found.isEmpty { print("No eSCL scanners found."); return 1 }
            for f in found { print("\(f.name)\n  http://\(f.host):\(f.port)/\(f.rs)") }
            return 0
        }

        var h = host, p = port, rs = path
        if h == nil {
            let found = Discovery().run(timeout: 6)
            guard let first = found.first else {
                throw ScanError("No eSCL scanner found. Pass --host.")
            }
            h = first.host; p = first.port; rs = first.rs
            if verbose { err("Using \(first.name) at \(first.host):\(first.port)") }
        }

        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = h
        if p != 80 { comps.port = p }
        comps.path = "/" + rs.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let base = comps.url else { throw ScanError("Bad scanner address.") }

        if wantStatus { print(scannerState(base: base)); return 0 }

        let caps = try parseCaps(http("GET", base.appendingPathComponent("ScannerCapabilities"),
                                      timeout: 20).data)
        if wantCaps { print(describe(caps)); return 0 }

        let outFormat = format ?? outPath.flatMap(inferredFormat(of:)) ?? .pdf

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let defaultName = "scan-\(stamp.string(from: Date()))."
            + (raw ? "jpg" : outFormat.ext)
        let base0 = outPath ?? defaultName

        let state = scannerState(base: base)
        if state != "Idle" && state != "Unknown" {
            err("Scanner state is \(state); trying anyway...")
        }

        let mime = outFormat == .pdf ? "application/pdf" : "image/jpeg"
        let settings = scanSettings(version: caps.version, mode: mode, mime: mime,
                                    dpi: dpi, intent: intent,
                                    width: caps.maxWidth, height: caps.maxHeight)
        if verbose { err(String(data: settings, encoding: .utf8) ?? "") }

        err("Scanning...")
        let started = Date()
        let pages = try runScan(base: base, settings: settings, verbose: verbose)
        err(String(format: "Scanner returned %d page(s) in %.1fs",
                   pages.count, Date().timeIntervalSince(started)))

        let platenW = platenMM(caps.maxWidth), platenH = platenMM(caps.maxHeight)

        for (i, data) in pages.enumerated() {
            let name = pageName(base0, index: i)
            let url = URL(fileURLWithPath: name)

            if raw {
                try data.write(to: url)
            } else if data.starts(with: Array("%PDF".utf8)) {
                try data.write(to: url)      // already a PDF, pass it through
            } else {
                var img = try loadImage(data)
                if let size = cropSize {
                    img = cropped(img, widthMM: size.0, heightMM: size.1,
                                  platenWmm: platenW, platenHmm: platenH)
                    if verbose { err("  cropped to \(img.width)x\(img.height)px") }
                }
                if rotate != 0 { img = try rotated(img, degreesClockwise: rotate) }
                switch mode {
                case .color: break
                case .gray: img = try toGray(img, threshold: nil)
                case .lineart: img = try toGray(img, threshold: threshold)
                }
                try write(img, to: url, format: outFormat)
            }

            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                        as? Int) ?? 0
            print("Wrote \(name) (\(size / 1024) KB)")
        }
        return 0

    } catch let e as ScanError {
        err("brscan: \(e.description)")
        return 1
    } catch {
        err("brscan: \(error.localizedDescription)")
        return 1
    }
}

exit(main())
