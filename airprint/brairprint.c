/*
 * brairprint — publishes a CUPS queue as an AirPrint printer.
 *
 * macOS printer sharing advertises a shared queue as a plain _ipp._tcp
 * service. iOS never sees it, for two independent reasons:
 *
 *   1. AirPrint clients browse the _universal subtype of _ipp._tcp, and cupsd
 *      registers the queue without it.
 *   2. They ignore any printer whose TXT record has no URF key, and cupsd does
 *      not emit one. Declaring *cupsUrfSupported in the PPD does not change
 *      this -- the queue's own PPD copy in /etc/cups/ppd carries the attribute
 *      and the TXT record still comes out without URF. Apple's cupsd simply
 *      does not build that key for shared queues.
 *
 * So we publish a second Bonjour record for the same queue, carrying what
 * AirPrint actually asks for. Jobs still land in the ordinary CUPS queue and
 * take the ordinary path:
 *
 *     iOS -> ipp://this-mac:631/printers/<queue> -> cupsd
 *         -> cgpdftoraster (PDF) or the image/urf edge (Apple Raster)
 *         -> rastertobrother -> image/pwg-raster -> printer
 *
 * Nothing is proxied or reimplemented here. This process registers a name and
 * then sleeps in select(); it never touches a job.
 *
 * Usage:  brairprint [--queue NAME] [--name "Service name"] [--port N]
 *
 * Copyright: written for personal use with a Brother DCP-T420W.
 */

#include <dns_sd.h>
#include <cups/cups.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <arpa/inet.h>
#include <sys/select.h>

#define DEFAULT_QUEUE "Brother_DCP_T420W"
#define DEFAULT_NAME  "Brother DCP-T420W (AirPrint)"
#define DEFAULT_PORT  631

/*
 * What the printer can actually do, in URF's vocabulary (PWG 5100.14):
 *
 *   CP1        one copy per job; the DCP-T420W has no collator
 *   IS1        a single input slot
 *   PQ3-4-5    draft, normal and high, matching the PPD's three qualities
 *   RS300-600  the two resolutions the firmware accepts
 *   SRGB24     srgb_8   -- colour
 *   W8         sgray_8  -- greyscale
 *   DM1        simplex only, which is honest: there is no duplexer
 *   FN3        no finishings
 *   V1.4       URF version
 */
#define URF_SUPPORTED "CP1,IS1,PQ3-4-5,RS300-600,SRGB24,W8,DM1,FN3,V1.4"

/*
 * The formats iOS may send. application/pdf is the common case and takes the
 * long-tested cgpdftoraster route; image/urf is Apple Raster, which libcups
 * reads transparently, so the PPD's image/urf edge hands it to the same
 * filter. Advertising a format we cannot convert would fail at job time, so
 * this list has to stay in step with the PPD.
 */
#define PDL_SUPPORTED "application/pdf,image/urf,image/jpeg,image/pwg-raster"

static volatile sig_atomic_t stop_requested = 0;

static void
on_signal(int sig)
{
  (void)sig;
  stop_requested = 1;
}

/*
 * Ask the local queue for its UUID, so the record we publish and the queue it
 * points at agree on identity. iOS remembers a printer by this, and a UUID
 * that changed on every restart would leave stale printers on the phone.
 *
 * Doubles as our readiness check: at boot we may well start before cupsd has
 * the queue, and a Bonjour record pointing at a queue that does not exist is
 * worse than no record at all.
 */
static int
printer_uuid(const char *queue, char *buf, size_t bufsize)
{
  http_t		*http;
  ipp_t			*request, *response;
  ipp_attribute_t	*attr;
  char			uri[1024];
  int			found = 0;
  static const char * const requested[] = { "printer-uuid" };

  if ((http = httpConnect2("localhost", DEFAULT_PORT, NULL, AF_UNSPEC,
                           HTTP_ENCRYPTION_IF_REQUESTED, 1, 5000, NULL)) == NULL)
    return 0;

  httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof(uri), "ipp", NULL,
                   "localhost", DEFAULT_PORT, "/printers/%s", queue);

  request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES);
  ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI,
               "printer-uri", NULL, uri);
  ippAddStrings(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD,
                "requested-attributes", 1, NULL, requested);

  response = cupsDoRequest(http, request, "/");

  if (response != NULL &&
      (attr = ippFindAttribute(response, "printer-uuid", IPP_TAG_URI)) != NULL)
  {
    const char *value = ippGetString(attr, 0, NULL);

    if (value != NULL)
    {
     /* CUPS reports urn:uuid:xxxx; the TXT record carries the bare form. */
      if (!strncmp(value, "urn:uuid:", 9))
        value += 9;

      strlcpy(buf, value, bufsize);
      found = 1;
    }
  }

  ippDelete(response);
  httpClose(http);

  return found;
}

static void DNSSD_API
on_register(DNSServiceRef ref, DNSServiceFlags flags, DNSServiceErrorType err,
            const char *name, const char *type, const char *domain, void *ctx)
{
  (void)ref; (void)flags; (void)type; (void)domain; (void)ctx;

  if (err == kDNSServiceErr_NoError)
    fprintf(stderr, "INFO: registered \"%s\" for AirPrint.\n", name);
  else
    fprintf(stderr, "ERROR: Bonjour registration failed (%d).\n", (int)err);
}

int
main(int argc, char *argv[])
{
  const char	*queue = DEFAULT_QUEUE;
  const char	*name  = DEFAULT_NAME;
  int		port   = DEFAULT_PORT;
  char		uuid[64] = "";
  char		hostname[256];
  char		rp[512], adminurl[1024];
  TXTRecordRef	txt;
  DNSServiceRef	ref = NULL;
  DNSServiceErrorType	err;
  int		fd, i;

  for (i = 1; i < argc; i ++)
  {
    if (!strcmp(argv[i], "--queue") && i + 1 < argc)
      queue = argv[++ i];
    else if (!strcmp(argv[i], "--name") && i + 1 < argc)
      name = argv[++ i];
    else if (!strcmp(argv[i], "--port") && i + 1 < argc)
      port = atoi(argv[++ i]);
    else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help"))
    {
      puts("Usage: brairprint [--queue NAME] [--name \"Service name\"] [--port N]");
      return 0;
    }
    else
    {
      fprintf(stderr, "ERROR: unknown option %s\n", argv[i]);
      return 2;
    }
  }

  signal(SIGTERM, on_signal);
  signal(SIGINT, on_signal);
  signal(SIGPIPE, SIG_IGN);

 /*
  * Wait for the queue rather than exiting and letting launchd respawn us in a
  * tight loop. At boot cupsd is usually a few seconds behind us.
  */
  while (!printer_uuid(queue, uuid, sizeof(uuid)) && !stop_requested)
  {
    static int complained = 0;

    if (!complained)
    {
      fprintf(stderr, "INFO: waiting for queue \"%s\"...\n", queue);
      complained = 1;
    }

    sleep(5);
  }

  if (stop_requested)
    return 0;

  if (gethostname(hostname, sizeof(hostname)) != 0)
    strlcpy(hostname, "localhost", sizeof(hostname));

  snprintf(rp, sizeof(rp), "printers/%s", queue);
  snprintf(adminurl, sizeof(adminurl), "http://%s:%d/printers/%s",
           hostname, port, queue);

  TXTRecordCreate(&txt, 0, NULL);
  TXTRecordSetValue(&txt, "txtvers",  1, "1");
  TXTRecordSetValue(&txt, "qtotal",   1, "1");
  TXTRecordSetValue(&txt, "rp",       (uint8_t)strlen(rp), rp);
  TXTRecordSetValue(&txt, "ty",       17, "Brother DCP-T420W");
  TXTRecordSetValue(&txt, "product",  11, "(DCP-T420W)");
  TXTRecordSetValue(&txt, "note",     0,  "");
  TXTRecordSetValue(&txt, "priority", 1,  "0");
  TXTRecordSetValue(&txt, "adminurl", (uint8_t)strlen(adminurl), adminurl);
  TXTRecordSetValue(&txt, "pdl",      (uint8_t)strlen(PDL_SUPPORTED), PDL_SUPPORTED);
  TXTRecordSetValue(&txt, "URF",      (uint8_t)strlen(URF_SUPPORTED), URF_SUPPORTED);
  TXTRecordSetValue(&txt, "Color",    1, "T");
  TXTRecordSetValue(&txt, "Duplex",   1, "F");
  TXTRecordSetValue(&txt, "Scan",     1, "F");
  TXTRecordSetValue(&txt, "UUID",     (uint8_t)strlen(uuid), uuid);

 /*
  * The ",_universal" suffix is the part iOS is actually browsing for. Without
  * it the record is published and never looked at.
  */
  err = DNSServiceRegister(&ref, 0, kDNSServiceInterfaceIndexAny,
                           name, "_ipp._tcp,_universal", NULL, NULL,
                           htons((uint16_t)port),
                           TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt),
                           on_register, NULL);

  TXTRecordDeallocate(&txt);

  if (err != kDNSServiceErr_NoError)
  {
    fprintf(stderr, "ERROR: DNSServiceRegister failed (%d).\n", (int)err);
    return 1;
  }

  fd = DNSServiceRefSockFD(ref);

  while (!stop_requested)
  {
    fd_set		input;
    struct timeval	timeout = { 1, 0 };
    int			ready;

    FD_ZERO(&input);
    FD_SET(fd, &input);

    ready = select(fd + 1, &input, NULL, NULL, &timeout);

    if (ready > 0 && FD_ISSET(fd, &input))
    {
      if (DNSServiceProcessResult(ref) != kDNSServiceErr_NoError)
        break;
    }
    else if (ready < 0 && errno != EINTR)
      break;
  }

  DNSServiceRefDeallocate(ref);

  return 0;
}
