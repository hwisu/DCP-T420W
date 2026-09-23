/*
 * rastertobrother — CUPS raster to PWG Raster filter for the Brother DCP-T420W.
 *
 * The DCP-T420W is Mopria 2.0 certified and accepts image/pwg-raster over IPP,
 * but it does NOT advertise urf-supported, so macOS will not drive it as an
 * AirPrint device. This filter completes the chain:
 *
 *     application/pdf -> cgpdftoraster -> application/vnd.cups-raster
 *                     -> rastertobrother -> image/pwg-raster -> ipp backend
 *
 * The substantive work here is geometry. CoreGraphics renders into the PPD's
 * *ImageableArea, so the incoming raster covers only the printable region. PWG
 * Raster is defined edge-to-edge: the page image must span the full media size,
 * with the hardware margins present as white. We therefore pad each page back
 * out to full bleed before handing it to the printer.
 *
 * Usage (CUPS filter interface):
 *     rastertobrother job user title copies options [filename]
 *
 * Copyright: written for personal use with a Brother DCP-T420W.
 */

#include <cups/cups.h>
#include <cups/ppd.h>
#include <cups/raster.h>
#include <cups/pwg.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <math.h>

/*
 * Cancellation flag, set from SIGTERM by the scheduler.
 */
static volatile sig_atomic_t job_canceled = 0;

static void
cancel_job(int sig)
{
  (void)sig;
  job_canceled = 1;
}

/*
 * Job-wide settings, resolved once from the PPD and the job options.
 */
typedef struct
{
  const char	*media_type;		/* IPP media-type keyword */
  unsigned	quality;		/* IPP print-quality, 3/4/5 */
  int		want_gray;		/* Job asked for monochrome output */
} job_options_t;

/*
 * Where the rendered band sits on the full-bleed sheet.
 */
typedef struct
{
  unsigned	xdpi, ydpi;		/* Device resolution */
  unsigned	full_width, full_height;/* Full-bleed page in pixels */
  unsigned	left_px, top_px;	/* Offset of the imageable area */
  unsigned	in_bpp;			/* Bytes per input pixel */
  float		page_w, page_h;		/* Media size in points */
  double	media_w, media_h;	/* Media size in hundredths of mm */
} page_layout_t;

/*
 * Map a PPD *MediaType choice onto the exact IPP keyword the DCP-T420W
 * publishes in media-type-supported. CUPS derives the same keywords from the
 * choice names via pwg_unppdize_name(), but we state them explicitly so the
 * raster header's MediaType field matches the IPP attribute the backend sends.
 */
static const char *
media_type_keyword(const char *choice)
{
  if (!choice || !*choice)
    return ("stationery");

  if (!strcasecmp(choice, "StationeryInkjet"))
    return ("stationery-inkjet");
  if (!strcasecmp(choice, "PhotographicGlossy"))
    return ("photographic-glossy");
  if (!strcasecmp(choice, "Com.brotherBp71"))
    return ("com.brother-bp71");

  return ("stationery");
}

/*
 * Resolve the job options against the queue's PPD.
 *
 * The PPD API has been deprecated since macOS 10.8, but it is still the only
 * way a filter can see the marked choices -- the suggested cupsCopyDestInfo()
 * talks to a destination, not to the PPD the scheduler hands us. Keep every
 * PPD call in this one function so the deprecation warning is silenced here
 * and nowhere else.
 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static const char *
load_job_options(const char *option_string, job_options_t *job)
{
  cups_option_t	*options = NULL;
  int		num_options;
  ppd_file_t	*ppd;
  ppd_choice_t	*choice;
  const char	*error = NULL;

  job->media_type = "stationery";
  job->quality    = 4;			/* IPP print-quality: 4 = normal */
  job->want_gray  = 0;

  num_options = cupsParseOptions(option_string, 0, &options);

  if ((ppd = ppdOpenFile(getenv("PPD"))) == NULL)
  {
    fputs("DEBUG: No PPD available, relying on raster header values.\n", stderr);
    cupsFreeOptions(num_options, options);
    return (NULL);
  }

  ppdMarkDefaults(ppd);
  cupsMarkOptions(ppd, num_options, options);

  if (ppdConflicts(ppd))
    error = "Conflicting print options (check paper size and media type).";

  if ((choice = ppdFindMarkedChoice(ppd, "MediaType")) != NULL)
    job->media_type = media_type_keyword(choice->choice);

  if ((choice = ppdFindMarkedChoice(ppd, "ColorModel")) != NULL)
    job->want_gray = !strcasecmp(choice->choice, "Gray");

  if ((choice = ppdFindMarkedChoice(ppd, "cupsPrintQuality")) != NULL)
  {
    if (!strcasecmp(choice->choice, "Draft"))
      job->quality = 3;
    else if (!strcasecmp(choice->choice, "High"))
      job->quality = 5;
  }

  ppdClose(ppd);
  cupsFreeOptions(num_options, options);
  return (error);
}

#pragma clang diagnostic pop

/*
 * Round a length in PostScript points to whole device pixels.
 */
static int
points_to_pixels(double points, unsigned dpi, unsigned *pixels)
{
  double px = points * (double)dpi / 72.0;

  if (!isfinite(px) || px > (double)UINT_MAX - 0.5)
    return (0);

  if (px < 0.0)
    px = 0.0;

  *pixels = (unsigned)(px + 0.5);
  return (1);
}

/*
 * Validate an incoming page header and work out where its band sits on the
 * full sheet. Returns NULL on success or an error message.
 */
static const char *
layout_page(const cups_page_header2_t *header, page_layout_t *layout)
{
 /*
  * This filter and the printer support only byte-interleaved sgray_8 and
  * srgb_8. Reject packed, planar and unrelated color spaces before using
  * their geometry to size or index a line buffer.
  */
  if (header->cupsWidth == 0 || header->cupsHeight == 0 ||
      header->cupsBitsPerColor != 8 ||
      header->cupsColorOrder != CUPS_ORDER_CHUNKED ||
      !((header->cupsColorSpace == CUPS_CSPACE_SW &&
         header->cupsBitsPerPixel == 8) ||
        (header->cupsColorSpace == CUPS_CSPACE_SRGB &&
         header->cupsBitsPerPixel == 24)))
    return ("Unsupported raster pixel format.");

  layout->in_bpp = header->cupsBitsPerPixel / 8;

  if (header->cupsWidth > UINT_MAX / layout->in_bpp ||
      header->cupsBytesPerLine < header->cupsWidth * layout->in_bpp)
    return ("Invalid raster line geometry.");

  layout->xdpi = header->HWResolution[0];
  layout->ydpi = header->HWResolution[1];

 /* Match pwg-raster-document-resolution-supported, not the UI alone. */
  if ((layout->xdpi != 300 && layout->xdpi != 600) ||
      layout->ydpi != layout->xdpi)
    return ("Unsupported raster resolution (expected 300 or 600 dpi).");

 /* The PPD requests host-generated copies; never multiply them again. */
  if (header->NumCopies > 1)
    return ("Raster copies must be expanded by the renderer.");

 /*
  * Work out the full media box. cupsPageSize is the floating point page size
  * in points; cupsImagingBBox is the printable rectangle within it. When the
  * PPD declares a borderless size the two coincide and the padding collapses
  * to a straight copy.
  */
  layout->page_w = header->cupsPageSize[0];
  layout->page_h = header->cupsPageSize[1];

  if (layout->page_w == 0.0f && layout->page_h == 0.0f)
  {
    layout->page_w = (float)header->PageSize[0];
    layout->page_h = (float)header->PageSize[1];
  }

 /*
  * PWG stores PageSize in whole points. Apple's renderer truncates that
  * field, losing up to one point (8.3 pixels at 600 dpi). Its raster is
  * already edge-to-edge, so use the pixel extent for precise geometry while
  * checking that it agrees with the coarsely declared size. Plain CUPS
  * raster can describe an inset band and must retain its full media box.
  */
  if (!strcmp(header->MediaClass, "PwgRaster"))
  {
    double raster_w = (double)header->cupsWidth * 72.0 / layout->xdpi;
    double raster_h = (double)header->cupsHeight * 72.0 / layout->ydpi;

    if (!isfinite(layout->page_w) || !isfinite(layout->page_h) ||
        fabs(layout->page_w - raster_w) > 1.01 ||
        fabs(layout->page_h - raster_h) > 1.01)
      return ("PWG raster dimensions disagree with the declared page size.");

    layout->page_w = (float)raster_w;
    layout->page_h = (float)raster_h;
  }

 /* Validate both the pixel geometry and the signed IPP media dimensions. */
  layout->media_w = (double)layout->page_w * 2540.0 / 72.0;
  layout->media_h = (double)layout->page_h * 2540.0 / 72.0;

  if (!(layout->page_w > 0.0f) || !(layout->page_h > 0.0f) ||
      layout->media_w > (double)INT_MAX - 0.5 ||
      layout->media_h > (double)INT_MAX - 0.5 ||
      !points_to_pixels(layout->page_w, layout->xdpi, &layout->full_width) ||
      !points_to_pixels(layout->page_h, layout->ydpi, &layout->full_height))
    return ("Invalid raster page size.");

 /*
  * The same custom media range as scripts/genppd.py, in hundredths of mm.
  * A 0.01 mm tolerance accommodates floating point PPD dimensions. Raster
  * data is in feed orientation even when the document is landscape.
  */
  if (layout->media_w < 8890.0 - 1.0 || layout->media_w > 21590.0 + 1.0 ||
      layout->media_h < 12700.0 - 1.0 || layout->media_h > 35560.0 + 1.0)
    return ("Unsupported raster media size.");

 /*
  * Allow one pixel of page-size rounding, never an arbitrarily larger band.
  * Bound the input allocation too, allowing at most 32-bit row alignment.
  */
  if (header->cupsWidth > layout->full_width + 1 ||
      header->cupsHeight > layout->full_height + 1 ||
      header->cupsBytesPerLine > ((header->cupsWidth * layout->in_bpp + 3u) & ~3u))
    return ("Raster band exceeds the declared page geometry.");

  if (!isfinite(header->cupsImagingBBox[0]) ||
      !isfinite(header->cupsImagingBBox[1]) ||
      !isfinite(header->cupsImagingBBox[2]) ||
      !isfinite(header->cupsImagingBBox[3]))
    return ("Invalid raster imaging bounds.");

  layout->left_px = 0;
  layout->top_px  = 0;

  if (header->cupsImagingBBox[0] != 0.0f || header->cupsImagingBBox[1] != 0.0f ||
      header->cupsImagingBBox[2] != 0.0f || header->cupsImagingBBox[3] != 0.0f)
  {
    double tolerance = 72.0 / layout->xdpi;

    if (header->cupsImagingBBox[0] < -tolerance ||
        header->cupsImagingBBox[1] < -tolerance ||
        header->cupsImagingBBox[2] <= header->cupsImagingBBox[0] ||
        header->cupsImagingBBox[3] <= header->cupsImagingBBox[1] ||
        header->cupsImagingBBox[2] > layout->page_w + tolerance ||
        header->cupsImagingBBox[3] > layout->page_h + tolerance)
      return ("Raster imaging bounds exceed the declared page.");
  }

  if (header->cupsImagingBBox[2] > header->cupsImagingBBox[0] &&
      (!points_to_pixels(header->cupsImagingBBox[0], layout->xdpi,
                         &layout->left_px) ||
       !points_to_pixels((double)layout->page_h - header->cupsImagingBBox[3],
                         layout->ydpi, &layout->top_px)))
    return ("Invalid raster imaging offset.");

 /*
  * Never let rounding push the rendered band outside the sheet.
  */
  if (layout->full_width < header->cupsWidth)
    layout->full_width = header->cupsWidth;
  if (layout->full_height < header->cupsHeight)
    layout->full_height = header->cupsHeight;

  if (layout->left_px > layout->full_width - header->cupsWidth + 1 ||
      layout->top_px > layout->full_height - header->cupsHeight + 1)
    return ("Raster image offset exceeds the declared page.");

  if (layout->left_px > layout->full_width - header->cupsWidth)
    layout->left_px = layout->full_width - header->cupsWidth;
  if (layout->top_px > layout->full_height - header->cupsHeight)
    layout->top_px = layout->full_height - header->cupsHeight;

  return (NULL);
}

/*
 * Build the outgoing header. Start from the incoming one so that copies,
 * orientation and colour space survive, then restate the geometry and the
 * fields PWG Raster defines. Returns NULL on success or an error message.
 */
static const char *
make_pwg_header(const cups_page_header2_t *header,
                const page_layout_t       *layout,
                const job_options_t       *job,
                cups_page_header2_t       *pwg)
{
  pwg_media_t	*media;
  unsigned	bpp;

  memcpy(pwg, header, sizeof(*pwg));
  pwg->NumCopies = 1; /* URF omits this field; all copies are explicit pages. */

 /*
  * The printer accepts sgray_8 and srgb_8 only. cgpdftoraster already
  * rasterises in grey when ColorModel=Gray, but if colour data arrives for a
  * monochrome job the pixel copy converts it rather than sending colour.
  */
  if (layout->in_bpp < 3 || job->want_gray)
  {
    pwg->cupsColorSpace   = CUPS_CSPACE_SW;
    pwg->cupsNumColors    = 1;
    pwg->cupsBitsPerPixel = 8;
  }
  else
  {
    pwg->cupsColorSpace   = CUPS_CSPACE_SRGB;
    pwg->cupsNumColors    = 3;
    pwg->cupsBitsPerPixel = 24;
  }

  pwg->cupsBitsPerColor = 8;
  pwg->cupsColorOrder   = CUPS_ORDER_CHUNKED;
  pwg->cupsWidth        = layout->full_width;
  pwg->cupsHeight       = layout->full_height;
  pwg->HWResolution[0]  = layout->xdpi;
  pwg->HWResolution[1]  = layout->ydpi;

  bpp = pwg->cupsBitsPerPixel / 8;
  if (layout->full_width > UINT_MAX / bpp)
    return ("Raster output line is too large.");

  pwg->cupsBytesPerLine = bpp * layout->full_width;
  pwg->cupsCompression  = 0;

 /*
  * PWG Raster carries the media identity as a self-describing name, and
  * leaves the margin fields at zero because the image is already full bleed.
  */
  /* libcups' media table predates Brother's India Legal keyword. */
  if (fabs(layout->media_w - 21500.0) <= 2540.0 / layout->xdpi + 1.0 &&
      fabs(layout->media_h - 34500.0) <= 2540.0 / layout->ydpi + 1.0)
    strlcpy(pwg->cupsPageSizeName, "om_india-legal_215x345mm",
            sizeof(pwg->cupsPageSizeName));
  else if ((media = pwgMediaForSize((int)(layout->media_w + 0.5),
                                   (int)(layout->media_h + 0.5))) != NULL)
    strlcpy(pwg->cupsPageSizeName, media->pwg, sizeof(pwg->cupsPageSizeName));

  strlcpy(pwg->MediaType, job->media_type, sizeof(pwg->MediaType));

  pwg->cupsPageSize[0] = layout->page_w;
  pwg->cupsPageSize[1] = layout->page_h;
  pwg->PageSize[0]     = (unsigned)(layout->page_w + 0.5f);
  pwg->PageSize[1]     = (unsigned)(layout->page_h + 0.5f);

  memset(pwg->cupsImagingBBox, 0, sizeof(pwg->cupsImagingBBox));
  memset(pwg->ImagingBoundingBox, 0, sizeof(pwg->ImagingBoundingBox));
  memset(pwg->Margins, 0, sizeof(pwg->Margins));

  pwg->cupsBorderlessScalingFactor = 1.0f;

 /*
  * Note: cupsRasterWriteHeader2() normalises the PWG-specific cupsInteger[]
  * slots itself (TotalPageCount, the feed transforms and AlternatePrimary),
  * and zeroes the rest, so setting ImageBox* here would be discarded. Print
  * quality reaches the printer as the IPP print-quality attribute, which the
  * DCP-T420W lists in print-quality-supported, rather than via the raster.
  */

 /* The DCP-T420W has no duplexer and a single face-up output bin. */
  pwg->Duplex       = CUPS_FALSE;
  pwg->Tumble       = CUPS_FALSE;
  pwg->OutputFaceUp = CUPS_TRUE;

  return (NULL);
}

/*
 * Copy one page's pixels onto the padded sheet. Returns NULL on success
 * (including cancellation) or an error message.
 */
static const char *
copy_page(cups_raster_t             *in,
          cups_raster_t             *out,
          const cups_page_header2_t *header,
          const cups_page_header2_t *pwg,
          const page_layout_t       *layout)
{
  unsigned	in_bytes  = header->cupsBytesPerLine;
  unsigned	out_bytes = pwg->cupsBytesPerLine;
  unsigned	bpp       = pwg->cupsBitsPerPixel / 8;
  int		convert_gray = (layout->in_bpp >= 3 && bpp == 1);
  unsigned char	*in_line  = malloc(in_bytes);
  unsigned char	*out_line = malloc(out_bytes);
  const char	*error = NULL;
  unsigned	y;

  if (!in_line || !out_line)
  {
    free(in_line);
    free(out_line);
    return ("Out of memory allocating raster line buffers.");
  }

  for (y = 0; y < layout->full_height && !job_canceled; y ++)
  {
   /*
    * White is 0xFF in both sGray and sRGB, so a memset gives us blank paper;
    * rows outside the rendered band stay exactly that.
    */
    memset(out_line, 0xFF, out_bytes);

    if (y >= layout->top_px && y < layout->top_px + header->cupsHeight)
    {
      if (cupsRasterReadPixels(in, in_line, in_bytes) != in_bytes)
      {
        if (!job_canceled)
          error = "Truncated raster page.";
        break;
      }

      if (convert_gray)
      {
       /*
        * Rec. 601 luma, computed on the sRGB values as CUPS does.
        */
        const unsigned char	*src = in_line;
        unsigned char		*dst = out_line + layout->left_px;
        unsigned		i;

        for (i = 0; i < header->cupsWidth; i ++, src += layout->in_bpp)
          *dst++ = (unsigned char)((77u * src[0] + 151u * src[1] +
                                    28u * src[2]) >> 8);
      }
      else
        memcpy(out_line + layout->left_px * bpp, in_line,
               header->cupsWidth * bpp);
    }

    if (cupsRasterWritePixels(out, out_line, out_bytes) == 0)
    {
      error = "Unable to write PWG raster line.";
      break;
    }
  }

  free(in_line);
  free(out_line);

  return (error);
}

int
main(int argc, char *argv[])
{
  int			fd = 0;		/* Raster input descriptor */
  cups_raster_t		*in = NULL;	/* Incoming CUPS raster */
  cups_raster_t		*out = NULL;	/* Outgoing PWG raster */
  cups_page_header2_t	header;		/* Page header as rendered */
  cups_page_header2_t	pwg;		/* Page header as sent */
  job_options_t		job;		/* Job-wide settings */
  page_layout_t		layout;		/* Current page geometry */
  const char		*error = NULL;	/* First fatal error */
  unsigned		page = 0;
  struct sigaction	action;
  const char		*content_type = getenv("CONTENT_TYPE");
  int			report_pages;

  if (argc < 6 || argc > 7)
  {
    fputs("Usage: rastertobrother job user title copies options [file]\n", stderr);
    return (1);
  }

 /*
  * CONTENT_TYPE is the original job format for the whole CUPS chain.
  * cgpdftoraster already emits PAGE for PDF/image jobs. Count only direct
  * raster jobs here, otherwise the scheduler counts every sheet twice.
  */
  report_pages = !content_type ||
                 !strcmp(content_type, "application/vnd.cups-raster") ||
                 !strcmp(content_type, "image/pwg-raster") ||
                 !strcmp(content_type, "image/urf");

 /*
  * Register for cancellation before we start consuming the stream.
  */
  memset(&action, 0, sizeof(action));
  sigemptyset(&action.sa_mask);
  action.sa_handler = cancel_job;
  sigaction(SIGTERM, &action, NULL);
  signal(SIGPIPE, SIG_IGN);

  if (argc == 7 && (fd = open(argv[6], O_RDONLY)) < 0)
  {
    fprintf(stderr, "ERROR: Unable to open raster file \"%s\": %s\n",
            argv[6], strerror(errno));
    return (1);
  }

 /*
  * Media type, colour and quality are queue/job options, not per-page values.
  */
  error = load_job_options(argv[5], &job);

  if (!error && (in = cupsRasterOpen(fd, CUPS_RASTER_READ)) == NULL)
    error = "Unable to read CUPS raster stream.";
  if (!error && (out = cupsRasterOpen(1, CUPS_RASTER_WRITE_PWG)) == NULL)
    error = "Unable to open PWG raster output stream.";

  while (!error && !job_canceled && cupsRasterReadHeader2(in, &header))
  {
    page ++;
    if ((error = layout_page(&header, &layout)) != NULL ||
        (error = make_pwg_header(&header, &layout, &job, &pwg)) != NULL)
      break;

    fprintf(stderr,
            "DEBUG: Page %u: rendered %ux%u -> sheet %ux%u at %ux%udpi, "
            "offset %u,%u, %s, media=%s type=%s quality=%u\n",
            page, header.cupsWidth, header.cupsHeight,
            layout.full_width, layout.full_height, layout.xdpi, layout.ydpi,
            layout.left_px, layout.top_px,
            pwg.cupsColorSpace == CUPS_CSPACE_SW ? "sgray_8" : "srgb_8",
            pwg.cupsPageSizeName, pwg.MediaType, job.quality);

    if (!cupsRasterWriteHeader2(out, &pwg))
      error = "Unable to write PWG raster page header.";
    else
      error = copy_page(in, out, &header, &pwg, &layout);

    if (!error && !job_canceled && report_pages)
      fprintf(stderr, "PAGE: %u 1\n", page);
  }

  if (!error && !job_canceled && page == 0)
    error = "No pages found in the raster stream.";

  if (error)
    fprintf(stderr, "ERROR: %s\n", error);
  else
    fprintf(stderr, "DEBUG: Converted %u page(s) to PWG Raster.\n", page);

  if (job_canceled)
    fputs("DEBUG: Job canceled.\n", stderr);

  if (in)
    cupsRasterClose(in);
  if (out)
    cupsRasterClose(out);

  if (fd > 0)
    close(fd);

  return (error ? 1 : 0);
}
