#!/bin/zsh
# Scans the package for unused code with Periphery and fails when it finds any.
# Usage: scripts/dead-code.sh [extra periphery scan flags, e.g. --format json]
#
# Settings live in .periphery.yml. Three things this wrapper owns:
# - The index. Swift Build (the default SwiftPM build system on Swift 6.4)
#   writes the compiler's index store to .build/out, not the
#   .build/debug/index/store path Periphery looks for, so the script builds
#   every target including tests and Periphery reads .build/out with its own
#   build skipped. Test targets are indexed so shared test helpers count as used.
# - No network. Periphery 3.8.0 sends `GET /v1/suggest-plan?loc=<line count>`
#   to its vendor on every scan with no flag to turn it off; pointing
#   PERIPHERY_API_BASE_URL at the discard port makes that request fail locally.
#   The update check is off in .periphery.yml.
# - The version pin. A release other than PERIPHERY_VERSION fails loudly, since
#   a new one may drop that override or add billing; read its source for network
#   calls before raising the pin.
#
# A finding is a candidate, not a delete order: check what the code does first.
# Code the index cannot see a use for (a C struct's padding fields, a strong
# reference held only to keep an object alive) carries its own
# `/** periphery:ignore - <reason> */` comment.
set -euo pipefail

PERIPHERY_VERSION=3.8.0

cd "${0:A:h}/.."

if ! command -v periphery >/dev/null; then
  echo "error: periphery is not installed" >&2
  echo "fix: brew install periphery (the script expects version $PERIPHERY_VERSION)" >&2
  exit 1
fi

installed="$(periphery version)"
if [[ "$installed" != "$PERIPHERY_VERSION" ]]; then
  echo "error: periphery $installed is installed, but scripts/dead-code.sh is pinned to $PERIPHERY_VERSION" >&2
  echo "fix: check the new release's source for outbound network calls and whether PERIPHERY_API_BASE_URL still overrides them, then update PERIPHERY_VERSION in scripts/dead-code.sh" >&2
  exit 1
fi

swift build --build-tests

units=(.build/out/v5/units/*(N))
if (( ${#units} == 0 )); then
  echo "error: swift build wrote no index store to .build/out/v5" >&2
  echo "fix: the build system may have moved its index; find it with: find .build -type d -name v5, then update index_store_path in .periphery.yml and this check" >&2
  exit 1
fi

PERIPHERY_API_BASE_URL=http://127.0.0.1:9/v1 periphery scan --config .periphery.yml --quiet "$@"
