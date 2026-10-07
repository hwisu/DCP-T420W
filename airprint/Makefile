# Build brairprint, the AirPrint Bonjour advertiser.
#
# Links against libcups (to read the queue's UUID) and Bonjour, both of which
# ship with macOS; as with the filter, the headers come from the SDK.

SDK      ?= $(shell xcrun --sdk macosx --show-sdk-path)
ifeq ($(origin CC), default)
CC       := xcrun --sdk macosx clang
endif
ARCHS    ?= -arch arm64 -arch x86_64
MIN_OS   ?= 11.0
CFLAGS   ?= -Os -Wall -Wextra
LDLIBS   += -lcups
BUILD_FLAGS = -isysroot "$(SDK)" -mmacosx-version-min=$(MIN_OS)

TARGET   := brairprint

.DELETE_ON_ERROR:

all: $(TARGET)

$(TARGET): brairprint.c Makefile
	$(CC) $(ARCHS) $(CPPFLAGS) $(CFLAGS) $(BUILD_FLAGS) -o $@ $< $(LDFLAGS) $(LDLIBS)

# Single-architecture build, useful when cross-arch SDK stubs are unavailable.
native: brairprint.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(BUILD_FLAGS) -o $(TARGET) $< $(LDFLAGS) $(LDLIBS)

install: $(TARGET)
	install -d /usr/local/libexec
	install -m 0755 $(TARGET) /usr/local/libexec/$(TARGET)

clean:
	rm -f $(TARGET)

.PHONY: all native install clean
