# Build the rastertobrother CUPS filter.
#
# The filter links against the system libcups. macOS ships the library but the
# headers live in the SDK, so pull the include path from xcrun.

SDK      := $(shell xcrun --show-sdk-path)
CC       ?= cc
ARCHS    ?= -arch arm64 -arch x86_64
CFLAGS   ?= -Os -Wall -Wextra -Wno-deprecated-declarations -isysroot $(SDK)
LDFLAGS  ?= -isysroot $(SDK) -lcups

TARGET   := rastertobrother

all: $(TARGET)

$(TARGET): rastertobrother.c
	$(CC) $(ARCHS) $(CFLAGS) -o $@ $< $(LDFLAGS)

# Single-architecture build, useful when cross-arch SDK stubs are unavailable.
native: rastertobrother.c
	$(CC) $(CFLAGS) -o $(TARGET) $< $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all native clean
