# Build brscan, the native scanner client.
#
# Universal by default so one binary covers Apple Silicon and Intel. The
# resulting binary has no runtime dependencies: Bonjour, URLSession and
# ImageIO all come from the system.

SWIFTC  ?= swiftc
SWIFTFLAGS ?= -O
TARGET  := brscan
MIN_OS  := 11

all: $(TARGET)

$(TARGET): brscan.swift
	$(SWIFTC) $(SWIFTFLAGS) -target arm64-apple-macos$(MIN_OS)  $< -o $@-arm64
	$(SWIFTC) $(SWIFTFLAGS) -target x86_64-apple-macos$(MIN_OS) $< -o $@-x86_64
	lipo -create -output $@ $@-arm64 $@-x86_64
	rm -f $@-arm64 $@-x86_64

# Single-architecture build for the machine you are on.
native: brscan.swift
	$(SWIFTC) $(SWIFTFLAGS) brscan.swift -o $(TARGET)

install: $(TARGET)
	install -d /usr/local/bin
	install -m 0755 $(TARGET) /usr/local/bin/$(TARGET)

clean:
	rm -f $(TARGET) $(TARGET)-arm64 $(TARGET)-x86_64

.PHONY: all native install clean
