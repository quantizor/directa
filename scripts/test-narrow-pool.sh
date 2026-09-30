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
#        scripts/test-narrow-pool.sh --self-test
#   NARROW_POOL_WIDTH          pool threads to leave (default 3)
#   NARROW_POOL_BLOCKED_SECONDS  how long a pool thread may wait before it is
#                              reported (default 1)
# Tests run as many at once as make test allows (Makefile, TEST_PARALLEL_WIDTH).
# --self-test runs only the library's own checks and exits with their result:
# a thread-churning process must survive the watcher (the watcher reads other
# threads' memory, which a thread that exited no longer maps), and a pool
# thread blocked on a semaphore must be reported with its waiting function.
# Run it after editing scripts/narrow-pool/narrow-pool.c.
#
# How: builds scripts/narrow-pool/narrow-pool.c into .build/narrow-pool, then
# runs each built test bundle through the toolchain's swiftpm-testing-helper
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

# The same parallel-width cap make test runs under (the why: Makefile,
# TEST_PARALLEL_WIDTH).
width=$(make --no-print-directory -s test-parallel-width) || width=
[[ -n $width ]] || { echo "error: cannot read TEST_PARALLEL_WIDTH from the Makefile" >&2; echo "fix: run from a checkout whose Makefile has the test-parallel-width target" >&2; exit 1 }
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=$width

mkdir -p .build/narrow-pool
library=$root/.build/narrow-pool/libnarrow-pool.dylib
clang -dynamiclib -O1 -Wall -Werror -isysroot "$sdk" -o "$library" scripts/narrow-pool/narrow-pool.c || exit 1

if [[ ${1:-} == --self-test ]]; then
  churn=$root/.build/narrow-pool/self-test-thread-churn
  blocked=$root/.build/narrow-pool/self-test-blocked-pool-thread
  clang -O1 -Wall -Werror -isysroot "$sdk" -o "$churn" scripts/narrow-pool/self-test-thread-churn.c || exit 1
  clang -O0 -fno-omit-frame-pointer -Wall -Werror -isysroot "$sdk" -o "$blocked" scripts/narrow-pool/self-test-blocked-pool-thread.c || exit 1
  self_test=0

  NARROW_POOL_PROCESS=${churn:t} DYLD_INSERT_LIBRARIES="$library" "$churn" 10
  churn_status=$?
  if (( churn_status == 0 )); then
    echo "self-test ok: a thread-churning process survived the watcher"
  else
    echo "self-test FAILED: the thread-churning process exited $churn_status under the watcher (139 is a crash in the watcher's read of another thread's memory)" >&2
    self_test=1
  fi

  blocked_log=$(NARROW_POOL_PROCESS=${blocked:t} DYLD_INSERT_LIBRARIES="$library" "$blocked" 2>&1)
  if [[ $blocked_log == *'[narrow-pool] BLOCKED:'* && $blocked_log == *'blockThePool'* ]]; then
    echo "self-test ok: a pool thread blocked on a semaphore was reported with its waiting function"
  else
    echo "self-test FAILED: no BLOCKED report naming blockThePool; the watcher printed:" >&2
    echo "$blocked_log" >&2
    self_test=1
  fi
  exit $self_test
fi

swift build --build-tests || exit 1
bin_path=$(swift build --show-bin-path) || exit 1
# The native build system links one directaPackageTests bundle; the default
# Swift Build engine writes one bundle per test target.
bundles=()
if [[ -d $bin_path/directaPackageTests.xctest ]]; then
  bundles=("$bin_path/directaPackageTests.xctest/Contents/MacOS/directaPackageTests")
else
  for packaged in "$bin_path"/*Tests.xctest(N); do
    bundles+=("$packaged/Contents/MacOS/${packaged:t:r}")
  done
fi
(( ${#bundles} > 0 )) || { echo "error: no test bundle under $bin_path after the build" >&2; exit 1 }

run=$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR)directa-narrow.XXXXXX") || exit 1
temp_root=$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR)directa-run.XXXXXX") || exit 1

result=0
for bundle in $bundles; do
  [[ -x $bundle ]] || { echo "error: no test bundle at $bundle after the build" >&2; result=1; continue }
  log=$run/${bundle:t}.log

  DYLD_FRAMEWORK_PATH="$platform/Developer/Library/Frameworks:$platform/Developer/Library/PrivateFrameworks" \
  DYLD_LIBRARY_PATH="$platform/Developer/usr/lib" \
  DYLD_INSERT_LIBRARIES="$library" \
  NARROW_POOL_SAMPLE_DIR="$run" \
  DIRECTA_TEST_TEMP_ROOT="$temp_root" \
    "$helper" --test-bundle-path "$bundle" "$@" "$bundle" --testing-library swift-testing 2>&1 | tee "$log"
  test_status=${pipestatus[1]}
  (( test_status == 0 )) || result=1
  if (( test_status == 139 )); then
    echo "error: the test process crashed (exit 139) in ${bundle:t}; a crash inside the narrow-pool watcher shows up as a swiftpm-testing-helper crash report in ~/Library/Logs/DiagnosticReports" >&2
  fi

  if ! grep -q '^\[narrow-pool\] cooperative pool narrowed' "$log"; then
    echo "error: the pool was never narrowed for ${bundle:t} (the library did not load into the test process)" >&2
    result=1
  fi
  if grep -q '^\[narrow-pool\] BLOCKED:' "$log"; then
    echo "--- blocked pool threads in ${bundle:t}, demangled ---" >&2
    grep '^\[narrow-pool\]' "$log" | xcrun swift-demangle --simplified >&2
    echo "error: a cooperative-pool thread was blocked; the stacks above, and full samples in $run/blocked-*.txt" >&2
    echo "fix: move the blocking call off the pool (a BlockingLane in product code, offPool in a test; Tests/DirectaTestSupport/OffPool.swift)" >&2
    result=1
  fi
  echo "run log: $log"
done
rm -rf "$temp_root"
exit $result
