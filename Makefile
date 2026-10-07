# All dependencies are supplied by macOS/Xcode, except Python for dev tools.
PYTHON ?= python3
COMPONENTS := filter scanner airprint

all: $(COMPONENTS)

$(COMPONENTS):
	$(MAKE) -C $@

check: all
	$(PYTHON) -m unittest discover -s test -v
	$(MAKE) check-sources

check-sources:
	mkdir -p build
	$(PYTHON) scripts/genppd.py > build/check.ppd
	cmp build/check.ppd ppd/Brother-DCP-T420W.ppd
	cupstestppd -q ppd/Brother-DCP-T420W.ppd
	@for script in install.sh uninstall.sh packaging/build-pkg.sh packaging/scripts/postinstall packaging/scripts-sharing/postinstall scripts/probe.sh; do \
		bash -n "$$script" || exit 1; \
	done

clean:
	$(MAKE) -C filter clean
	$(MAKE) -C scanner clean
	$(MAKE) -C airprint clean

.PHONY: all $(COMPONENTS) check check-sources clean
