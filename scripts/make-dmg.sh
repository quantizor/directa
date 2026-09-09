#!/bin/zsh
# Builds the directa DMG from the assembled (and signed) directa.app.
# Usage: scripts/make-dmg.sh [SIGN_IDENTITY]
#
# The image holds the app alone: no /Applications symlink. Setup happens inside
# the app (it copies itself to /Applications after an explicit confirm), so a
# drag target would be a second, conflicting way to install. The window
# background says to double-click instead.
#
# Finder styling needs a GUI session. Without one the AppleScript pass is skipped
# and the image still ships, just unstyled: plain icon view, background file
# present but unused. Set DIRECTA_DMG_REQUIRE_LAYOUT=1 to make that a hard error,
# so a release build never quietly loses the instructions.
#
# Two kinds of image. A TEST image is what an external contributor gets: signed
# with whatever identity is available (ad-hoc when the keychain has none) and not
# notarized, so Gatekeeper blocks it on other machines, which is fine for local
# testing. A REAL image is notarized and stapled, and is reserved for where the
# notarytool credentials live: the maintainer's machine (the `devctl-notary`
# keychain profile, which kept the old product name) or CI (App Store Connect
# API key env). make dmg notarizes automatically when those credentials are
# reachable; DIRECTA_NOTARIZE=1 demands the real path (failing if they are
# missing) and the release build sets
# DIRECTA_REQUIRE_SIGNING=1, which implies it. SKIP_NOTARIZE=1 forces the fast
# local loop; DIRECTA_DMG_QUARANTINE=0 drops the download stamp.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${1:--}"
APP="$ROOT/directa.app"
DIST="$ROOT/dist"
STAGE="$DIST/dmg-stage"
VOLUME_NAME="directa"

[[ -d "$APP" ]] || { echo "make-dmg: run make app first (missing $APP)" >&2; exit 1 }

# A leftover volume of this name makes the new one mount as "directa 1". The
# layout pass below reads the real name back so it still styles the right disk,
# but a stale mount also means a later double-click can open the OLD image, so
# say so rather than leaving it to be discovered during a test install.
if [[ -d "/Volumes/$VOLUME_NAME" ]]; then
  echo "note: /Volumes/$VOLUME_NAME is already mounted, so this build will mount alongside it." >&2
  echo "      detach it with: hdiutil detach /Volumes/$VOLUME_NAME" >&2
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
DMG="$DIST/directa-${VERSION}.dmg"
RW_DMG="$DIST/.directa-${VERSION}.rw.dmg"

rm -rf "$STAGE"
mkdir -p "$STAGE/.background" "$DIST"
ditto "$APP" "$STAGE/directa.app"

echo "rendering background..."
swift "$ROOT/scripts/make-dmg-background.swift" "$STAGE/.background"
tiffutil -cathidpicheck \
  "$STAGE/.background/background.png" \
  "$STAGE/.background/background@2x.png" \
  -out "$STAGE/.background/background.tiff" > /dev/null
rm -f "$STAGE/.background/background.png" "$STAGE/.background/background@2x.png"

rm -f "$DMG" "$RW_DMG"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDRW \
  "$RW_DMG" > /dev/null

# Mount under /Volumes and read the name back: Finder resolves the window by
# volume name, and a stale directa mount makes this one "directa 1". Custom
# -mountpoint or -nobrowse both break the AppleScript lookup.
MOUNT_POINT="$(hdiutil attach "$RW_DMG" -noverify -noautoopen | awk -F'\t' '/\/Volumes\// { print $NF }' | tail -1)"
[[ -n "$MOUNT_POINT" ]] || { echo "make-dmg: could not mount $RW_DMG" >&2; exit 1 }
MOUNTED_NAME="$(basename "$MOUNT_POINT")"
abort_cleanup() {
  hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  rm -f "$RW_DMG"
  rm -rf "$STAGE"
}
trap abort_cleanup EXIT

LAYOUT_LOG="$(mktemp "${TMPDIR:-/tmp}/directa-dmg-layout.XXXXXX")"
if osascript - "$MOUNTED_NAME" > "$LAYOUT_LOG" 2>&1 <<'APPLESCRIPT'
on run argv
  set volumeName to item 1 of argv
  tell application "Finder"
    tell disk volumeName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 120, 760, 520}
      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 128
      set text size of viewOptions to 12
      set background picture of viewOptions to file ".background:background.tiff"
      set position of item "directa.app" of container window to {280, 162}
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
APPLESCRIPT
then
  echo "applied Finder window layout"
  rm -f "$LAYOUT_LOG"
elif [[ "${DIRECTA_DMG_REQUIRE_LAYOUT:-0}" == "1" ]]; then
  echo "make-dmg: Finder window layout failed and DIRECTA_DMG_REQUIRE_LAYOUT=1" >&2
  cat "$LAYOUT_LOG" >&2
  echo "make-dmg: run from a logged-in GUI session, grant the terminal Automation access for Finder, and check that no other volume is named $VOLUME_NAME" >&2
  exit 1
else
  echo "note: skipped Finder layout; the image ships unstyled. Reason:"
  sed 's/^/  /' "$LAYOUT_LOG"
  rm -f "$LAYOUT_LOG"
fi

rm -rf "$MOUNT_POINT/.fseventsd"
sync
hdiutil detach "$MOUNT_POINT" -quiet
trap - EXIT

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" > /dev/null
rm -f "$RW_DMG"
rm -rf "$STAGE"

# Whether notarytool credentials are reachable. Real (notarized) images are built
# where these live: this machine's `devctl-notary` keychain profile (the stored
# credential kept the old product name), or CI's App Store Connect API key env.
# A contributor without them still gets a signed TEST image and a clear note,
# never a hard failure. A false negative here costs the
# maintainer only a `DIRECTA_NOTARIZE=1`; it never blocks a contributor.
notary_creds_available() {
  if [[ -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" \
        && ( -n "${APPLE_API_KEY_PATH:-}" || -n "${APPLE_API_KEY_BASE64:-}" ) ]]; then
    return 0
  fi
  local profile="${NOTARY_KEYCHAIN_PROFILE:-devctl-notary}"
  # notarytool's store-credentials service name has varied across Xcode; probe
  # the known spellings by label and service.
  security find-generic-password -l "$profile" >/dev/null 2>&1 && return 0
  security find-generic-password -s "com.apple.gke.notary.tool.saved-creds.$profile" \
    >/dev/null 2>&1 && return 0
  security find-generic-password -s "com.apple.gke.notary.tool" >/dev/null 2>&1 && return 0
  return 1
}

if [[ "$IDENTITY" == "-" ]]; then
  echo "note: ad-hoc image, so no notarization (it requires a Developer ID signature)." >&2
  echo "      Gatekeeper will refuse this on any machine that did not build it." >&2
else
  codesign --force --sign "$IDENTITY" "$DMG"
  echo "signed DMG with $IDENTITY"

  # A real release is signed AND notarized; a contributor build is signed only.
  # DIRECTA_NOTARIZE=1 (and the release build's DIRECTA_REQUIRE_SIGNING=1) demands
  # the real path, so a missing credential fails loudly rather than shipping a
  # test image. SKIP_NOTARIZE=1 forces the fast local loop. Otherwise notarize
  # only when the credentials are actually reachable.
  require_notarize=0
  [[ "${DIRECTA_NOTARIZE:-}" == "1" || "${DIRECTA_REQUIRE_SIGNING:-0}" == "1" ]] && require_notarize=1

  if [[ "${SKIP_NOTARIZE:-0}" == "1" && "$require_notarize" != "1" ]]; then
    echo "note: SKIP_NOTARIZE=1. Quarantined, Gatekeeper will block this image." >&2
  elif [[ "$require_notarize" == "1" ]] || notary_creds_available; then
    # notarize.sh fails if the credentials are missing, which is the point when a
    # real build was demanded.
    NOTARIZE_TARGET="$DMG" "$ROOT/scripts/notarize.sh"
    # Gatekeeper assesses the image and the app inside it separately, so check
    # the image here with the policy Finder uses when opening a download.
    spctl -a -vvv -t open --context context:primary-signature "$DMG"
  else
    echo "note: signed TEST DMG, not notarized (no notarytool credentials found)." >&2
    echo "      Real notarized releases are built on the maintainer's machine or in CI." >&2
    echo "      Quarantined, Gatekeeper will block this image; that is expected for a test build." >&2
  fi
fi

# A download carries com.apple.quarantine; a locally built file does not, and
# without it Gatekeeper never runs its first-launch check at all. Stamping it
# here is what makes a local double-click match what a user gets. The attribute
# is per-file metadata and does not survive an upload, so a released artifact is
# unaffected. Set DIRECTA_DMG_QUARANTINE=0 to build without it.
if [[ "${DIRECTA_DMG_QUARANTINE:-1}" == "1" ]]; then
  xattr -w com.apple.quarantine \
    "0081;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" "$DMG"
  echo "stamped com.apple.quarantine (as a download would)"
fi

echo "wrote $DMG"
