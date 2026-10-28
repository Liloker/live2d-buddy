# Live2D Buddy — common tasks. Run `make help`.
APP      := build/Live2D Buddy.app
PREFIX   ?= $(HOME)/Applications
BINDIR   ?= $(HOME)/.local/bin
VERSION  := $(shell cat VERSION)
ZIP      := dist/Live2D-Buddy-macOS.zip

.PHONY: help build universal assets run install uninstall test smoke dist clean

help:
	@echo "make build      compile build/Live2D Buddy.app (native arch)"
	@echo "make assets     download the Live2D runtime + demo characters (third-party, ~4 MB)"
	@echo "make run        build, fetch assets if needed, launch"
	@echo "make install    install to $(PREFIX) and the 'buddy' CLI to $(BINDIR)"
	@echo "make uninstall  remove the app and the CLI (keeps downloaded assets)"
	@echo "make test       unit tests (Node.js)"
	@echo "make smoke      headless-ish check that every character renders"
	@echo "make dist       universal build zipped into $(ZIP)"

build:
	@scripts/build.sh

universal:
	@ARCHS="arm64 x86_64" scripts/build.sh

assets:
	@scripts/fetch-assets.sh

run: build
	@scripts/fetch-assets.sh --check --quiet || scripts/fetch-assets.sh
	@open "$(APP)"

install: build
	@scripts/fetch-assets.sh --check --quiet || scripts/fetch-assets.sh
	@mkdir -p "$(PREFIX)" "$(BINDIR)"
	@osascript -e 'tell application id "io.github.liloker.live2dbuddy" to quit' >/dev/null 2>&1 || true
	@rm -rf "$(PREFIX)/Live2D Buddy.app"
	@ditto "$(APP)" "$(PREFIX)/Live2D Buddy.app"
	@install -m 755 bin/buddy "$(BINDIR)/buddy"
	@open "$(PREFIX)/Live2D Buddy.app"
	@echo "Installed $(PREFIX)/Live2D Buddy.app and $(BINDIR)/buddy"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) echo "Note: add $(BINDIR) to your PATH to use 'buddy' directly.";; esac

uninstall:
	@osascript -e 'tell application id "io.github.liloker.live2dbuddy" to quit' >/dev/null 2>&1 || true
	@rm -rf "$(PREFIX)/Live2D Buddy.app" "$(BINDIR)/buddy"
	@echo "Removed. Downloaded assets remain in ~/Library/Application Support/Live2D Buddy"

test:
	@node tests/core.test.cjs

smoke: build
	@scripts/fetch-assets.sh --check --quiet || scripts/fetch-assets.sh
	@"$(APP)/Contents/MacOS/Live2DBuddy" --smoke-test

dist: universal
	@mkdir -p dist
	@rm -f "$(ZIP)"
	@ditto -c -k --keepParent "$(APP)" "$(ZIP)"
	@shasum -a 256 "$(ZIP)"

clean:
	@rm -rf build dist
