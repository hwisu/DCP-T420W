# Build the rastertobrother CUPS filter.
#
# The filter links against the system libcups. macOS ships the library but the
# headers live in the SDK, so pull the include path from xcrun.

SDK      ?= $(shell xcrun --sdk macosx --show-sdk-path)
ifeq ($(origin CC), default)
CC       := xcrun --sdk macosx clang
endif
ARCHS    ?= -arch arm64 -arch x86_64
MIN_OS   ?= 11.0
CFLAGS   ?= -Os -Wall -Wextra
LDLIBS   += -lcups
BUILD_FLAGS = -isysroot "$(SDK)" -mmacosx-version-min=$(MIN_OS)

TARGET   := rastertobrother

.DELETE_ON_ERROR:

all: $(TARGET)

$(TARGET): rastertobrother.c Makefile
	$(CC) $(ARCHS) $(CPPFLAGS) $(CFLAGS) $(BUILD_FLAGS) -o $@ $< $(LDFLAGS) $(LDLIBS)

# Single-architecture build, useful when cross-arch SDK stubs are unavailable.
native: rastertobrother.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(BUILD_FLAGS) -o $(TARGET) $< $(LDFLAGS) $(LDLIBS)

clean:
	rm -f $(TARGET)

.PHONY: all native clean
