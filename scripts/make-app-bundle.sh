#!/bin/zsh
# Assembles directa.app from the SPM-built products. No Xcode: the bundle is
# directory layout + Info.plist + signature. Contents/Resources carries the CLI
# (and a Resources copy of the daemon for setup); Contents/Helpers/ddirecta is the
# daemon SMAppService BundleProgram target; Contents/Library/LaunchAgents holds
# two in-bundle agent plists: the daemon's (dev.quantizor.directa, BundleProgram
# Contents/Helpers/ddirecta) and the app's own (dev.quantizor.directa.app,
# BundleProgram Contents/MacOS/directa-app, the app's KeepAlive resilience
# against TAL and jetsam). $1 is the signing identity; the Makefile resolves it
# through scripts/signing-identity.sh, which prefers a Developer ID certificate
# and falls back to "-" (ad-hoc) when the keychain has none.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${1:--}"
CONFIG="${2:-release}"
BUILD="$ROOT/.build/$CONFIG"
APP_BINARY="$BUILD/DirectaApp"
CLI_BINARY="$BUILD/directa"
DAEMON_BINARY="$BUILD/ddirecta"
APP="$ROOT/directa.app"
LABEL="dev.quantizor.directa"

[[ -x "$APP_BINARY" ]] || { echo "make-app-bundle: build first (missing $APP_BINARY)" >&2; exit 1 }
[[ -x "$CLI_BINARY" ]] || { echo "make-app-bundle: build first (missing $CLI_BINARY)" >&2; exit 1 }
[[ -x "$DAEMON_BINARY" ]] || { echo "make-app-bundle: build first (missing $DAEMON_BINARY)" >&2; exit 1 }

ICON_ICNS="$ROOT/Resources/AppIcon.icns"
[[ -f "$ICON_ICNS" ]] || { echo "make-app-bundle: missing $ICON_ICNS" >&2; exit 1 }

rm -rf "$APP"
mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources" \
  "$APP/Contents/Helpers" \
  "$APP/Contents/Library/LaunchAgents"
cp "$APP_BINARY" "$APP/Contents/MacOS/directa-app"
cp "$CLI_BINARY" "$APP/Contents/Resources/directa"
cp "$DAEMON_BINARY" "$APP/Contents/Resources/ddirecta"
cp "$DAEMON_BINARY" "$APP/Contents/Helpers/ddirecta"
cp "$ICON_ICNS" "$APP/Contents/Resources/AppIcon.icns"
chmod 755 \
  "$APP/Contents/MacOS/directa-app" \
  "$APP/Contents/Resources/directa" \
  "$APP/Contents/Resources/ddirecta" \
  "$APP/Contents/Helpers/ddirecta"

# Sealed in-bundle agent: BundleProgram (SMAppService-only), static PATH floor.
# Dynamic login PATH lives in Application Support/agent.path (daemon applies it).
# Stdio redirects omitted: per-user paths cannot be baked into a notarized plist;
# the daemon writes its own daemon.log after start.
cat > "$APP/Contents/Library/LaunchAgents/${LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>BundleProgram</key>
	<string>Contents/Helpers/ddirecta</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
	<key>ExitTimeOut</key>
	<integer>60</integer>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
PLIST

# The app's own agent (Start at login; why: docs/macos-lifecycle.md "Menu bar
# extra"). No PATH floor: the GUI app never spawns dev servers, only Terminal
# logins (TerminalRunner) for brew, which get a real login shell's PATH already.
APP_LABEL="dev.quantizor.directa.app"
cat > "$APP/Contents/Library/LaunchAgents/${APP_LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>BundleProgram</key>
	<string>Contents/MacOS/directa-app</string>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>Label</key>
	<string>${APP_LABEL}</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
PLIST

VERSION="$("$CLI_BINARY" --version 2>/dev/null || echo 0.1.0)"

# Release builds require a real signature: an ad-hoc image installs through the
# cask and is then disabled by Gatekeeper. Enforced here because the Makefile
# resolves the identity through $(shell ...), which swallows the exit code of
# scripts/signing-identity.sh.
if [[ "$IDENTITY" == "-" && "${DIRECTA_REQUIRE_SIGNING:-0}" == "1" ]]; then
  echo "make-app-bundle: DIRECTA_REQUIRE_SIGNING=1 but no signing identity; refusing to build an ad-hoc release." >&2
  exit 1
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>quantizor/directa</string>
    <key>CFBundleExecutable</key>
    <string>directa-app</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>dev.quantizor.directa.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>directa</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Evan Jacobs</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>dev.quantizor.directa.url</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>directa</string>
            </array>
        </dict>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "APPL????" > "$APP/Contents/PkgInfo"

sign() {
  local target="$1"
  if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign "$IDENTITY" "$target"
  else
    # Hardened runtime is required for Developer ID notarization.
    codesign --force --options runtime --sign "$IDENTITY" "$target"
  fi
}

# Nested Mach-Os first, then the outer bundle (Gatekeeper walks inward).
sign "$APP/Contents/Resources/directa"
sign "$APP/Contents/Resources/ddirecta"
sign "$APP/Contents/Helpers/ddirecta"
sign "$APP/Contents/MacOS/directa-app"
sign "$APP"
echo "assembled $APP (signed: $IDENTITY; Helpers/ddirecta + LaunchAgents + Resources)"

# Warn at the point of signing, because the build succeeds either way and the
# cost only lands later, on whoever installs over a previous copy. Reasoning for
# why the Team ID matters lives in scripts/signing-identity.sh.
#
# DIRECTA_ADHOC_EXPECTED=1 silences it for a bundle nobody installs (smoke.sh
# builds one to assert its layout), so the warning keeps meaning "this one will
# bite you" rather than becoming noise the gate prints every run.
if [[ "$IDENTITY" == "-" && "${DIRECTA_ADHOC_EXPECTED:-0}" != "1" ]]; then
  echo "warning: ad-hoc signed (no Team ID). Installing this over an existing copy" >&2
  echo "         stalls ddirecta for tens of seconds: the stale launch constraint" >&2
  echo "         SIGKILLs it on exec until BTM invalidates its item." >&2
  echo "         To sign, install a Developer ID certificate or pass SIGN_IDENTITY=..." >&2
  echo "         (scripts/signing-identity.sh picks one up automatically when present.)" >&2
fi
