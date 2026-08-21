#!/usr/bin/env python3
"""Generate the Brother DCP-T420W PPD.

Every dimension below is transcribed from the printer's own IPP responses
(media-size-supported, media-*-margin-supported, print-quality-supported), so
the geometry in the PPD matches what the hardware reports rather than being
hand-rounded. Run scripts/probe.sh to re-read those attributes from a printer.

    python3 scripts/genppd.py > ppd/Brother-DCP-T420W.ppd
"""

import sys

# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

def pt(hundredths_mm):
    """Hundredths of a millimetre -> PostScript points."""
    return hundredths_mm / 100.0 / 25.4 * 72.0


def num(value):
    """Format a point value the way CUPS writes them: compact, no exponent."""
    text = f"{value:.6f}".rstrip("0").rstrip(".")
    return text if text else "0"


# Hardware margins, from media-{top,bottom,left,right}-margin-supported.
# The printer reports 300 (3 mm) for cut sheet, 1200 (12 mm) top/bottom for
# envelopes, and 0 for the borderless configurations.
MARGIN_SHEET = pt(300)      # 8.503937 pt
MARGIN_ENV_TB = pt(1200)    # 34.015748 pt

# ---------------------------------------------------------------------------
# Media, transcribed from media-supported / media-size-supported
#
#   ppd name, IPP keyword, width, height (hundredths of mm), profile, borderless
# ---------------------------------------------------------------------------

SHEET, ENVELOPE = "sheet", "envelope"

MEDIA = [
    ("A4",                 "iso_a4_210x297mm",           21000, 29700, SHEET,    True),
    ("Letter",             "na_letter_8.5x11in",         21590, 27940, SHEET,    True),
    ("Legal",              "na_legal_8.5x14in",          21590, 35560, SHEET,    False),
    ("Executive",          "na_executive_7.25x10.5in",   18415, 26670, SHEET,    False),
    ("A5",                 "iso_a5_148x210mm",           14800, 21000, SHEET,    False),
    ("A6",                 "iso_a6_105x148mm",           10500, 14800, SHEET,    True),
    ("FanFoldGermanLegal", "na_foolscap_8.5x13in",       21590, 33020, SHEET,    False),
    ("Oficio",             "na_oficio_8.5x13.4in",       21590, 34036, SHEET,    False),
    ("215x345mm",          "om_india-legal_215x345mm",   21500, 34500, SHEET,    False),
    ("4x6",                "na_index-4x6_4x6in",         10160, 15240, SHEET,    True),
    ("3.5x5",              "oe_photo-l_3.5x5in",          8890, 12700, SHEET,    True),
    ("5x7",                "na_5x7_5x7in",               12700, 17780, SHEET,    True),
    ("5x8",                "na_index-5x8_5x8in",         12700, 20320, SHEET,    True),
    ("Env10",              "na_number-10_4.125x9.5in",   10477, 24130, ENVELOPE, False),
    ("EnvDL",              "iso_dl_110x220mm",           11000, 22000, ENVELOPE, False),
    ("EnvC5",              "iso_c5_162x229mm",           16200, 22900, ENVELOPE, False),
    ("EnvMonarch",         "na_monarch_3.875x7.5in",      9842, 19050, ENVELOPE, False),
]

# Human-readable names. Korean strings are supplied because the queue is used on
# a ko_KR system; the auto-generated IPP Everywhere PPD mistranslates several of
# these (notably "Draft" as "임시 저장", i.e. "temporary save").
MEDIA_TEXT = {
    "A4":                 ("A4",                    "A4"),
    "Letter":             ("US Letter",             "US 레터"),
    "Legal":              ("US Legal",              "US 리걸"),
    "Executive":          ("Executive",             "이그제큐티브"),
    "A5":                 ("A5",                    "A5"),
    "A6":                 ("A6",                    "A6"),
    "FanFoldGermanLegal": ("Folio 8.5x13in",        "폴리오 8.5x13인치"),
    "Oficio":             ("Oficio 8.5x13.4in",     "오피시오 8.5x13.4인치"),
    "215x345mm":          ("India Legal 215x345mm", "인디아 리걸 215x345mm"),
    "4x6":                ("4x6in Photo",           "4x6인치 인화지"),
    "3.5x5":              ("3.5x5in Photo (L)",     "3.5x5인치 인화지 (L)"),
    "5x7":                ("5x7in Photo",           "5x7인치 인화지"),
    "5x8":                ("5x8in Index Card",      "5x8인치 카드"),
    "Env10":              ("Envelope #10",          "봉투 #10"),
    "EnvDL":              ("Envelope DL",           "봉투 DL"),
    "EnvC5":              ("Envelope C5",           "봉투 C5"),
    "EnvMonarch":         ("Envelope Monarch",      "봉투 몬라크"),
}

# media-type-supported. The PPD choice names are chosen so that CUPS'
# pwg_unppdize_name() recovers the exact IPP keyword, and the mapping is also
# stated explicitly via *cupsMediaType for good measure.
MEDIA_TYPES = [
    ("Stationery",         "stationery",          "Plain Paper",        "일반 용지"),
    ("StationeryInkjet",   "stationery-inkjet",   "Inkjet Paper",       "잉크젯 용지"),
    ("PhotographicGlossy", "photographic-glossy", "Glossy Photo Paper", "광택 인화지"),
    ("Com.brotherBp71",    "com.brother-bp71",    "Brother BP71 Photo", "브라더 BP71 인화지"),
]

# Custom size range, from custom_min_88.9x127mm / custom_max_215.9x355.6mm.
CUSTOM_MIN_W, CUSTOM_MIN_H = pt(8890), pt(12700)
CUSTOM_MAX_W, CUSTOM_MAX_H = pt(21590), pt(35560)


def margins(profile, borderless):
    """Return (left, bottom, right, top) margins in points."""
    if borderless:
        return (0.0, 0.0, 0.0, 0.0)
    if profile == ENVELOPE:
        return (MARGIN_SHEET, MARGIN_ENV_TB, MARGIN_SHEET, MARGIN_ENV_TB)
    return (MARGIN_SHEET, MARGIN_SHEET, MARGIN_SHEET, MARGIN_SHEET)


def entries():
    """Yield (ppd_name, width_pt, height_pt, margins, english, korean)."""
    for name, _keyword, w_hmm, h_hmm, profile, borderless in MEDIA:
        w, h = pt(w_hmm), pt(h_hmm)
        en, ko = MEDIA_TEXT[name]
        yield (name, w, h, margins(profile, False), en, ko)
        if borderless:
            yield (f"{name}.Borderless", w, h, (0.0, 0.0, 0.0, 0.0),
                   f"{en} (Borderless)", f"{ko} (여백 없음)")


def main(out=sys.stdout):
    w = out.write
    items = list(entries())

    # -- Header ------------------------------------------------------------
    w('*PPD-Adobe: "4.3"\n')
    w("*%% Brother DCP-T420W - PWG Raster driver for macOS\n")
    w("*%% Generated by scripts/genppd.py from the printer's IPP attributes.\n")
    w('*FormatVersion: "4.3"\n')
    w('*FileVersion: "1.0"\n')
    w("*LanguageVersion: English\n")
    w("*LanguageEncoding: ISOLatin1\n")
    w('*PSVersion: "(3010.000) 0"\n')
    w('*LanguageLevel: "3"\n')
    w("*FileSystem: False\n")
    w("*PCFileName: "'"brdcp420.ppd"'"\n")
    w('*Manufacturer: "Brother"\n')
    w('*ModelName: "Brother DCP-T420W"\n')
    w('*Product: "(DCP-T420W)"\n')
    w('*NickName: "Brother DCP-T420W (PWG Raster)"\n')
    w('*ShortNickName: "Brother DCP-T420W"\n')
    w("*ColorDevice: True\n")
    w('*cupsVersion: 2.3\n')
    w('*cupsModelNumber: 420\n')
    w("*cupsLanguages: "'"ko"'"\n")
    w("*cupsSNMPSupplies: False\n")
    w("*cupsIPPSupplies: True\n")
    w("*cupsManualCopies: True\n")
    w('*1284DeviceID: "MFG:Brother;CMD:HBP,PJL;MDL:DCP-T420W;CLS:PRINTER;"\n')
    w("\n*%% Filter chain. cgpdftoraster can emit image/pwg-raster in one step, but it\n")
    w("*%% labels the page with PPD names (\"A4.Borderless\", \"Stationery\") where PWG\n")
    w("*%% Raster calls for IPP keywords. Declaring exactly one *cupsFilter2, from\n")
    w("*%% application/vnd.cups-raster, is what forces our route: CUPS turns each\n")
    w("*%% *cupsFilter2 into an edge into printer/<queue>, so the only way to reach\n")
    w("*%% the queue is through rastertobrother, with cgpdftoraster feeding it.\n")
    w('*cupsFilter2: "application/vnd.cups-raster image/pwg-raster 20 rastertobrother"\n')
    w("\n")

    # -- PageSize / PageRegion --------------------------------------------
    for keyword in ("PageSize", "PageRegion"):
        w(f"*OpenUI *{keyword}: PickOne\n")
        w(f"*OrderDependency: 10 AnySetup *{keyword}\n")
        w(f"*ko.Translation {keyword}/용지 크기: \"\"\n")
        w(f"*Default{keyword}: A4\n")
        for name, pw, ph, _m, en, ko in items:
            w(f'*{keyword} {name}/{en}: '
              f'"<</PageSize[{num(pw)} {num(ph)}]>>setpagedevice"\n')
            w(f'*ko.{keyword} {name}/{ko}: ""\n')
        w(f"*CloseUI: *{keyword}\n\n")

    # -- Imageable areas ---------------------------------------------------
    w("*DefaultImageableArea: A4\n")
    w("*DefaultPaperDimension: A4\n")
    for name, pw, ph, (ml, mb, mr, mt), _en, _ko in items:
        w(f'*ImageableArea {name}: '
          f'"{num(ml)} {num(mb)} {num(pw - mr)} {num(ph - mt)}"\n')
    w("\n")
    for name, pw, ph, _m, _en, _ko in items:
        w(f'*PaperDimension {name}: "{num(pw)} {num(ph)}"\n')
    w("\n")
    w(f'*HWMargins: "{num(MARGIN_SHEET)} {num(MARGIN_SHEET)} '
      f'{num(MARGIN_SHEET)} {num(MARGIN_SHEET)}"\n\n')

    # -- Custom sizes ------------------------------------------------------
    w(f'*MaxMediaWidth: "{num(CUSTOM_MAX_W)}"\n')
    w(f'*MaxMediaHeight: "{num(CUSTOM_MAX_H)}"\n')
    w(f"*ParamCustomPageSize Width: 1 points {num(CUSTOM_MIN_W)} {num(CUSTOM_MAX_W)}\n")
    w(f"*ParamCustomPageSize Height: 2 points {num(CUSTOM_MIN_H)} {num(CUSTOM_MAX_H)}\n")
    w("*ParamCustomPageSize WidthOffset: 3 points 0 0\n")
    w("*ParamCustomPageSize HeightOffset: 4 points 0 0\n")
    w("*ParamCustomPageSize Orientation: 5 int 0 3\n")
    w('*CustomPageSize True: "pop pop pop <</PageSize[5 -2 roll]'
      '/ImagingBBox null>>setpagedevice"\n')
    w(f'*CustomHWMargins: "{num(MARGIN_SHEET)} {num(MARGIN_SHEET)} '
      f'{num(MARGIN_SHEET)} {num(MARGIN_SHEET)}"\n\n')

    # -- Input slot --------------------------------------------------------
    w("*OpenUI *InputSlot: PickOne\n")
    w("*OrderDependency: 10 AnySetup *InputSlot\n")
    w('*ko.Translation InputSlot/용지 공급: ""\n')
    w("*DefaultInputSlot: Auto\n")
    w('*InputSlot Auto/Auto Select: "<</MediaPosition 0>>setpagedevice"\n')
    w('*ko.InputSlot Auto/자동 선택: ""\n')
    w('*InputSlot Main/Paper Tray: "<</MediaPosition 1>>setpagedevice"\n')
    w('*ko.InputSlot Main/용지함: ""\n')
    w("*CloseUI: *InputSlot\n\n")

    # -- Media type --------------------------------------------------------
    w("*OpenUI *MediaType: PickOne\n")
    w("*OrderDependency: 10 AnySetup *MediaType\n")
    w('*ko.Translation MediaType/용지 종류: ""\n')
    w("*DefaultMediaType: Stationery\n")
    for choice, keyword, en, ko in MEDIA_TYPES:
        w(f'*MediaType {choice}/{en}: "<</MediaType({keyword})>>setpagedevice"\n')
        w(f'*ko.MediaType {choice}/{ko}: ""\n')
    w("*CloseUI: *MediaType\n\n")
    w("*%% Explicit PPD-choice -> IPP keyword mapping for the ipp backend.\n")
    for choice, keyword, _en, _ko in MEDIA_TYPES:
        w(f'*cupsMediaType {choice}/{keyword}: "{keyword}"\n')
    w("\n")

    # -- Colour model ------------------------------------------------------
    w("*OpenUI *ColorModel: PickOne\n")
    w("*OrderDependency: 10 AnySetup *ColorModel\n")
    w('*ko.Translation ColorModel/색상 모드: ""\n')
    w("*DefaultColorModel: RGB\n")
    w('*ColorModel RGB/Color: "<</cupsColorSpace 19/cupsBitsPerColor 8'
      '/cupsColorOrder 0/cupsCompression 0>>setpagedevice"\n')
    w('*ko.ColorModel RGB/컬러: ""\n')
    w('*ColorModel Gray/Grayscale: "<</cupsColorSpace 18/cupsBitsPerColor 8'
      '/cupsColorOrder 0/cupsCompression 0>>setpagedevice"\n')
    w('*ko.ColorModel Gray/흑백: ""\n')
    w("*CloseUI: *ColorModel\n\n")

    # -- Print quality -----------------------------------------------------
    # printer-resolution-supported is 600dpi only, so the IPP attribute stays at
    # 600 while pwg-raster-document-resolution-supported (600, 300) lets Draft
    # render at 300dpi for speed and ink saving.
    w("*DefaultResolution: 600dpi\n\n")
    w("*OpenUI *cupsPrintQuality/Print Quality: PickOne\n")
    w("*OrderDependency: 10 AnySetup *cupsPrintQuality\n")
    w('*ko.Translation cupsPrintQuality/인쇄 품질: ""\n')
    w("*DefaultcupsPrintQuality: Normal\n")
    w('*cupsPrintQuality Draft/Draft (300dpi, saves ink): '
      '"<</HWResolution[300 300]>>setpagedevice"\n')
    w('*ko.cupsPrintQuality Draft/초안 (300dpi, 잉크 절약): ""\n')
    w('*cupsPrintQuality Normal/Normal (600dpi): '
      '"<</HWResolution[600 600]>>setpagedevice"\n')
    w('*ko.cupsPrintQuality Normal/표준 (600dpi): ""\n')
    w('*cupsPrintQuality High/Best (600dpi): '
      '"<</HWResolution[600 600]>>setpagedevice"\n')
    w('*ko.cupsPrintQuality High/고품질 (600dpi): ""\n')
    w("*CloseUI: *cupsPrintQuality\n\n")

    # -- Constraints -------------------------------------------------------
    # Borderless is a photo-path feature; the printer cannot pull an envelope
    # or plain-paper full-bleed sheet from the same path.
    w("*%% Borderless output requires photo media.\n")
    for name, _pw, _ph, _m, _en, _ko in items:
        if name.endswith(".Borderless"):
            w(f"*UIConstraints: *PageSize {name} *MediaType Stationery\n")
            w(f"*UIConstraints: *MediaType Stationery *PageSize {name}\n")
    w("\n")

    # No *APSupplies here: it would hard-code one unit's hostname (which is
    # derived from its MAC address). *cupsIPPSupplies above already reports
    # ink levels over IPP, and works for any DCP-T420W on the network.
    w("*%% End of PPD\n")


if __name__ == "__main__":
    main()
