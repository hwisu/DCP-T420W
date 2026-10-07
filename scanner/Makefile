# Build brscan, the native scanner client.
#
# Universal by default so one binary covers Apple Silicon and Intel. The
# resulting binary has no runtime dependencies: Bonjour, URLSession and
# ImageIO all come from the system.

SDK     ?= $(shell xcrun --sdk macosx --show-sdk-path)
SWIFTC  ?= xcrun --sdk macosx swiftc
SWIFTFLAGS ?= -O -swift-version 6
TARGET  := brscan
MIN_OS  ?= 11.0
NATIVE_ARCH ?= $(shell uname -m)
MODULE_CACHE ?= $(abspath ../build/swift-module-cache)
BUILD_FLAGS = -sdk "$(SDK)" -module-cache-path "$(MODULE_CACHE)"

.DELETE_ON_ERROR:

all: $(TARGET)

$(TARGET): brscan.swift Makefile
	$(SWIFTC) $(SWIFTFLAGS) $(BUILD_FLAGS) -target arm64-apple-macos$(MIN_OS)  $< -o $@-arm64
	$(SWIFTC) $(SWIFTFLAGS) $(BUILD_FLAGS) -target x86_64-apple-macos$(MIN_OS) $< -o $@-x86_64
	xcrun lipo -create -output $@ $@-arm64 $@-x86_64
	rm -f $@-arm64 $@-x86_64

# Single-architecture build for the machine you are on.
native: brscan.swift
	$(SWIFTC) $(SWIFTFLAGS) $(BUILD_FLAGS) -target $(NATIVE_ARCH)-apple-macos$(MIN_OS) $< -o $(TARGET)

install: $(TARGET)
	install -d /usr/local/bin
	install -m 0755 $(TARGET) /usr/local/bin/$(TARGET)

clean:
	rm -f $(TARGET) $(TARGET)-arm64 $(TARGET)-x86_64

.PHONY: all native install clean
