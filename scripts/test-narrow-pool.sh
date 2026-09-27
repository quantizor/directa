#!/bin/zsh -f
# Runs the unit suites with Swift's cooperative pool narrowed to a small
# runner's size and fails when anything blocks a pool thread.
#
# A GitHub macOS runner has about three cores, so the cooperative pool (one
# thread per core) has about three threads, shared by every suite running in
# parallel and by the daemon code under test. A test body or daemon path
# that blocks one of them (a semaphore, a process wait, a pipe read, a
# sleep) goes unnoticed on a many-core laptop and stalls or hangs the whole
# run on CI. This makes a laptop run behave like the runner and names the
# blocking call.
#
# Usage: scripts/test-narrow-pool.sh [swift-testing arguments, e.g. --filter X]
#   NARROW_POOL_WIDTH          pool threads to leave (default 3)
#   NARROW_POOL_BLOCKED_SECONDS  how long a pool thread may wait before it is
#                              reported (default 1)
#
# How: builds scripts/narrow-pool/narrow-pool.c into .build/narrow-pool, then
# runs the built test bundle through the toolchain's swiftpm-testing-helper
# directly (`swift test` goes through a SIP-protected /usr/bin shim that
# strips DYLD_INSERT_LIBRARIES) with the library inserted. The library's
# header says what it narrows and how it watches.
#
# Output: the Swift Testing report, one "BLOCKED:" line and the waiting
# thread's stack per pool thread that waited past the threshold (repeated
# demangled at the end), and a summary. A full sample of the process at each
# BLOCKED moment is written next to the run log, and the run log's path is
# printed at the end.
#
# Fails (nonzero) when a test fails, when a pool thread was reported
# blocked, or when the pool could not be narrowed. Tests run with
# DIRECTA_TEST_TEMP_ROOT set to a fresh directory, removed afterward.
#
# Blind spots: those of the library (a wait under the threshold, a user-space
# spin, other QoS classes); and only the default-QoS pool is narrowed, so work
# a test runs at another priority still has every core.
set -u

root=${0:A:h:h}
cd "$root" || exit 1

toolchain_bin=$(dirname "$(xcrun --find swift)") || { echo "error: xcrun cannot find swift" >&2; exit 1 }
helper="$toolchain_bin/../libexec/swift/pm/swiftpm-testing-helper"
platform=$(xcrun --show-sdk-platform-path) || { echo "error: xcrun cannot find the macOS platform" >&2; exit 1 }
sdk=$(xcrun --show-sdk-path) || { echo "error: xcrun cannot find the macOS SDK" >&2; exit 1 }
[[ -x $helper ]] || { echo "error: no swiftpm-testing-helper at $helper; this toolchain runs tests differently" >&2; exit 1 }

mkdir -p .build/narrow-pool
library=$root/.build/narrow-pool/libnarrow-pool.dylib
clang -dynamiclib -O1 -Wall -Werror -isysroot "$sdk" -o "$library" scripts/narrow-pool/narrow-pool.c || exit 1

swift build --build-tests || exit 1
bundle="$(swift build --show-bin-path)/directaPackageTests.xctest/Contents/MacOS/directaPackageTests"
[[ -x $bundle ]] || { echo "error: no test bundle at $bundle after the build" >&2; exit 1 }

run=$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR)directa-narrow.XXXXXX") || exit 1
temp_root=$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR)directa-run.XXXXXX") || exit 1
log=$run/run.log

DYLD_FRAMEWORK_PATH="$platform/Developer/Library/Frameworks:$platform/Developer/Library/PrivateFrameworks" \
DYLD_LIBRARY_PATH="$platform/Developer/usr/lib" \
DYLD_INSERT_LIBRARIES="$library" \
NARROW_POOL_SAMPLE_DIR="$run" \
DIRECTA_TEST_TEMP_ROOT="$temp_root" \
  "$helper" --test-bundle-path "$bundle" "$@" "$bundle" --testing-library swift-testing 2>&1 | tee "$log"
test_status=${pipestatus[1]}
rm -rf "$temp_root"

result=$test_status
if ! grep -q '^\[narrow-pool\] cooperative pool narrowed' "$log"; then
  echo "error: the pool was never narrowed (the library did not load into the test process)" >&2
  result=1
fi
if grep -q '^\[narrow-pool\] BLOCKED:' "$log"; then
  echo "--- blocked pool threads, demangled ---" >&2
  grep '^\[narrow-pool\]' "$log" | xcrun swift-demangle --simplified >&2
  echo "error: a cooperative-pool thread was blocked; the stacks above, and full samples in $run/blocked-*.txt" >&2
  echo "fix: move the blocking call off the pool (a BlockingLane in product code, offPool in a test; Tests/DirectaTestSupport/OffPool.swift)" >&2
  result=1
fi
echo "run log: $log"
exit $result
