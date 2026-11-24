# All dependencies are supplied by macOS/Xcode.
SDK          ?= $(shell xcrun --sdk macosx --show-sdk-path)
SWIFTC       ?= xcrun --sdk macosx swiftc
CLANG        ?= xcrun --sdk macosx clang
SWIFTFLAGS   ?= -O -swift-version 6
MODULE_CACHE ?= $(abspath build/swift-module-cache)
SWIFT_BUILD   = $(SWIFTC) $(SWIFTFLAGS) -sdk "$(SDK)" -module-cache-path "$(MODULE_CACHE)"
SWIFT_CHECK   = $(SWIFTC) -typecheck -swift-version 6 -warnings-as-errors -sdk "$(SDK)" -module-cache-path "$(MODULE_CACHE)"
CLANG_CHECK   = $(CLANG) -fsyntax-only -isysroot "$(SDK)" -mmacosx-version-min=11.0 \
                -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Wundef \
                -Wstrict-prototypes -Wold-style-definition -Wmissing-prototypes -Werror

COMPONENTS := filter scanner airprint
C_SOURCES  := filter/rastertobrother.c airprint/brairprint.c
SWIFT_SOURCES := scanner/brscan.swift scripts/genppd.swift \
                 test/PWG.swift test/pwgdump.swift test/pwg2png.swift \
                 test/make_testpage.swift test/Runner.swift \
                 test/RegressionTests.swift test/PrintPipelineTests.swift
SHELL_SCRIPTS := install.sh uninstall.sh packaging/build-pkg.sh \
                 packaging/scripts/postinstall packaging/scripts-sharing/postinstall \
                 scripts/probe.sh
TOOLS := build/genppd build/pwgdump build/pwg2png build/make_testpage

all: $(COMPONENTS)

$(COMPONENTS):
	$(MAKE) -C $@

tools: $(TOOLS)

build/genppd: scripts/genppd.swift
	mkdir -p "$(MODULE_CACHE)"
	$(SWIFT_BUILD) $< -o $@

build/pwgdump: test/PWG.swift test/pwgdump.swift
	mkdir -p "$(MODULE_CACHE)"
	$(SWIFT_BUILD) $^ -lz -o $@

build/pwg2png: test/PWG.swift test/pwg2png.swift
	mkdir -p "$(MODULE_CACHE)"
	$(SWIFT_BUILD) $^ -lz -o $@

build/make_testpage: test/make_testpage.swift
	mkdir -p "$(MODULE_CACHE)"
	$(SWIFT_BUILD) $< -lz -o $@

build/run-tests: test/PWG.swift test/Runner.swift test/RegressionTests.swift test/PrintPipelineTests.swift
	mkdir -p "$(MODULE_CACHE)"
	$(SWIFT_BUILD) $^ -lz -o $@

check: all build/genppd build/run-tests
	./build/run-tests
	$(MAKE) check-sources

check-sources: build/genppd
	mkdir -p build
	./build/genppd > build/check.ppd
	cmp build/check.ppd ppd/Brother-DCP-T420W.ppd
	cupstestppd -q ppd/Brother-DCP-T420W.ppd
	plutil -lint -s packaging/launchd/com.hwisu.dcp-t420w.airprint.plist
	xmllint --noout packaging/distribution.xml
	@for script in $(SHELL_SCRIPTS); do \
		bash -n "$$script" || exit 1; \
	done

lint: check-sources
	$(CLANG_CHECK) $(C_SOURCES)
	@for src in $(C_SOURCES); do \
		out="$$($(CLANG) --analyze -Xanalyzer -analyzer-output=text -isysroot "$(SDK)" -mmacosx-version-min=11.0 -o build/analyze.plist "$$src" 2>&1)"; \
		if [ -n "$$out" ]; then echo "$$out"; exit 1; fi; \
	done
	xcrun clang-format --dry-run --Werror $(C_SOURCES)
	mkdir -p "$(MODULE_CACHE)"
	$(SWIFT_CHECK) scanner/brscan.swift
	$(SWIFT_CHECK) scripts/genppd.swift
	$(SWIFT_CHECK) test/PWG.swift test/pwgdump.swift
	$(SWIFT_CHECK) test/PWG.swift test/pwg2png.swift
	$(SWIFT_CHECK) test/make_testpage.swift
	$(SWIFT_CHECK) test/PWG.swift test/Runner.swift test/RegressionTests.swift test/PrintPipelineTests.swift
	xcrun swift-format lint --strict --configuration .swift-format $(SWIFT_SOURCES)
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(SHELL_SCRIPTS); \
	fi

format:
	xcrun clang-format -i $(C_SOURCES)
	xcrun swift-format format --configuration .swift-format -i $(SWIFT_SOURCES)

clean:
	$(MAKE) -C filter clean
	$(MAKE) -C scanner clean
	$(MAKE) -C airprint clean
	rm -f $(TOOLS) build/run-tests build/check.ppd build/analyze.plist

.PHONY: all $(COMPONENTS) tools check check-sources lint format clean
