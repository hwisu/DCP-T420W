# Pitfalls: driving a Brother DCP-T420W from macOS

Notes gathered while building this driver. Everything marked **Verified** was
observed directly on a DCP-T420W (firmware reporting eSCL 2.63, IPP 2.0) from
macOS 26.5 on Apple Silicon. A few items are marked **Inferred** where the
reasoning is sound but the test had confounds.

---

## Part 1 — Printing

### 1.1 "Mopria certified" does not mean AirPrint

**Verified.** The printer answers Bonjour, appears in Add Printer, and macOS
still has no driver for it. The reason is one missing attribute:

```
mopria-certified            = 2.0
pwg-raster-document-type-supported = sgray_8, srgb_8
urf-supported               = (absent)
```

macOS looks for `urf-supported` before it will treat a printer as AirPrint.
Mopria requires PWG Raster; AirPrint requires URF. They are different formats
and this printer speaks only the first. Check any printer with:

```sh
ipptool -tv ipp://HOST:631/ipp/print get-printer-attributes.test | grep -i urf
```

No output means no AirPrint, whatever the box says.

### 1.2 `*cupsFilter2` lines are edges into the queue, not a pipeline

**Verified — this one cost real time.** It is tempting to read

```
*cupsFilter2: "application/pdf application/vnd.cups-raster 40 cgpdftoraster"
*cupsFilter2: "application/vnd.cups-raster image/pwg-raster 20 rastertobrother"
```

as "run these two in order". CUPS does not. Each line becomes a filter edge
from the **source** type into `printer/<queue>`; the destination type in the
line only records the format the backend will send. So the first line above
makes `cgpdftoraster` a valid *final* filter, CUPS takes it as the cheaper
one-step route, and the custom filter never runs.

Declare exactly one `*cupsFilter2`, from the type your filter consumes:

```
*cupsFilter2: "application/vnd.cups-raster image/pwg-raster 20 rastertobrother"
```

Now the only edge into the queue is through your filter, and CUPS is forced to
find something that produces `application/vnd.cups-raster` to feed it.

To see which filters actually ran:

```sh
cupsctl --debug-logging
lp -d QUEUE file.pdf
grep -E "started|argv" /var/log/cups/error_log | tail -20
cupsctl --no-debug-logging
```

### 1.3 `cgpdftoraster` ignores `*ImageableArea`, and `rastertopwg` then refuses the job

**Verified.** macOS renders the **full page**, not the printable area:

```
DEBUG: cupsPageSize=[595.276 841.89], cupsImagingBBox=[0 0 595.276 841.89]
DEBUG: cgpdftoraster: top=0, bottom=0, left=0, right=0
DEBUG: cupsWidth=4961, cupsHeight=7016          <- 210 x 297 mm at 600 dpi
```

The stock `rastertopwg` computes expected margins from the PPD, sees a raster
that is bigger than the imageable area, and aborts:

```
ERROR: Unsupported raster data.
DEBUG: Bad bottom/left/top margin on page 1.
```

So a PPD with honest non-zero margins plus `rastertopwg` is a broken
combination on macOS. Either declare zero margins, or write a filter that
derives geometry from the incoming raster instead of from the PPD.

Note this does **not** happen on the default path, because `cgpdftoraster` can
emit `image/pwg-raster` in one step and `rastertopwg` is never invoked. It bites
as soon as you insert your own raster filter.

### 1.4 The one-step path writes PPD names where PWG Raster wants IPP keywords

**Verified** by decoding both streams' page headers:

| Field | `cgpdftoraster` direct | what the printer publishes |
|---|---|---|
| `cupsPageSizeName` | `A4.Borderless` | `iso_a4_210x297mm` |
| `MediaType` | `Stationery` | `stationery` |
| `ImagingBoundingBox` | `[0 0 595 841]` | PWG says leave it `[0 0 0 0]` |

Two things to notice. The strings are PPD choice names, not the self-describing
PWG names from `media-supported`. And plain A4 gets announced as
**`A4.Borderless`** — telling an inkjet that a plain-paper page is full bleed is
not a good default.

Decode any PWG stream and check for yourself with `test/pwgdump.py`.

### 1.5 You cannot set the PWG `cupsInteger[]` fields through libcups

**Verified.** PWG Raster carries `ImageBoxLeft/Top/Right/Bottom`, `PrintQuality`
and the feed transforms in `cupsInteger[]`. Setting them before
`cupsRasterWriteHeader2()` in `CUPS_RASTER_WRITE_PWG` mode does nothing —
the writer normalises the array itself, keeping only `TotalPageCount`,
`CrossFeedTransform`, `FeedTransform` and `AlternatePrimary`:

```
requested: [1,1,1,0,0,4961,7016,16777215,4,...]
on the wire:[1,1,1,0,0,   0,   0,16777215,0,...]
```

The same applies to `cupsPageSize`, `cupsImagingBBox` and
`cupsBorderlessScalingFactor` — all zeroed. Do not write code that appears to
configure them. Send print quality as the IPP `print-quality` attribute
instead; the printer lists it in `print-quality-supported`.

### 1.6 PPD choice names round-trip through `pwg_unppdize_name()`

**Verified.** CUPS converts a PPD `*MediaType` choice to an IPP keyword by
lowercasing and hyphenating before uppercase letters. So

```
Com.brotherBp71    -> com.brother-bp71
PhotographicGlossy -> photographic-glossy
StationeryInkjet   -> stationery-inkjet
```

These *are* the printer's keywords, so the odd-looking choice names are
correct and should not be "tidied up". Renaming `Com.brotherBp71` to something
prettier silently breaks the media-type mapping.

### 1.7 Resolution: two different attributes, two different answers

**Verified.**

```
printer-resolution-supported             = 600dpi
pwg-raster-document-resolution-supported = 600dpi, 300dpi
```

The raster may be 300 dpi, but the IPP `printer-resolution` attribute must
stay at 600 — 300 is not in its supported list. Drive draft mode by rendering
the raster at 300 dpi (via `*cupsPrintQuality` setting `HWResolution`) and leave
`*DefaultResolution: 600dpi` alone. Do not expose a `*Resolution` UI option.

### 1.8 Margins are not uniform

**Verified.** The printer reports margin sets, not a single margin:

```
media-top-margin-supported    = 300, 0, 1200, 1200
media-bottom-margin-supported = 300, 0, 1200, 1200
media-left-margin-supported   = 300, 0,  300,  300
media-right-margin-supported  = 300, 0,  300,  300
```

In hundredths of a millimetre: 3 mm all round for cut sheet, **12 mm top and
bottom for envelopes**, 0 for borderless. A PPD with one global `*HWMargins` is
wrong for envelopes. The auto-generated IPP Everywhere PPD applies the envelope
value globally.

### 1.9 Borderless belongs to the photo path

Full bleed means spraying past the paper edge. On plain paper that is ink on the
platen, which later transfers to the back of subsequent sheets. This driver adds
`*UIConstraints` between every `.Borderless` size and plain `Stationery`.
**Inferred** — general inkjet behaviour, not something worth testing
deliberately.

### 1.10 `.Borderless` vs `.Fullbleed`

`cupstestppd` warns that the Adobe-standard suffix is `.Fullbleed`. Ignore it:
CUPS's own IPP Everywhere generator emits `.Borderless`, and CUPS's PPD cache
understands that spelling. Matching Adobe here would break the CUPS mapping.

### 1.11 Copies

`document-format-varying-attributes = copies` is the printer warning you that
copy support depends on the document format. Safest is `*cupsManualCopies: True`
so CUPS sends the page N times rather than trusting the firmware.

### 1.12 Installing the filter

`/usr/libexec/cups/filter` is root-owned but carries **no SIP `restricted`
flag**, so root can write there (`ls -lO` shows the flags). This is the standard
location every vendor driver uses. Two things still bite:

* You need `sudo`; being in `_lpadmin` is enough for `lpadmin` but not for
  installing the binary.
* Build **universal** (`-arch arm64 -arch x86_64`). The filter runs as a child
  of `cupsd`, and a single-architecture binary fails on the other Mac.

`cupstestppd` reports the missing filter as a hard FAIL until it is installed —
that particular failure is expected before `install.sh` runs.

### 1.13 Device URI: prefer `dnssd:`

`ipp://192.168.1.50:631/ipp/print` breaks the next time DHCP moves the printer.
`lpinfo -v` gives a Bonjour URI that survives address changes:

```
dnssd://Brother%20DCP-T420W._ipp._tcp.local./?uuid=...
```

### 1.14 Ink levels

Set `*cupsIPPSupplies: True` and `*cupsSNMPSupplies: False`. The printer reports
`marker-levels` over IPP; SNMP polling is redundant and slow. Do **not** put a
hard-coded `*APSupplies` URL in a shareable PPD — the hostname
(`BRW<MAC>.local`) is specific to one unit.

### 1.15 Test without burning paper

The whole chain can be exercised offline:

```sh
PPD=ppd/Brother-DCP-T420W.ppd /usr/libexec/cups/filter/cgpdftoraster \
    1 me test 1 "" test/testpage-a4.pdf > /tmp/page.cups
PPD=ppd/Brother-DCP-T420W.ppd ./filter/rastertobrother \
    1 me test 1 "" < /tmp/page.cups > /tmp/page.pwg
python3 test/pwgdump.py /tmp/page.pwg              # header fields
python3 test/pwg2png.py /tmp/page.pwg /tmp/x.png   # decode back to an image
```

Decoding the output back to PNG catches inverted colours, wrong stride, off-by-one
widths and truncated rows before any ink is used.

---

## Part 2 — Scanning

### 2.1 The DCP-T420W ignores every eSCL scan setting

**Verified, and the single most important thing on this page.** The scanner
accepts a `POST /eSCL/ScanJobs`, returns `201 Created` with a job Location, and
then disregards the request body completely. Proof:

```
POST body: "this is not xml at all"      -> HTTP 201, Location: yes
POST body: <nonsense><a>1</a></nonsense> -> HTTP 201, Location: yes
POST body: (empty)                       -> connection reset
```

It never validates, so it never honours. Consequences, all **verified**:

| Requested | Received |
|---|---|
| `Grayscale8` | 3-channel colour JPEG |
| `application/pdf` | JPEG, with `Content-Type: image/jpeg` |
| `XResolution` 100 / 300 | same fixed size every time |
| `ScanRegion` A6, with `MustHonor="true"` | full platen |

Element order, `pwg:MustHonor`, `Version` 2.0 vs 2.63, `Content-Type: text/xml`
vs `text/xml; charset=utf-8` — none of it changes anything. Do not spend an
evening permuting the XML the way this project did.

**What to do instead:** take what the device gives you and convert locally.
`sips` (built into macOS) handles crop, rotate, resample and format; greyscale
and thresholding are a few lines of pixel work. That is what `brscan` does.

Before assuming a sibling model behaves the same, test it in one shot:

```sh
curl -s -X POST -H 'Content-Type: text/xml' -d 'garbage' \
     -D- -o /dev/null http://HOST/eSCL/ScanJobs
```

A `201` means the firmware is not reading the body.

### 2.2 The advertised capabilities are aspirational

**Verified.** `ScannerCapabilities` claims 100/200/300/600 dpi, three colour
modes, PDF and JPEG, four intents, and 1200 x 2400 optical. In practice exactly
one combination is reachable. Treat the capability document as a description of
the hardware, not of the API.

### 2.3 Fixed frame, non-square pixels

**Verified:** every scan returns **1680 x 2195** pixels, JPEG, three channels,
with an embedded density of 200 dpi.

**Inferred:** that frame covers the full declared platen
(`MaxWidth` 2550, `MaxHeight` 3507 = 215.9 x 296.9 mm), which works out at about
198 dpi across and 188 dpi down — the pixels are **not square**, and the
embedded 200 dpi tag is nominal. Measuring a printed target gave 195 x 183 dpi,
consistent within the error introduced by the printer's own margins clipping the
target's outline. If you need true physical dimensions, scan a ruler.

Practical effect: a millimetre-accurate crop needs a per-axis scale, not one
dpi number. `brscan --crop` derives both axes from `MaxWidth`/`MaxHeight`.

### 2.4 Flatbed only

`is=platen`, `duplex=F`, and no `<scan:Adf>` element. There is no document
feeder, so no multi-page scanning, no duplex, and `NextDocument` always yields
exactly one image.

### 2.5 `NextDocument` returning 404 is normal

End-of-pages is signalled by `404`/`410` on
`GET <job>/NextDocument`. Treat it as the loop terminator, not an error — but
only *after* at least one page, otherwise a genuine failure looks like an empty
scan.

### 2.6 The `Location` header may not be reachable

**Verified** on this firmware the host in `Location` is fine, but it is common
for eSCL devices to return an internal address. Rewrite the scheme+host with
the one you connected to and keep only the path.

### 2.7 Cancelled jobs linger

`DELETE <job>` is best-effort; some firmwares reject it. Abandoned jobs stay
visible in `ScannerStatus` for a while:

```xml
<pwg:JobState>Canceled</pwg:JobState>
<pwg:JobStateReason>JobCanceledAtDevice</pwg:JobStateReason>
```

Harmless, but do not treat a non-`Idle` state as a reason to refuse to scan.

### 2.8 An empty POST body resets the connection

**Verified.** Not a clean `400` — the TCP connection drops
(`[Errno 54] Connection reset by peer`). Always send a body, even one the device
will ignore.

### 2.9 Orientation

The glass origin is one specific corner, and a page laid in the "natural"
reading direction often comes back rotated 180°. This is placement, not a bug.
`brscan --rotate 180` fixes it without re-scanning.

### 2.10 Scanning does not need the print driver

eSCL is plain HTTP on port 80 and is completely independent of CUPS. `brscan`
works whether or not the print queue exists, and needs no root.

---

## Part 3 — Diagnosing anything else

```sh
# Everything the printer claims about printing
scripts/probe.sh

# Everything it claims about scanning
curl -s http://HOST/eSCL/ScannerCapabilities | xmllint --format -
curl -s http://HOST/eSCL/ScannerStatus       | xmllint --format -

# Watch the print pipeline
cupsctl --debug-logging && tail -f /var/log/cups/error_log

# What CUPS thinks the queue can do
lpoptions -p QUEUE -l

# Validate a PPD
cupstestppd ppd/Brother-DCP-T420W.ppd
```

One closing note: firmware updates can change any of this, in either direction.
The `curl -d garbage` check in §2.1 takes two seconds and tells you immediately
whether a newer firmware has started reading scan settings.
