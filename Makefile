PREFIX ?= $(HOME)/.local
# Resolved lazily, so only the signing targets pay for the keychain lookup, and
# `make test` never does. Falls back to "-" (ad-hoc) where no Developer ID
# identity exists, which is what a fresh clone and CI get. Override explicitly
# with SIGN_IDENTITY=... to pick a specific identity or to force ad-hoc.
SIGN_IDENTITY ?= $(shell scripts/signing-identity.sh)

.PHONY: build test sweep-test-temp app dmg release-dmg install clean icon

build:
	swift build -c release

# The unit suites create their fixture project trees under the user temp dir
# (directa-sup-*, directa-wt-*, directa-cfg-*, …) and never delete them: a run
# killed part way has no one to clean up after it. This sweeps anything older
# than a day, so a second `make test` running concurrently is untouched and a
# just-finished run's own dirs are not yanked from under a still-attached
# debugger. Best-effort by design (macOS system dirs are unreadable and make
# find exit 1), so a failed sweep never fails a test run.
sweep-test-temp:
	@find "$$(getconf DARWIN_USER_TEMP_DIR)" -mindepth 1 -maxdepth 1 -name 'directa-*' -type d -mtime +0 -exec rm -rf {} + 2>/dev/null || true

test: sweep-test-temp
	swift test

app: build
	scripts/make-app-bundle.sh "$(SIGN_IDENTITY)"

dmg: app
	scripts/make-dmg.sh "$(SIGN_IDENTITY)"

# Maintainer release image: always Developer ID signed, notarized, and stapled.
# DIRECTA_REQUIRE_SIGNING=1 fails the app build if no Developer ID cert is present
# (never a silent ad-hoc fallback) and implies notarization, which then fails
# loudly if the notary credentials are unreachable rather than shipping a test
# image. Re-invokes `make dmg` so both the app build and the DMG step see the
# environment. This is the path for anything a user will install or launch;
# contributors use `make dmg` for the unsigned/test image.
release-dmg:
	DIRECTA_REQUIRE_SIGNING=1 DIRECTA_NOTARIZE=1 $(MAKE) dmg

install: build app
	mkdir -p $(PREFIX)/bin
	install .build/release/directa $(PREFIX)/bin/directa
	install .build/release/ddirecta $(PREFIX)/bin/ddirecta
	ditto directa.app /Applications/directa.app
	$(PREFIX)/bin/directa daemon install

# Regenerates Resources/AppIcon.png and AppIcon.icns from logo.svg. The icns is
# checked in, so `make app` does not need librsvg; re-run this after changing
# the mark (`brew install librsvg` for rsvg-convert).
icon:
	scripts/make-app-icon.sh

clean:
	swift package clean
	rm -rf directa.app dist
