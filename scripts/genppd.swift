// Generate the Brother DCP-T420W PPD.
//
// Every dimension below is transcribed from the printer's own IPP responses
// (media-size-supported, media-*-margin-supported, print-quality-supported), so
// the geometry in the PPD matches what the hardware reports rather than being
// hand-rounded. Run scripts/probe.sh to re-read those attributes from a printer.
//
//     make build/genppd && build/genppd > ppd/Brother-DCP-T420W.ppd
//     build/genppd --media       # tab-separated media table, used by the tests

import Foundation

// MARK: - Geometry helpers

/// Hundredths of a millimetre -> PostScript points.
func pt(_ hundredthsMM: Int) -> Double {
    Double(hundredthsMM) / 100.0 / 25.4 * 72.0
}

/// Format a point value the way CUPS writes them: compact, no exponent.
func num(_ value: Double) -> String {
    var text = String(format: "%.6f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text.isEmpty ? "0" : text
}

// Hardware margins, from media-{top,bottom,left,right}-margin-supported.
// The printer reports 300 (3 mm) for cut sheet, 1200 (12 mm) top/bottom for
// envelopes, and 0 for the borderless configurations.
let marginSheet = pt(300)  // 8.503937 pt
let marginEnvelopeTB = pt(1200)  // 34.015748 pt

// MARK: - Media, transcribed from media-supported / media-size-supported

enum Profile { case sheet, envelope }

struct Media {
    let name: String  // PPD choice name
    let keyword: String  // IPP keyword
    let width: Int, height: Int  // hundredths of mm
    let profile: Profile
    let borderless: Bool
    let english: String, korean: String
}

// Korean strings are supplied because the queue is used on a ko_KR system; the
// auto-generated IPP Everywhere PPD mistranslates several of these (notably
// "Draft" as "임시 저장", i.e. "temporary save").
let media: [Media] = [
    Media(
        name: "A4", keyword: "iso_a4_210x297mm", width: 21000, height: 29700,
        profile: .sheet, borderless: true, english: "A4", korean: "A4"),
    Media(
        name: "Letter", keyword: "na_letter_8.5x11in", width: 21590, height: 27940,
        profile: .sheet, borderless: true, english: "US Letter", korean: "US 레터"),
    Media(
        name: "Legal", keyword: "na_legal_8.5x14in", width: 21590, height: 35560,
        profile: .sheet, borderless: false, english: "US Legal", korean: "US 리걸"),
    Media(
        name: "Executive", keyword: "na_executive_7.25x10.5in", width: 18415, height: 26670,
        profile: .sheet, borderless: false, english: "Executive", korean: "이그제큐티브"),
    Media(
        name: "A5", keyword: "iso_a5_148x210mm", width: 14800, height: 21000,
        profile: .sheet, borderless: false, english: "A5", korean: "A5"),
    Media(
        name: "A6", keyword: "iso_a6_105x148mm", width: 10500, height: 14800,
        profile: .sheet, borderless: true, english: "A6", korean: "A6"),
    Media(
        name: "FanFoldGermanLegal", keyword: "na_foolscap_8.5x13in", width: 21590, height: 33020,
        profile: .sheet, borderless: false, english: "Folio 8.5x13in", korean: "폴리오 8.5x13인치"),
    Media(
        name: "Oficio", keyword: "na_oficio_8.5x13.4in", width: 21590, height: 34036,
        profile: .sheet, borderless: false, english: "Oficio 8.5x13.4in",
        korean: "오피시오 8.5x13.4인치"),
    Media(
        name: "215x345mm", keyword: "om_india-legal_215x345mm", width: 21500, height: 34500,
        profile: .sheet, borderless: false, english: "India Legal 215x345mm",
        korean: "인디아 리걸 215x345mm"),
    Media(
        name: "4x6", keyword: "na_index-4x6_4x6in", width: 10160, height: 15240,
        profile: .sheet, borderless: true, english: "4x6in Photo", korean: "4x6인치 인화지"),
    Media(
        name: "3.5x5", keyword: "oe_photo-l_3.5x5in", width: 8890, height: 12700,
        profile: .sheet, borderless: true, english: "3.5x5in Photo (L)",
        korean: "3.5x5인치 인화지 (L)"),
    Media(
        name: "5x7", keyword: "na_5x7_5x7in", width: 12700, height: 17780,
        profile: .sheet, borderless: true, english: "5x7in Photo", korean: "5x7인치 인화지"),
    Media(
        name: "5x8", keyword: "na_index-5x8_5x8in", width: 12700, height: 20320,
        profile: .sheet, borderless: true, english: "5x8in Index Card", korean: "5x8인치 카드"),
    Media(
        name: "Env10", keyword: "na_number-10_4.125x9.5in", width: 10477, height: 24130,
        profile: .envelope, borderless: false, english: "Envelope #10", korean: "봉투 #10"),
    Media(
        name: "EnvDL", keyword: "iso_dl_110x220mm", width: 11000, height: 22000,
        profile: .envelope, borderless: false, english: "Envelope DL", korean: "봉투 DL"),
    Media(
        name: "EnvC5", keyword: "iso_c5_162x229mm", width: 16200, height: 22900,
        profile: .envelope, borderless: false, english: "Envelope C5", korean: "봉투 C5"),
    Media(
        name: "EnvMonarch", keyword: "na_monarch_3.875x7.5in", width: 9842, height: 19050,
        profile: .envelope, borderless: false, english: "Envelope Monarch",
        korean: "봉투 몬라크"),
]

// media-type-supported. Keep the vendor keyword lowercase and literal:
// macOS CUPS inserts an unwanted dash before 71 in a CamelCase choice name.
// A top-level cupsMediaType attribute does not override that cache mapping.
let mediaTypes: [(choice: String, keyword: String, english: String, korean: String)] = [
    ("Stationery", "stationery", "Plain Paper", "일반 용지"),
    ("StationeryInkjet", "stationery-inkjet", "Inkjet Paper", "잉크젯 용지"),
    ("PhotographicGlossy", "photographic-glossy", "Glossy Photo Paper", "광택 인화지"),
    ("com.brother-bp71", "com.brother-bp71", "Brother BP71 Photo", "브라더 BP71 인화지"),
]

// macOS' native quality menu uses its own Draft/Normal/Best labels, ignoring
// the PPD choice text. Driver presets keep the raster DPI visible in the
// top-level Presets control, and also advertise all qualities to CUPS clients.
// Set the paper type explicitly: macOS otherwise resets it when applying a
// driver preset. Size/source and page handling are not encoded in our presets.
struct Quality {
    let name: String
    let level: String
    let dpi: Int
    let presetEnglish: String, presetKorean: String
    let optionEnglishTemplate: String, optionKoreanTemplate: String

    var optionEnglish: String {
        optionEnglishTemplate.replacingOccurrences(of: "{dpi}", with: "\(dpi)")
    }

    var optionKorean: String {
        optionKoreanTemplate.replacingOccurrences(of: "{dpi}", with: "\(dpi)")
    }
}

let qualities = [
    Quality(
        name: "Draft", level: "low", dpi: 300, presetEnglish: "Eco", presetKorean: "에코",
        optionEnglishTemplate: "Eco ({dpi}dpi, saves ink)",
        optionKoreanTemplate: "에코 ({dpi}dpi, 잉크 절약)"),
    Quality(
        name: "Normal", level: "mid", dpi: 600, presetEnglish: "Standard", presetKorean: "표준",
        optionEnglishTemplate: "Standard Document ({dpi}dpi)",
        optionKoreanTemplate: "표준 문서 ({dpi}dpi)"),
    Quality(
        name: "High", level: "high", dpi: 600, presetEnglish: "High Quality",
        presetKorean: "고화질",
        optionEnglishTemplate: "High Quality ({dpi}dpi)",
        optionKoreanTemplate: "고화질 ({dpi}dpi)"),
]

struct Preset {
    let name: String, color: String, mode: String
    let quality: Quality
    let media: String, coating: String
    let english: String, korean: String
}

func presets() -> [Preset] {
    var out: [Preset] = []
    let colors = [
        ("RGB", "color", "Color", "컬러"),
        ("Gray", "monochrome", "Grayscale", "흑백"),
    ]
    for (color, mode, englishColor, koreanColor) in colors {
        for quality in qualities {
            out.append(
                Preset(
                    name: "\(color)_\(quality.name)", color: color, mode: mode,
                    quality: quality, media: "Stationery", coating: "none",
                    english:
                        "\(englishColor) Document - \(quality.presetEnglish) (\(quality.dpi) dpi)",
                    korean: "\(koreanColor) 문서 · \(quality.presetKorean) (\(quality.dpi) dpi)"))
        }
    }
    let high = qualities[2]
    let photos = [
        ("PhotoGlossy", "PhotographicGlossy", "Glossy Photo", "광택 사진"),
        ("PhotoBP71", "com.brother-bp71", "Brother BP71 Photo", "BP71 사진"),
    ]
    for (name, paper, english, korean) in photos {
        out.append(
            Preset(
                name: name, color: "RGB", mode: "color", quality: high, media: paper,
                coating: "glossy",
                english: "\(english) - \(high.presetEnglish) (\(high.dpi) dpi)",
                korean: "\(korean) · \(high.presetKorean) (\(high.dpi) dpi)"))
    }
    return out
}

// Custom size range, from custom_min_88.9x127mm / custom_max_215.9x355.6mm.
let customMinWidth = pt(8890), customMinHeight = pt(12700)
let customMaxWidth = pt(21590), customMaxHeight = pt(35560)

/// Margins in points: left, bottom, right, top.
typealias Margins = (left: Double, bottom: Double, right: Double, top: Double)

func margins(_ profile: Profile) -> Margins {
    switch profile {
    case .envelope: (marginSheet, marginEnvelopeTB, marginSheet, marginEnvelopeTB)
    case .sheet: (marginSheet, marginSheet, marginSheet, marginSheet)
    }
}

struct Entry {
    let name: String
    let width: Double, height: Double
    let margins: Margins
    let english: String, korean: String
}

func entries() -> [Entry] {
    var out: [Entry] = []
    for m in media {
        let width = pt(m.width), height = pt(m.height)
        out.append(
            Entry(
                name: m.name, width: width, height: height, margins: margins(m.profile),
                english: m.english, korean: m.korean))
        if m.borderless {
            out.append(
                Entry(
                    name: "\(m.name).Borderless", width: width, height: height,
                    margins: (0, 0, 0, 0), english: "\(m.english) (Borderless)",
                    korean: "\(m.korean) (여백 없음)"))
        }
    }
    return out
}

// MARK: - Output

func ppd() -> String {
    var out = ""
    func w(_ line: String) { out += line + "\n" }
    let items = entries()

    // -- Header ---------------------------------------------------------------
    w(#"*PPD-Adobe: "4.3""#)
    w("*%% Brother DCP-T420W - PWG Raster driver for macOS")
    w("*%% Generated by scripts/genppd.swift from the printer's IPP attributes.")
    w(#"*FormatVersion: "4.3""#)
    w(#"*FileVersion: "1.5.1""#)
    w("*LanguageVersion: English")
    w("*LanguageEncoding: ISOLatin1")
    w(#"*PSVersion: "(3010.000) 0""#)
    w(#"*LanguageLevel: "3""#)
    w("*FileSystem: False")
    w(#"*PCFileName: "brdcp420.ppd""#)
    w(#"*Manufacturer: "Brother""#)
    w(#"*ModelName: "Brother DCP-T420W""#)
    w(#"*Product: "(DCP-T420W)""#)
    w(#"*NickName: "Brother DCP-T420W (PWG Raster)""#)
    w(#"*ShortNickName: "Brother DCP-T420W""#)
    w("*ColorDevice: True")
    // Select macOS' native Color and Media & Quality controls instead of the
    // nested generic Printer Features/Paper Feed dialogs. This is the local
    // driver's UI hint, as emitted by Apple's ipp2ppd; the physical printer
    // still needs our PWG conversion. Do not add an automatic PPD replacement
    // tool or a pass-through filter here.
    w("*APAirPrint: True")
    w("*cupsVersion: 2.3")
    w("*cupsModelNumber: 420")
    w(#"*cupsLanguages: "ko""#)
    w("*cupsSNMPSupplies: False")
    w("*cupsIPPSupplies: True")
    w("*cupsManualCopies: True")
    // Let the macOS PDF renderer order pages, before they reach our streaming
    // raster filter. An explicit per-job outputorder=normal still overrides it.
    w("*DefaultOutputOrder: Reverse")
    w(#"*1284DeviceID: "MFG:Brother;CMD:HBP,PJL;MDL:DCP-T420W;CLS:PRINTER;""#)
    w("\n*%% Filter chain. cgpdftoraster can emit image/pwg-raster in one step, but it")
    w(#"*%% labels the page with PPD names ("A4.Borderless", "Stationery") where PWG"#)
    w("*%% Raster calls for IPP keywords. Declaring the cups-raster *cupsFilter2 is")
    w("*%% what forces our route: CUPS turns each *cupsFilter2 into an edge into")
    w("*%% printer/<queue>, so cgpdftoraster feeds rastertobrother rather than")
    w("*%% reaching the queue on its own.")
    w(#"*cupsFilter2: "application/vnd.cups-raster image/pwg-raster 20 rastertobrother""#)

    w("\n*%% The second edge is for iOS. AirPrint clients send Apple Raster, and")
    w("*%% libcups reads it transparently -- cupsRasterOpen() in read mode detects")
    w("*%% the UNIRAST sync word (CUPS_RASTER_HAVE_APPLERASTER), so rastertobrother")
    w("*%% needs no code for it. Without this edge CUPS still advertises image/urf,")
    w("*%% because the image/* wildcard in apple.convs routes it through")
    w("*%% cgimagetopdf -- which cannot read Apple Raster, so the job dies there.")
    w("*%%")
    w("*%% Cost 40 is chosen to sit inside a window, not picked for taste:")
    w("*%%   image/urf direct         = 40   vs via cgimagetopdf 25+100+20 = 145")
    w("*%%   application/pdf as today = 120  vs via cgpdftoraster+urf 100+40 = 140")
    w("*%% so URF takes this edge while PDF stays on the tested raster route.")
    w(#"*cupsFilter2: "image/urf image/pwg-raster 40 rastertobrother""#)

    w("\n*%% What makes the queue AirPrint rather than Mopria when it is shared.")
    w("*%% iOS looks for a URF key in the Bonjour TXT record and ignores anything")
    w("*%% without one -- the printer itself has no urf-supported attribute, which")
    w("*%% is the whole reason this driver exists, so the Mac has to supply it.")
    w("*%% DM1 is simplex-only, which is honest: the DCP-T420W has no duplexer.")
    w(#"*cupsUrfSupported: "CP1,IS1,PQ3-4-5,RS300-600,SRGB24,W8,DM1,FN3,V1.4""#)
    w("")

    // -- PageSize / PageRegion ------------------------------------------------
    for keyword in ["PageSize", "PageRegion"] {
        w("*OpenUI *\(keyword): PickOne")
        w("*OrderDependency: 10 AnySetup *\(keyword)")
        w("*ko.Translation \(keyword)/용지 크기: \"\"")
        w("*Default\(keyword): A4")
        for e in items {
            w(
                "*\(keyword) \(e.name)/\(e.english): "
                    + "\"<</PageSize[\(num(e.width)) \(num(e.height))]>>setpagedevice\"")
            w("*ko.\(keyword) \(e.name)/\(e.korean): \"\"")
        }
        w("*CloseUI: *\(keyword)\n")
    }

    // -- Imageable areas ------------------------------------------------------
    w("*DefaultImageableArea: A4")
    w("*DefaultPaperDimension: A4")
    for e in items {
        let m = e.margins
        w(
            "*ImageableArea \(e.name): \"\(num(m.left)) \(num(m.bottom)) "
                + "\(num(e.width - m.right)) \(num(e.height - m.top))\"")
    }
    w("")
    for e in items {
        w("*PaperDimension \(e.name): \"\(num(e.width)) \(num(e.height))\"")
    }
    w("")
    let hwMargins = Array(repeating: num(marginSheet), count: 4).joined(separator: " ")
    w("*HWMargins: \"\(hwMargins)\"\n")

    // -- Custom sizes ---------------------------------------------------------
    w("*MaxMediaWidth: \"\(num(customMaxWidth))\"")
    w("*MaxMediaHeight: \"\(num(customMaxHeight))\"")
    w("*ParamCustomPageSize Width: 1 points \(num(customMinWidth)) \(num(customMaxWidth))")
    w("*ParamCustomPageSize Height: 2 points \(num(customMinHeight)) \(num(customMaxHeight))")
    w("*ParamCustomPageSize WidthOffset: 3 points 0 0")
    w("*ParamCustomPageSize HeightOffset: 4 points 0 0")
    w("*ParamCustomPageSize Orientation: 5 int 0 3")
    w(
        #"*CustomPageSize True: "pop pop pop <</PageSize[5 -2 roll]/ImagingBBox null>>setpagedevice""#
    )
    w("*CustomHWMargins: \"\(hwMargins)\"\n")

    // -- Input slot -----------------------------------------------------------
    w("*OpenUI *InputSlot: PickOne")
    w("*OrderDependency: 10 AnySetup *InputSlot")
    w(#"*ko.Translation InputSlot/용지 공급: """#)
    w("*DefaultInputSlot: Auto")
    w(#"*InputSlot Auto/Auto Select: "<</MediaPosition 0>>setpagedevice""#)
    w(#"*ko.InputSlot Auto/자동 선택: """#)
    w(#"*InputSlot Main/Paper Tray: "<</MediaPosition 1>>setpagedevice""#)
    w(#"*ko.InputSlot Main/용지함: """#)
    w("*CloseUI: *InputSlot\n")

    // -- Colour model ---------------------------------------------------------
    w("*OpenUI *ColorModel/Color Mode: PickOne")
    w("*OrderDependency: 10 AnySetup *ColorModel")
    w(#"*ko.Translation ColorModel/색상 모드: """#)
    w("*DefaultColorModel: RGB")
    w(
        #"*ColorModel RGB/Color: "<</cupsColorSpace 19/cupsBitsPerColor 8"#
            + #"/cupsColorOrder 0/cupsCompression 0>>setpagedevice""#)
    w(#"*ko.ColorModel RGB/컬러: """#)
    w(
        #"*ColorModel Gray/Grayscale: "<</cupsColorSpace 18/cupsBitsPerColor 8"#
            + #"/cupsColorOrder 0/cupsCompression 0>>setpagedevice""#)
    w(#"*ko.ColorModel Gray/흑백 (회색조): """#)
    w("*CloseUI: *ColorModel\n")

    // -- Print quality --------------------------------------------------------
    // printer-resolution-supported is 600dpi only, so the IPP attribute stays at
    // 600 while pwg-raster-document-resolution-supported (600, 300) lets Draft
    // render at 300dpi for speed and ink saving.
    w("*DefaultResolution: 600dpi\n")
    w("*OpenUI *cupsPrintQuality/Print Quality: PickOne")
    w("*OrderDependency: 10 AnySetup *cupsPrintQuality")
    w(#"*ko.Translation cupsPrintQuality/인쇄 품질: """#)
    w("*DefaultcupsPrintQuality: Normal")
    for q in qualities {
        w(
            "*cupsPrintQuality \(q.name)/\(q.optionEnglish): "
                + "\"<</HWResolution[\(q.dpi) \(q.dpi)]>>setpagedevice\"")
        w("*ko.cupsPrintQuality \(q.name)/\(q.optionKorean): \"\"")
    }
    w("*CloseUI: *cupsPrintQuality\n")

    // -- Media type -----------------------------------------------------------
    w("*OpenUI *MediaType/Paper Type: PickOne")
    w("*OrderDependency: 10 AnySetup *MediaType")
    w(#"*ko.Translation MediaType/용지 종류: """#)
    w("*DefaultMediaType: Stationery")
    // The native macOS pane sorts localized labels, and displays the first
    // entry when the job has no explicit MediaType. Keep the shipped default
    // (plain paper) first in both locales instead of misleadingly showing
    // Glossy while the renderer uses Stationery. Numbering also keeps the
    // four choices in the same predictable order in every print dialog.
    for (index, t) in mediaTypes.enumerated() {
        let n = index + 1
        w(
            "*MediaType \(t.choice)/\(n). \(t.english): \"<</MediaType(\(t.keyword))>>setpagedevice\""
        )
        w("*ko.MediaType \(t.choice)/\(n). \(t.korean): \"\"")
    }
    w("*CloseUI: *MediaType\n")

    // Built-in presets are visible immediately; no user-saved plist is needed.
    // CUPS and cgpdftoraster consume the same option pairs as the print dialog.
    for p in presets() {
        w("*APPrinterPreset \(p.name)/\(p.english): \"")
        w(" *ColorModel \(p.color) *cupsPrintQuality \(p.quality.name)")
        w(" *MediaType \(p.media)")
        w(" com.apple.print.preset.graphicsType General")
        w(" com.apple.print.preset.quality \(p.quality.level)")
        w(" com.apple.print.preset.media-front-coating \(p.coating)")
        w(" com.apple.print.preset.output-mode \(p.mode)\"")
        w("*End")
        w("*ko.APPrinterPreset \(p.name)/\(p.korean): \"\"")
    }
    w("")

    // -- Constraints ----------------------------------------------------------
    // Borderless is a photo-path feature; the printer cannot pull an envelope
    // or plain-paper full-bleed sheet from the same path.
    w("*%% Borderless output requires photo media.")
    for e in items where e.name.hasSuffix(".Borderless") {
        w("*UIConstraints: *PageSize \(e.name) *MediaType Stationery")
        w("*UIConstraints: *MediaType Stationery *PageSize \(e.name)")
    }
    w("")

    // No *APSupplies here: it would hard-code one unit's hostname (which is
    // derived from its MAC address). *cupsIPPSupplies above already reports
    // ink levels over IPP, and works for any DCP-T420W on the network.
    w("*%% End of PPD")
    return out
}

func mediaTable() -> String {
    media.map { "\($0.name)\t\($0.keyword)\t\($0.width)\t\($0.height)\n" }.joined()
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments {
case []: FileHandle.standardOutput.write(Data(ppd().utf8))
case ["--media"]: FileHandle.standardOutput.write(Data(mediaTable().utf8))
default:
    FileHandle.standardError.write(Data("usage: genppd [--media]\n".utf8))
    exit(2)
}
