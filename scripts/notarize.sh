#!/bin/zsh
# Notarize and staple a Developer ID-signed DMG (or app). Credentials come from
# the environment / keychain; never commit secrets.
#
# Auth (one of):
#   NOTARY_KEYCHAIN_PROFILE  (default: devctl-notary, the stored credential name)
#   APPLE_API_KEY_ID + APPLE_API_ISSUER + (APPLE_API_KEY_PATH | APPLE_API_KEY_BASE64) — CI
# Optional:
#   NOTARIZE_TARGET    (path to .dmg or .app; default: newest dist/directa-*.dmg)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

TARGET="${NOTARIZE_TARGET:-}"
if [[ -z "$TARGET" ]]; then
  TARGET="$(ls -t "$ROOT"/dist/directa-*.dmg 2>/dev/null | head -1 || true)"
fi
[[ -n "$TARGET" && -e "$TARGET" ]] || {
  echo "notarize: no target (set NOTARIZE_TARGET or build make dmg first)" >&2
  exit 1
}

PROFILE="${NOTARY_KEYCHAIN_PROFILE:-devctl-notary}"
AUTH_ARGS=()
CLEANUP_KEY=""

if [[ -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" ]]; then
  KEY_PATH="${APPLE_API_KEY_PATH:-}"
  if [[ -z "$KEY_PATH" ]]; then
    : "${APPLE_API_KEY_BASE64:?set APPLE_API_KEY_PATH or APPLE_API_KEY_BASE64}"
    # The private key lands in a 0700 directory of its own: mktemp only
    # randomizes trailing Xs, so a template like AuthKey.XXXXXX.p8 would be a
    # fixed, world-readable path, and chmod after the write leaves a window.
    KEY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/directa-notary.XXXXXX")"
    KEY_PATH="$KEY_DIR/AuthKey.p8"
    CLEANUP_KEY="$KEY_DIR"
    print -r -- "$APPLE_API_KEY_BASE64" | base64 -D > "$KEY_PATH"
  fi
  AUTH_ARGS=(--key "$KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
else
  AUTH_ARGS=(--keychain-profile "$PROFILE")
fi

trap '[[ -n "$CLEANUP_KEY" ]] && rm -rf "$CLEANUP_KEY"' EXIT

echo "submitting $TARGET for notarization..."
xcrun notarytool submit "$TARGET" "${AUTH_ARGS[@]}" --wait

echo "stapling $TARGET..."
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
echo "notarize ok: $TARGET"
