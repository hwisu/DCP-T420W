# Brother DCP-T420W — macOS printer and scanner driver

Printing and scanning for the Brother DCP-T420W on modern macOS (built and
tested on macOS 26.5, Apple Silicon). The print side is a real CUPS driver —
filter plus PPD — giving the printer a proper queue with full paper, quality
and colour options. The scan side is a dependency-free eSCL client.

Nothing here needs Brother's software, SANE, or an ICA plugin.

**If you are here because something is behaving strangely, read
[PITFALLS.md](PITFALLS.md) first** — it documents the firmware quirks this
driver works around, including the big one: *the scanner ignores every scan
setting you send it*.

## Why this exists

The DCP-T420W is **Mopria 2.0 certified but not an AirPrint device**. Its IPP
attributes advertise

```
document-format-supported = application/octet-stream, image/pwg-raster,
                            application/vnd.brother-hbp
pwg-raster-document-type-supported = sgray_8, srgb_8
```

but there is **no `urf-supported` attribute**, and URF is what macOS looks for
before it will drive a printer as AirPrint. So the printer answers Bonjour,
shows up in the Add Printer dialog, and then macOS has no model to attach to
it. The printer's own language, HBP (`usb_CMD=HBP,PJL`), is undocumented.

The way through is the format the printer already supports and that is fully
specified: **PWG Raster** (PWG 5102.4), over IPP.

## What it installs

| Component | Path | Role |
|---|---|---|
| `rastertobrother` | `/usr/libexec/cups/filter/` | CUPS raster → PWG Raster |
| `Brother DCP-T420W.ppd` | `/Library/Printers/PPDs/Contents/Resources/` | Option model |

The print path is

```
application/pdf → cgpdftoraster → application/vnd.cups-raster
                → rastertobrother → image/pwg-raster → ipp backend → printer
```

## Install

```sh
sudo ./install.sh
```

It builds the filter if needed, installs both files, finds the printer over
Bonjour and creates a queue called `Brother_DCP_T420W`. Options:

```sh
sudo ./install.sh --uri ipp://192.0.2.25:631/ipp/print   # skip discovery
sudo ./install.sh --name Office                          # queue name
sudo ./install.sh --no-queue                             # files only
sudo ./uninstall.sh                                      # remove everything
```

Then:

```sh
lp -d Brother_DCP_T420W test/testpage-a4.pdf
```

## Supported options

* **Paper** — A4, Letter, Legal, Executive, A5, A6, Folio, Oficio, India Legal,
  4×6, 3.5×5 (L), 5×7, 5×8, #10, DL, C5 and Monarch envelopes, plus custom
  sizes from 88.9×127 mm to 215.9×355.6 mm.
* **Borderless** — A4, Letter, A6 and the four photo sizes carry `.Borderless`
  variants with zero margins. Constrained against plain paper, since full bleed
  is a photo-path feature.
* **Media type** — Plain, Inkjet, Glossy Photo, Brother BP71.
* **Quality** — Draft (300 dpi, saves ink), Normal and Best (600 dpi).
* **Colour** — Colour (`srgb_8`) or Grayscale (`sgray_8`).
* **Ink levels** — reported through IPP (`*cupsIPPSupplies`).

Margins come from the printer: 3 mm on cut sheet, 12 mm top and bottom on
envelopes, 0 for borderless.

## Why a custom filter, when `cgpdftoraster` can emit PWG Raster directly

It can, and CUPS would prefer that one-step route on cost. But its output
labels the page with **PPD names where PWG Raster calls for IPP keywords**:

| Field | `cgpdftoraster` direct | `rastertobrother` |
|---|---|---|
| `cupsPageSizeName` | `A4.Borderless` | `iso_a4_210x297mm` |
| `MediaType` | `Stationery` | `stationery` |
| `ImagingBoundingBox` | `[0 0 595 841]` | `[0 0 0 0]` (per spec) |

`iso_a4_210x297mm` and `stationery` are exactly the strings this printer
publishes in `media-supported` and `media-type-supported`. The direct path also
announces plain A4 as `A4.Borderless`, which is the wrong thing to tell an
inkjet about a plain-paper page.

The PPD declares exactly one `*cupsFilter2`, from
`application/vnd.cups-raster`. That is what forces the route: CUPS turns each
`*cupsFilter2` into an edge into `printer/<queue>`, so the only way to reach
the queue is through `rastertobrother`, with `cgpdftoraster` feeding it.
(Declaring a second line for the `cgpdftoraster` stage backfires — it makes
`cgpdftoraster` itself a valid final filter and the custom one is skipped.)

The filter also pads the rendered band out to full bleed if it ever arrives
inset, converts sRGB to grey when a colour raster reaches a monochrome job, and
maps PPD media choices to IPP keywords.

## Scanning

`scanner/brscan` is a standalone eSCL (AirScan / Mopria Scan) client. It needs
no installation and no root — copy it somewhere on your `PATH` if you like:

```sh
sudo install -m 0755 scanner/brscan /usr/local/bin/brscan
```

```sh
brscan                                   # full platen, colour, PDF
brscan --mode gray --out receipt.pdf
brscan --mode lineart --rotate 180 --out doc.pdf
brscan --crop a6 --out photo.jpg         # crop from the top-left of the glass
brscan --raw --out exactly-what-it-sent.jpg
brscan --caps                            # what the scanner claims
brscan --list                            # find scanners on the network
```

### The firmware ignores scan settings

This is worth stating plainly, because it shapes the whole tool. The
DCP-T420W accepts a scan job and then **disregards the request body**. It
returns `201 Created` even for a body of `this is not xml at all`, and always
scans the same way: full platen, colour, JPEG, fixed size. Ask for
`Grayscale8` and you get three-channel colour; ask for `application/pdf` and
you get JPEG.

So `brscan` sends a correct, well-formed request anyway — harmless, and
sibling models may honour it — and then applies whatever the device ignored
locally using `sips`, which ships with macOS. `--raw` skips all of that and
saves the scanner's bytes untouched.

| Option | Where it happens |
|---|---|
| `--mode gray` / `--mode lineart` | locally |
| `--crop`, `--rotate` | locally |
| `--format pdf/jpeg/png` | locally |
| `--dpi`, `--intent` | requested, then ignored by the device |

Scans come back 1680 × 2195 px covering the whole platen. The pixels are not
square — roughly 198 dpi across and 188 dpi down — so `--crop` scales each
axis separately. See [PITFALLS.md §2.3](PITFALLS.md).

There is no document feeder: flatbed only, one page per scan, no duplex.

## Layout

```
filter/rastertobrother.c   the print filter
filter/Makefile            builds a universal (arm64 + x86_64) binary
ppd/Brother-DCP-T420W.ppd  generated — edit the generator, not this
scanner/brscan             eSCL scan client (no install, no dependencies)
scripts/genppd.py          builds the PPD from the printer's own attributes
scripts/probe.sh           dumps a printer's IPP capabilities
test/make_testpage.py      generates the A4 test page
test/pwgdump.py            decodes PWG Raster page headers
test/pwg2png.py            decodes a PWG stream back to PNG
install.sh, uninstall.sh
PITFALLS.md                everything that bites, printing and scanning
```

## Verification

The driver was checked without printing, by decoding its own output:

```sh
python3 test/make_testpage.py > test/testpage-a4.pdf
PPD=ppd/Brother-DCP-T420W.ppd /usr/libexec/cups/filter/cgpdftoraster \
    1 me test 1 "" test/testpage-a4.pdf > /tmp/page.cups
PPD=ppd/Brother-DCP-T420W.ppd ./filter/rastertobrother \
    1 me test 1 "" < /tmp/page.cups > /tmp/page.pwg
python3 test/pwgdump.py /tmp/page.pwg          # header fields
python3 test/pwg2png.py /tmp/page.pwg /tmp/page.png --scale 7
```

Confirmed: A4 at 600 dpi decodes to 4961×7016 `srgb_8` with every row
well-formed; `ColorModel=Gray` and `cupsPrintQuality=Draft` produce 2480×3508
`sgray_8`; colour input forced to mono converts with correct Rec. 601 luma.
The resulting stream was then sent to the printer over IPP and came back
`job-completed-successfully`, and the printed sheet was scanned back in to
confirm colour, greys, fine lines and text all survived the round trip.

On the scan side, `--mode lineart --rotate 180`, `--mode gray --crop a6` and
`--raw` were each run against the hardware and the output checked by decoding
it back to an image.

## Adapting to a sibling model

Run `scripts/probe.sh` against the other printer, update the `MEDIA` table and
margin constants in `scripts/genppd.py` to match what it reports, regenerate,
and reinstall. Any Brother that lists `image/pwg-raster` in
`document-format-supported` should work the same way.
