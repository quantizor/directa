#!/bin/zsh
# Measures the CPU the running daemon (ddirecta) and menu bar app (directa-app)
# spend over a window, for a before-and-after figure on any change to what
# either does while idle.
#
# Usage: scripts/idle-cpu.sh [seconds]
#   seconds defaults to 300. Prints one key=value line:
#     window daemon_cpu_s daemon_core_pct app_cpu_s app_core_pct running_servers load_start load_end
#   *_core_pct is CPU seconds over the measured wall seconds, as a percent of
#   one core. running_servers counts servers with a live process (what
#   ServerPhase.hasLiveRun counts: running, starting, unhealthy, stopping, or
#   failed with a pid) from `directa status --all --json`; the script fails
#   when directa or jq is unavailable or the status read fails. It counts
#   servers, not processes: helper subprocesses the daemon spawns (git, lsof,
#   launchctl) are not included.
#   load_* is the 1-minute load average before and after the window.
#
# Overrides: IDLE_CPU_DAEMON_NAME and IDLE_CPU_APP_NAME name the processes
# (default ddirecta and directa-app), matched exactly as process names.
#
# Fails (non-zero, with the fix) when a process is absent or ambiguous, when a
# CPU read comes back empty or unparseable (including a process that exits
# during the window), or when the running-server count cannot be read. CPU
# comes from `ps -o time=`, which has 10 ms resolution, so use a window of at
# least 20 s.
set -euo pipefail
zmodload zsh/datetime

DAEMON_NAME="${IDLE_CPU_DAEMON_NAME:-ddirecta}"
APP_NAME="${IDLE_CPU_APP_NAME:-directa-app}"
WINDOW="${1:-300}"

fail() { echo "idle-cpu: $1" >&2; exit 1 }

[[ "$WINDOW" =~ '^[0-9]+$' ]] && (( WINDOW > 0 )) || fail "window must be a whole number of seconds, got '$WINDOW'; run: scripts/idle-cpu.sh 300"

# Prints the one pid of a process named exactly $1, else fails naming the fix.
find_pid() {
  local name=$1 fix=$2
  local -a pids
  pids=(${(f)"$(pgrep -x -- "$name" || true)"})
  (( ${#pids} == 1 )) || fail "expected one process named $name, found ${#pids}${pids:+ (pids: ${pids[*]})}; $fix"
  print -r -- "${pids[1]}"
}

# Prints cumulative CPU seconds for a pid from `ps -o time=`, which reports
# [[d-]hh:]mm:ss[.cc].
cpu_seconds() {
  local pid=$1 name=$2 raw
  raw=$(ps -o time= -p "$pid" 2>/dev/null | tr -d ' ') || true
  [[ -n "$raw" ]] || fail "ps returned no CPU time for $name (pid $pid); it exited or is not readable, so start it and rerun"
  print -r -- "$raw" | awk -F'[-:]' -v name="$name" '
    NF == 2 { print $1 * 60 + $2; ok = 1 }
    NF == 3 { print $1 * 3600 + $2 * 60 + $3; ok = 1 }
    NF == 4 { print $1 * 86400 + $2 * 3600 + $3 * 60 + $4; ok = 1 }
    END { if (!ok) { print "idle-cpu: cannot parse CPU time for " name > "/dev/stderr"; exit 1 } }'
}

load_average() { sysctl -n vm.loadavg | awk '{ print $2 }' }

# The jq select mirrors ServerPhase.hasLiveRun(pid:) in
# Sources/DirectaKit/Model/Models.swift (isActive, or failed with a pid); change
# both together.
running_servers() {
  command -v directa >/dev/null || fail "directa is not on PATH, so running_servers cannot be read; install it (make install) or add its directory to PATH"
  command -v jq >/dev/null || fail "jq is not on PATH, so running_servers cannot be read; run: brew install jq"
  local out
  out=$(directa status --all --json 2>/dev/null | jq '[.servers[] | select(.phase == "running" or .phase == "starting" or .phase == "unhealthy" or .phase == "stopping" or (.phase == "failed" and .pid != null))] | length' 2>/dev/null) || out=""
  [[ "$out" =~ '^[0-9]+$' ]] || fail "could not read the running server count from 'directa status --all --json'; start the daemon with: directa daemon start, then rerun"
  print -r -- "$out"
}

daemon_pid=$(find_pid "$DAEMON_NAME" "start the daemon with: directa daemon start")
app_pid=$(find_pid "$APP_NAME" "launch directa.app, then rerun")

running_servers >/dev/null # fail before the window, not after it

daemon_start=$(cpu_seconds "$daemon_pid" "$DAEMON_NAME")
app_start=$(cpu_seconds "$app_pid" "$APP_NAME")
load_start=$(load_average)
began=$EPOCHREALTIME

sleep "$WINDOW"

daemon_end=$(cpu_seconds "$daemon_pid" "$DAEMON_NAME")
app_end=$(cpu_seconds "$app_pid" "$APP_NAME")
load_end=$(load_average)
elapsed=$(( EPOCHREALTIME - began ))
servers=$(running_servers)

awk -v elapsed="$elapsed" -v ds="$daemon_start" -v de="$daemon_end" -v as="$app_start" -v ae="$app_end" \
  -v ls="$load_start" -v le="$load_end" -v servers="$servers" 'BEGIN {
  d = de - ds; a = ae - as
  printf "window=%.1fs daemon_cpu_s=%.2f daemon_core_pct=%.2f app_cpu_s=%.2f app_core_pct=%.2f", elapsed, d, d / elapsed * 100, a, a / elapsed * 100
  printf " running_servers=%s load_start=%s load_end=%s\n", servers, ls, le
}'
