PREFIX ?= $(HOME)/.local
# Resolved lazily, so only the signing targets pay for the keychain lookup, and
# `make test` never does. Falls back to "-" (ad-hoc) where no Developer ID
# identity exists, which is what a fresh clone and CI get. Override explicitly
# with SIGN_IDENTITY=... to pick a specific identity or to force ad-hoc.
SIGN_IDENTITY ?= $(shell scripts/signing-identity.sh)

.PHONY: build test sweep-test-temp app dmg release-dmg install clean icon

# The shipped products only. A bare `swift build -c release` also compiles the
# test-only targets (DirectaTestSupport imports Testing). `--product` keeps
# only its last value, hence one invocation per product.
build:
	swift build -c release --product directa
	swift build -c release --product ddirecta
	swift build -c release --product DirectaApp

# A run killed part way leaves its scratch trees under the user temp dir
# (directa-run.* from `make test`, directa-test-* from TemporaryTree when no
# run root is set) with no one to clean up after it. This sweeps exactly those
# two shapes, never another directa-* entry there (the grok hook's turn state
# lives in directa-grok-hook), and only when older than a day, so a second `make test` running concurrently is
# untouched and a just-finished run's own dirs are not yanked from under a
# still-attached debugger. Best-effort by design (macOS system dirs are
# unreadable and make find exit 1), so a failed sweep never fails a test run.
sweep-test-temp:
	@find "$$(getconf DARWIN_USER_TEMP_DIR)" -mindepth 1 -maxdepth 1 \( -name 'directa-run.*' -o -name 'directa-test-*' \) -type d -mtime +0 -exec rm -rf {} + 2>/dev/null || true

# Every test's scratch tree comes from TemporaryTree
# (Tests/DirectaTestSupport/TemporaryTree.swift), which removes it when the
# test ends. The run gets its own root through DIRECTA_TEST_TEMP_ROOT, and a
# root that is not empty afterward fails the run and is kept for inspection:
# something bypassed the helper, or a server rebuilt a tree after its test
# returned.
test: sweep-test-temp
	@root="$$(mktemp -d "$$(getconf DARWIN_USER_TEMP_DIR)directa-run.XXXXXX")" || exit 1; \
	DIRECTA_TEST_TEMP_ROOT="$$root" swift test; status=$$?; \
	left="$$(find "$$root" -mindepth 1 -maxdepth 1)"; \
	if [ -n "$$left" ]; then \
		echo "error: the test run left temporary trees in $$root:" >&2; \
		echo "$$left" >&2; \
		echo "fix: each test's tree must be gone when it returns; see Tests/DirectaTestSupport/TemporaryTree.swift" >&2; \
		exit 1; \
	fi; \
	rm -rf "$$root"; \
	exit $$status

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
