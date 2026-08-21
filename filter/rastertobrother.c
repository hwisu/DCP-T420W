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
#include <math.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

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
 * Round a length in PostScript points to whole device pixels.
 */
static unsigned
points_to_pixels(float points, unsigned dpi)
{
  double px = (double)points * (double)dpi / 72.0;

  if (px < 0.0)
    px = 0.0;

  return ((unsigned)(px + 0.5));
}

int
main(int argc, char *argv[])
{
  int			fd = 0;		/* Raster input descriptor */
  cups_raster_t		*in = NULL;	/* Incoming CUPS raster */
  cups_raster_t		*out = NULL;	/* Outgoing PWG raster */
  cups_page_header2_t	header;		/* Page header as rendered */
  cups_page_header2_t	pwg;		/* Page header as sent */
  ppd_file_t		*ppd = NULL;	/* PPD for this queue */
  cups_option_t		*options = NULL;/* Job options */
  int			num_options = 0;
  ppd_choice_t		*choice;
  unsigned char		*in_line = NULL, *out_line = NULL;
  unsigned		page = 0;
  int			exit_status = 0;
  struct sigaction	action;

  if (argc < 6 || argc > 7)
  {
    fputs("Usage: rastertobrother job user title copies options [file]\n", stderr);
    return (1);
  }

 /*
  * Register for cancellation before we start consuming the stream.
  */
  memset(&action, 0, sizeof(action));
  sigemptyset(&action.sa_mask);
  action.sa_handler = cancel_job;
  sigaction(SIGTERM, &action, NULL);

  if (argc == 7)
  {
    if ((fd = open(argv[6], O_RDONLY)) < 0)
    {
      fprintf(stderr, "ERROR: Unable to open raster file \"%s\": %s\n",
              argv[6], strerror(errno));
      return (1);
    }
  }

  num_options = cupsParseOptions(argv[5], 0, &options);

  if ((ppd = ppdOpenFile(getenv("PPD"))) != NULL)
  {
    ppdMarkDefaults(ppd);
    cupsMarkOptions(ppd, num_options, options);
  }
  else
    fputs("DEBUG: No PPD available, relying on raster header values.\n", stderr);

  if ((in = cupsRasterOpen(fd, CUPS_RASTER_READ)) == NULL)
  {
    fputs("ERROR: Unable to read CUPS raster stream.\n", stderr);
    exit_status = 1;
    goto cleanup;
  }

  if ((out = cupsRasterOpen(1, CUPS_RASTER_WRITE_PWG)) == NULL)
  {
    fputs("ERROR: Unable to open PWG raster output stream.\n", stderr);
    exit_status = 1;
    goto cleanup;
  }

 /*
  * Resolve the media type once; it is a queue/job option, not a per-page value.
  */
  const char	*type_keyword = "stationery";
  unsigned	quality = 4;		/* IPP print-quality: 4 = normal */
  int		want_gray = 0;		/* Job asked for monochrome output */

  if (ppd && (choice = ppdFindMarkedChoice(ppd, "MediaType")) != NULL)
    type_keyword = media_type_keyword(choice->choice);

  if (ppd && (choice = ppdFindMarkedChoice(ppd, "ColorModel")) != NULL)
    want_gray = !strcasecmp(choice->choice, "Gray");

  if (ppd && (choice = ppdFindMarkedChoice(ppd, "cupsPrintQuality")) != NULL)
  {
    if (!strcasecmp(choice->choice, "Draft"))
      quality = 3;
    else if (!strcasecmp(choice->choice, "High"))
      quality = 5;
  }

  while (!job_canceled && cupsRasterReadHeader2(in, &header))
  {
    unsigned	xdpi, ydpi;		/* Device resolution */
    unsigned	full_width, full_height;/* Full-bleed page in pixels */
    unsigned	left_px, top_px;	/* Offset of the imageable area */
    unsigned	bpp;			/* Bytes per pixel */
    unsigned	in_bytes, out_bytes;	/* Line lengths */
    unsigned	y;
    pwg_media_t	*media;

    page ++;
    fprintf(stderr, "PAGE: %u %u\n", page, header.NumCopies ? header.NumCopies : 1);

    xdpi = header.HWResolution[0] ? header.HWResolution[0] : 600;
    ydpi = header.HWResolution[1] ? header.HWResolution[1] : 600;

   /*
    * Work out the full media box. cupsPageSize is the floating point page size
    * in points; cupsImagingBBox is the printable rectangle within it. When the
    * PPD declares a borderless size the two coincide and the padding below
    * collapses to a straight copy.
    */
    float	page_w = header.cupsPageSize[0];
    float	page_h = header.cupsPageSize[1];

    if (page_w <= 0.0f || page_h <= 0.0f)
    {
      page_w = (float)header.PageSize[0];
      page_h = (float)header.PageSize[1];
    }

    full_width  = points_to_pixels(page_w, xdpi);
    full_height = points_to_pixels(page_h, ydpi);

    if (header.cupsImagingBBox[2] > header.cupsImagingBBox[0])
    {
      left_px = points_to_pixels(header.cupsImagingBBox[0], xdpi);
      top_px  = points_to_pixels(page_h - header.cupsImagingBBox[3], ydpi);
    }
    else
    {
      left_px = 0;
      top_px  = 0;
    }

   /*
    * Never let rounding push the rendered band outside the sheet.
    */
    if (full_width < header.cupsWidth)
      full_width = header.cupsWidth;
    if (full_height < header.cupsHeight)
      full_height = header.cupsHeight;

    if (left_px + header.cupsWidth > full_width)
      left_px = full_width - header.cupsWidth;
    if (top_px + header.cupsHeight > full_height)
      top_px = full_height - header.cupsHeight;

   /*
    * Build the outgoing header. Start from the incoming one so that copies,
    * orientation and colour space survive, then restate the geometry and the
    * fields PWG Raster defines.
    */
    memcpy(&pwg, &header, sizeof(pwg));

    unsigned	in_bpp = header.cupsBitsPerPixel / 8;
    int		convert_gray = 0;

   /*
    * The printer accepts sgray_8 and srgb_8 only. cgpdftoraster already
    * rasterises in grey when ColorModel=Gray, but if colour data arrives for a
    * monochrome job we do the conversion here rather than sending colour.
    */
    if (in_bpp < 3 || want_gray)
    {
      pwg.cupsColorSpace   = CUPS_CSPACE_SW;
      pwg.cupsNumColors    = 1;
      pwg.cupsBitsPerPixel = 8;
      convert_gray         = (in_bpp >= 3);
    }
    else
    {
      pwg.cupsColorSpace   = CUPS_CSPACE_SRGB;
      pwg.cupsNumColors    = 3;
      pwg.cupsBitsPerPixel = 24;
    }

    pwg.cupsBitsPerColor = 8;
    pwg.cupsColorOrder   = CUPS_ORDER_CHUNKED;
    pwg.cupsWidth        = full_width;
    pwg.cupsHeight       = full_height;
    pwg.cupsBytesPerLine = (pwg.cupsBitsPerPixel / 8) * full_width;
    pwg.cupsCompression  = 0;

   /*
    * PWG Raster carries the media identity as a self-describing name, and
    * leaves the margin fields at zero because the image is already full bleed.
    */
    if ((media = pwgMediaForSize((int)(page_w * 2540.0f / 72.0f + 0.5f),
                                 (int)(page_h * 2540.0f / 72.0f + 0.5f))) != NULL)
      strlcpy(pwg.cupsPageSizeName, media->pwg, sizeof(pwg.cupsPageSizeName));

    strlcpy(pwg.MediaType, type_keyword, sizeof(pwg.MediaType));

    pwg.cupsPageSize[0] = page_w;
    pwg.cupsPageSize[1] = page_h;
    pwg.PageSize[0]     = (unsigned)(page_w + 0.5f);
    pwg.PageSize[1]     = (unsigned)(page_h + 0.5f);

    pwg.cupsImagingBBox[0] = 0.0f;
    pwg.cupsImagingBBox[1] = 0.0f;
    pwg.cupsImagingBBox[2] = 0.0f;
    pwg.cupsImagingBBox[3] = 0.0f;
    memset(pwg.ImagingBoundingBox, 0, sizeof(pwg.ImagingBoundingBox));
    memset(pwg.Margins, 0, sizeof(pwg.Margins));

    pwg.cupsBorderlessScalingFactor = 1.0f;

   /*
    * Note: cupsRasterWriteHeader2() normalises the PWG-specific cupsInteger[]
    * slots itself (TotalPageCount, the feed transforms and AlternatePrimary),
    * and zeroes the rest, so setting ImageBox* here would be discarded. Print
    * quality reaches the printer as the IPP print-quality attribute, which the
    * DCP-T420W lists in print-quality-supported, rather than via the raster.
    */

   /* The DCP-T420W has no duplexer and a single face-up output bin. */
    pwg.Duplex       = CUPS_FALSE;
    pwg.Tumble       = CUPS_FALSE;
    pwg.OutputFaceUp = CUPS_TRUE;

    fprintf(stderr,
            "DEBUG: Page %u: rendered %ux%u -> sheet %ux%u at %ux%udpi, "
            "offset %u,%u, %s, media=%s type=%s quality=%u\n",
            page, header.cupsWidth, header.cupsHeight, full_width, full_height,
            xdpi, ydpi, left_px, top_px,
            pwg.cupsColorSpace == CUPS_CSPACE_SW ? "sgray_8" : "srgb_8",
            pwg.cupsPageSizeName, pwg.MediaType, quality);

    if (!cupsRasterWriteHeader2(out, &pwg))
    {
      fputs("ERROR: Unable to write PWG raster page header.\n", stderr);
      exit_status = 1;
      break;
    }

    in_bytes  = header.cupsBytesPerLine;
    out_bytes = pwg.cupsBytesPerLine;
    bpp       = pwg.cupsBitsPerPixel / 8;

    free(in_line);
    free(out_line);
    in_line  = malloc(in_bytes);
    out_line = malloc(out_bytes);

    if (!in_line || !out_line)
    {
      fputs("ERROR: Out of memory allocating raster line buffers.\n", stderr);
      exit_status = 1;
      break;
    }

   /*
    * White is 0xFF in both sGray and sRGB, so a memset gives us blank paper.
    */
    memset(out_line, 0xFF, out_bytes);

    for (y = 0; y < full_height && !job_canceled; y ++)
    {
      if (y < top_px || y >= top_px + header.cupsHeight)
      {
       /* Margin band above or below the rendered area. */
        memset(out_line, 0xFF, out_bytes);
      }
      else
      {
        if (cupsRasterReadPixels(in, in_line, in_bytes) == 0)
        {
         /* Short page: pad the remainder rather than truncating the sheet. */
          memset(out_line, 0xFF, out_bytes);
        }
        else
        {
          unsigned pixels = header.cupsWidth;

          if (left_px + pixels > full_width)
            pixels = full_width - left_px;

          memset(out_line, 0xFF, out_bytes);

          if (convert_gray)
          {
           /*
            * Rec. 601 luma, computed on the sRGB values as CUPS does.
            */
            const unsigned char	*src = in_line;
            unsigned char	*dst = out_line + left_px;
            unsigned		i;

            for (i = 0; i < pixels; i ++, src += in_bpp)
              *dst++ = (unsigned char)((77u * src[0] + 151u * src[1] +
                                        28u * src[2]) >> 8);
          }
          else
            memcpy(out_line + left_px * bpp, in_line, pixels * bpp);
        }
      }

      if (cupsRasterWritePixels(out, out_line, out_bytes) == 0)
      {
        fputs("ERROR: Unable to write PWG raster line.\n", stderr);
        exit_status = 1;
        break;
      }
    }

    if (exit_status)
      break;
  }

  if (page == 0 && !exit_status)
  {
    fputs("ERROR: No pages found in the raster stream.\n", stderr);
    exit_status = 1;
  }
  else if (!exit_status)
    fprintf(stderr, "DEBUG: Converted %u page(s) to PWG Raster.\n", page);

  if (job_canceled)
    fputs("DEBUG: Job canceled.\n", stderr);

cleanup:

  free(in_line);
  free(out_line);

  if (in)
    cupsRasterClose(in);
  if (out)
    cupsRasterClose(out);
  if (ppd)
    ppdClose(ppd);

  cupsFreeOptions(num_options, options);

  if (fd > 0)
    close(fd);

  return (exit_status);
}
