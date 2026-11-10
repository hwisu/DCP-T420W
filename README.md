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

For everyday documents, use **A4**, **Plain Paper** and **Standard Document** quality.

| What you want | Where to find it in the print dialog |
|---|---|
| Colour or grayscale; quality; paper type | **Printer Options → Printer Features** |
| Only odd or even pages | **Paper Handling → Sheets to Print** |
| First page first | **Paper Handling → Sheet Order → Normal** |
| Last page first | **Paper Handling → Sheet Order → Reverse** |

**Changed in 1.4.0:** automatic page order now prints the **last page first**.
After upgrading, choose **Normal** if you want the previous order. Saved presets
with an explicit page order can override this default.

To avoid opening Printer Features every time, save these combinations using
**Presets → Save Current Settings as Preset** and select this Brother printer:

| Suggested preset | Colour | Quality | Paper |
|---|---|---|---|
| Colour document · A4 | Colour | Standard Document | A4, plain |
| Grayscale document · A4 | Grayscale | Standard Document | A4, plain |
| Save ink · grayscale A4 | Grayscale | Eco | A4, plain |

These are presets you save yourself, not shortcuts automatically added by the
installer. Check page order, scaling and copies before saving. The printer has
no automatic two-sided printing; borderless printing requires photo paper.

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

These reports concern v1.3.4, not v1.4.0 or Brother's separate ICA driver.

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
