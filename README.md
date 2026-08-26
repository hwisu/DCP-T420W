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
| `brscan` | `/usr/local/bin/` | Scanner client |
| `brairprint` | `/usr/local/libexec/` | AirPrint Bonjour advertiser, for iOS |
| `com.hwisu.dcp-t420w.airprint.plist` | `/Library/LaunchDaemons/` | Keeps it resident — sharing option only |

The print path is

```
application/pdf → cgpdftoraster → application/vnd.cups-raster
                → rastertobrother → image/pwg-raster → ipp backend → printer
```

## Install

### The installer package

Download `DCP-T420W-<version>.pkg` from
[Releases](https://github.com/hwisu/DCP-T420W/releases) and open it. It installs
the filter, the PPD and `brscan`, then finds your printer over Bonjour and
creates a queue called `Brother_DCP_T420W`.

The installer shows one tick box, **Share the printer with iPhone, iPad and
other Macs**, off by default. See
[Printing from an iPhone or iPad](#printing-from-an-iphone-or-ipad) for what it
does and when you do not want it. Installing from the command line skips the
tick box, so there is a recipe for it in that section too.

The package is **not signed** — that needs a paid Apple Developer ID Installer
certificate. Gatekeeper will refuse a plain double-click, so either
**right-click the `.pkg` → Open**, or:

```sh
sudo installer -pkg DCP-T420W-1.2.1.pkg -target /
```

Everything inside is a universal binary (arm64 + x86_64) with no runtime
dependencies — no Python, no SANE, no background agents.

To build the package yourself:

```sh
./packaging/build-pkg.sh          # -> build/DCP-T420W-<version>.pkg
```

### From source instead

```sh
sudo ./install.sh                              # printing
sudo make -C scanner install                   # brscan -> /usr/local/bin
```

```sh
sudo ./install.sh --uri ipp://192.0.2.25:631/ipp/print   # skip discovery
sudo ./install.sh --name Office                          # queue name
sudo ./install.sh --no-queue                             # files only
sudo ./install.sh --share                                # share on the LAN
sudo ./uninstall.sh                                      # remove everything
```

Then:

```sh
lp -d Brother_DCP_T420W test/testpage-a4.pdf
```

### Removing it

```sh
sudo ./uninstall.sh
sudo rm -f /usr/local/bin/brscan
sudo pkgutil --forget com.hwisu.dcp-t420w
sudo pkgutil --forget com.hwisu.dcp-t420w.sharing
sudo cupsctl --no-share-printers    # only if you enabled sharing
```

## Printing from an iPhone or iPad

There is nothing to install on the phone, and nothing you *can* install: iOS has
no driver model at all. Its only print path is AirPrint, and this printer is
Mopria — no `urf-supported`, so no AirPrint. The phone has to print *through* a
Mac that already has this driver.

Ticking the installer's sharing box, or running `install.sh --share`, sets that
up. It takes three switches, and none of them implies the others:

| Switch | Effect |
|---|---|
| `cupsctl --share-printers` | cupsd moves from `Listen localhost:631` to `Port 631` plus `Allow @LOCAL` |
| `lpadmin -o printer-is-shared=true` | that one queue gets advertised |
| `brairprint`, as a LaunchDaemon | publishes the Bonjour record iOS is actually looking for |

The third one is not optional, and it is the part that is easy to miss. macOS
advertises a shared queue as plain `_ipp._tcp` with no `URF` key in its TXT
record; AirPrint clients browse the `_universal` subtype and ignore anything
without URF, so an iPhone reports **"No AirPrint Printers Found"** next to a
perfectly working shared printer. Declaring `*cupsUrfSupported` in the PPD does
not fix it either — the queue's own PPD copy carries the attribute and the TXT
record still comes out bare. PITFALLS.md §1.16 and §1.17 have the measurements.

So `brairprint` publishes a second record for the same queue with the subtype
and the TXT keys AirPrint wants. It proxies nothing: it registers a name, then
sleeps. Jobs land in the ordinary queue and take the ordinary path.

```
iPhone ──▶ ipp://your-mac:631/printers/Brother_DCP_T420W
             │
             ├─ application/pdf ─▶ cgpdftoraster ─┐
             │                                    ├─▶ rastertobrother ─▶ printer
             └─ image/urf ────────────────────────┘
```

Apple Raster arrives when iOS chooses URF over PDF, and needs no new code:
`cupsRasterOpen()` detects the `UNIRAST` sync word, so `rastertobrother` reads
both formats through the same calls. The PPD just has to declare the edge.

Installing from the command line has no tick box, so the choice has to be passed
in:

```sh
cat > /tmp/sharing.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
  <key>choiceIdentifier</key><string>com.hwisu.dcp-t420w.sharing</string>
  <key>choiceAttribute</key><string>selected</string>
  <key>attributeSetting</key><integer>1</integer>
</dict></array></plist>
EOF

sudo installer -pkg DCP-T420W-1.2.1.pkg \
     -applyChoiceChangesXML /tmp/sharing.plist -target /
```

To check what is actually on the air:

```sh
ippfind -T 6 _ipp._tcp.local. \
  -x echo "{service_name} URF=[{txt_URF}] rp=[{txt_rp}]" \;
```

```
Brother DCP-T420W                      URF=[] rp=[ipp/print]
Brother DCP-T420W @ your-mac           URF=[] rp=[printers/Brother_DCP_T420W]
Brother DCP-T420W (AirPrint)           URF=[CP1,IS1,PQ3-4-5,...,V1.4] rp=[printers/Brother_DCP_T420W]
```

The third line is the one the phone can see. If it is missing:
`sudo launchctl print system/com.hwisu.dcp-t420w.airprint`, and
`/var/log/brairprint.log`.

### What sharing opens up

Anyone on the same subnet can print **without a password** — that is how macOS
printer sharing works, and on a home network the worst case is wasted paper. Two
things are worth knowing:

* The setting follows the machine onto every network it joins. On a laptop that
  visits cafés or shared offices, leave it off, or stop the daemon and CUPS
  sharing when you are out.
* It is LAN only. Nothing reaches port 631 from outside unless your router
  forwards it.

Queue administration still needs authentication (`Require user @SYSTEM`), the
CUPS web interface stays off, and macOS does not ship `cups-browsed` — the
component behind the 2024 CUPS RCE chain. The Mac has to be awake.

To undo it without uninstalling the driver:

```sh
sudo launchctl bootout system/com.hwisu.dcp-t420w.airprint
sudo rm -f /Library/LaunchDaemons/com.hwisu.dcp-t420w.airprint.plist
sudo cupsctl --no-share-printers
```

### Scanning from a phone

Not possible through this route. eSCL scanning has no equivalent of AirPrint on
iOS, and `brscan` is a command-line tool for the Mac. Brother's **Mobile
Connect** app scans directly from the printer, and prints too, if you would
rather not keep a Mac awake.

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

## Why these languages

Three languages, each doing the job it is actually best at.

**The print filter is C.** This is not really a free choice. A CUPS filter is a
process `cupsd` runs with the raster on stdin, and the raster API
(`cupsRasterReadHeader2`, `cupsRasterWritePixels`) is a C library shipped with
the OS. Writing it in C means linking `libcups` directly and getting the tested
PWG encoder for free. It also has to be quick: one A4 page at 600 dpi is a
**104 MB** raster, and this filter touches every row of it.

CUPS will happily execute a filter written in anything — Brother's own Linux
drivers use shell wrappers — but per-pixel work in an interpreter is orders of
magnitude slower, and you would have to reimplement PWG Raster encoding by hand.

*Rust* is the one genuinely credible alternative: same native binary, same
speed, and memory safety while parsing raster data derived from arbitrary PDFs,
which is the part of this code where a bug would be ugliest. The cost is FFI
bindings to `libcups` (or reimplementing PWG Raster, roughly 300 lines) plus a
toolchain anyone building from source has to install. Go works too, via cgo.
For ~370 lines against a C API, C stayed the pragmatic answer — but a Rust
rewrite would be a defensible change, not a step backwards.

**The scanner client is Swift.** eSCL is just HTTP and XML, so any language can
speak it, and the first version here was Python. Swift wins on macOS for one
reason: everything it needs is already in the OS. Bonjour discovery, URLSession,
XML parsing and — the big one — ImageIO/CoreGraphics for crop, rotate,
greyscale, thresholding and PDF output. That removes both the Python dependency
*and* the `sips` subprocesses the Python version shells out to.

The difference is measurable. Same scan, same options:

| | Python + sips | Swift + CoreGraphics |
|---|---|---|
| wall clock | 24.7 s | 12.0 s |
| lineart PDF | 276 KB | 77 KB |
| dependencies | `python3`, `sips` | none |

macOS does ship `/usr/bin/python3` (3.9.6, and `brscan.py` still runs on it),
but on a machine without Command Line Tools it is a stub that prompts to install
them — not something an installer should rely on.

`scanner/brscan.py` is kept because eSCL is not macOS-specific: it is the
portable version, useful on Linux or anywhere without a Swift toolchain.

**Everything else is Python or shell, and never ships.** `scripts/genppd.py`
generates the PPD, `test/pwgdump.py` and `test/pwg2png.py` decode PWG Raster for
verification, `install.sh` and `packaging/build-pkg.sh` build and install. These
are development tools that run on your machine, not runtime dependencies of the
driver.

## Scanning

`brscan` is a standalone eSCL (AirScan / Mopria Scan) client. The installer
package puts it in `/usr/local/bin`; from source it is:

```sh
make -C scanner && sudo make -C scanner install
```

It is a native universal binary with no runtime dependencies. A portable Python
implementation of the same tool lives at `scanner/brscan.py` for non-macOS use.

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
filter/rastertobrother.c   the print filter (C, links libcups)
filter/Makefile            builds a universal (arm64 + x86_64) binary
ppd/Brother-DCP-T420W.ppd  generated — edit the generator, not this
scanner/brscan.swift       eSCL scan client, native and dependency-free
scanner/brscan.py          the same tool in Python, for non-macOS use
scanner/Makefile           builds brscan universal
airprint/brairprint.c      publishes the queue as AirPrint, for iOS clients
airprint/Makefile          builds brairprint universal
packaging/build-pkg.sh     builds the double-clickable installer
packaging/scripts/         pkg pre/postinstall (creates the print queue)
packaging/scripts-sharing/ postinstall for the optional sharing component
packaging/launchd/         the brairprint LaunchDaemon plist
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
