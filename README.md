# Brother DCP-T420W for Mac

[한국어](README.KO.md) · [Technical guide](TECHY_README.md) · [Download](https://github.com/hwisu/DCP-T420W/releases)

Print from Preview, Safari and other Mac apps using your **Brother DCP-T420W**.
This community driver adds it to the normal macOS print menu. It also includes
`brscan`, a small command-line scanning tool. It is not an official Brother product.

## 1. Install

1. Turn on the printer and connect the Mac to the same network.
2. Download the `.pkg` installer from [Releases](https://github.com/hwisu/DCP-T420W/releases).
3. Open it and follow the installer. Leave **Share the printer with iPhone and
   iPad** unchecked unless you need it; read the security notes below first.
4. Open a document, press **⌘P**, and select **Brother DCP-T420W**.

If the printer was not found during installation, add it in **System Settings →
Printers & Scanners**, using **Brother DCP-T420W (PWG Raster)** as the driver.

**Security notes — please read before installing**

- The installer is **unsigned**. macOS may block it because it cannot verify the
  developer. Download only from this repository's releases and proceed only if
  you trust this project. Do not disable Gatekeeper globally. See the
  [installation details](TECHY_README.md#the-installer-package) if it is blocked.
- Printer sharing is **off by default**. Enabling it lets anyone on the same local
  network print **without a password**. Use it only on a trusted network.
- Sharing stays enabled when a laptop joins a different network. Turn it off
  before using public or shared Wi-Fi. Do not expose printer sharing to the
  internet with router port forwarding.
- An upgrade can preserve sharing that you previously enabled. See the
  [sharing controls](TECHY_README.md#what-sharing-opens-up) to turn it off.

## 2. Print

**Since 1.5.0, colour is on the main print screen, and paper and quality are in
Media & Quality.** There is no need to open Printer Options → Printer Features.

| Option | Where to find it |
|---|---|
| Colour / grayscale | **Print in Color** switch on the main screen |
| Quality with resolution | Top-level **Presets**: Eco **300 dpi**, Standard **600 dpi**, High Quality **600 dpi** |
| Paper type, paper source, quality individually | Expand **Media & Quality** to see all three controls |
| Paper size, borderless sizes, orientation, copies, page range | Main print screen |
| Pages per sheet, border, mirror | **Layout** |
| Odd/even pages, collation, sheet order, scaling | **Paper Handling** |
| Watermark | **Watermark** |

Eight built-in presets appear immediately: **Color/Grayscale Document ×
Eco/Standard/High Quality**, plus **Glossy Photo / Brother BP71 Photo — High Quality
(600 dpi)**. Document presets select plain paper; photo presets select their
named photo paper. For everyday documents choose **A4 + Color Document — Standard
(600 dpi)**. Check size, page range, copies, orientation and sheet order separately.

**DPI describes the output raster resolution.** Standard and High Quality both
use 600 dpi but send different quality modes to the printer. The native macOS
quality control uses its own Draft/Normal/Best labels; DPI is shown in the preset
names. Those three labels correspond to Eco 300 dpi, Standard 600 dpi and High
Quality 600 dpi.

macOS controls the layout and collapsed sections; a driver cannot force all
sections to stay expanded. Expand the sections you need to adjust their controls
inline. Available controls and whether expansion is remembered depend on the app
and macOS version.

Automatic sheet order prints the **last page first** (since 1.4.0). Choose
**Normal** for page 1 first. Existing presets can override page order. This
printer has no automatic two-sided printing; borderless printing needs photo paper.

## 3. Scan

**Want to use a built-in Mac app?** Brother documents scanning with **Image
Capture** after installing its separate **Scanner Driver (ICA)**. Choose your
macOS version on [Brother's downloads page](https://support.brother.com/g/b/downloadtop.aspx?c=eu_ot&lang=en&prod=dcpt420w_all)
and check for an ICA driver. Then open **Image Capture**, select the Brother
scanner, click **Show Details**, choose PDF or an image format, and scan.

This installer does **not** include that ICA driver. Successful printing with
this project does not by itself make the scanner appear in Image Capture.
See [Brother's Image Capture instructions](https://support.brother.com/g/s/id/htmldoc/mfc/cv_dcp220/mexlte/html/GUID-6A4819EC-1724-4DEE-ABA5-BC35B08593A0_70.html).

If you prefer the included Terminal tool:

```sh
brscan --out ~/Desktop/scan.pdf
```

Place one page on the glass. This model has no document feeder. The current
`brscan` workaround applies colour, crop and rotation on the Mac; requesting a
higher DPI does not improve the device's actual scan resolution.

## iPhone and iPad

Enable the installer's optional sharing only on a trusted network. Keep the Mac
awake, then choose **Brother DCP-T420W (AirPrint)** on the phone. The Mac handles
the print job. Phone scanning is not included in this project.

## Compatibility

Packages include Apple Silicon and Intel binaries and target macOS 11 or later;
not every OS version has been tested. Development was originally tested on
macOS 26.5, Apple Silicon.

Users reported **v1.3.4 works fine** on:

- **Golden Gate 27.0.1 (26A434)**
- **Tahoe 26.7.1 (25G241)**

These reports concern v1.3.4, not v1.5.0 or Brother's separate ICA driver.

## If something does not work

- **Printer missing:** check power and the network, then add the printer as above.
- **Old options after an upgrade:** quit and reopen the app you print from.
- **Wrong page order:** check Sheet Order and any saved preset.
- **Scanner missing in Image Capture:** check the ICA driver and network connection;
  installing this print driver alone is not enough.
- **Need help:** [open an issue](https://github.com/hwisu/DCP-T420W/issues) with your
  macOS version, driver version and the error. Remove private document contents,
  network addresses and other personal information from attachments.

For build instructions, removal, release changes, diagnostics and known device
limitations, read [TECHY_README.md](TECHY_README.md).
