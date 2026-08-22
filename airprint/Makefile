# Build brairprint, the AirPrint Bonjour advertiser.
#
# Links against libcups (to read the queue's UUID) and Bonjour, both of which
# ship with macOS; as with the filter, the headers come from the SDK.

SDK      := $(shell xcrun --show-sdk-path)
CC       ?= cc
ARCHS    ?= -arch arm64 -arch x86_64
CFLAGS   ?= -Os -Wall -Wextra -Wno-deprecated-declarations -isysroot $(SDK)
LDFLAGS  ?= -isysroot $(SDK) -lcups

TARGET   := brairprint

all: $(TARGET)

$(TARGET): brairprint.c
	$(CC) $(ARCHS) $(CFLAGS) -o $@ $< $(LDFLAGS)

# Single-architecture build, useful when cross-arch SDK stubs are unavailable.
native: brairprint.c
	$(CC) $(CFLAGS) -o $(TARGET) $< $(LDFLAGS)

install: $(TARGET)
	install -d /usr/local/libexec
	install -m 0755 $(TARGET) /usr/local/libexec/$(TARGET)

clean:
	rm -f $(TARGET)

.PHONY: all native install clean
