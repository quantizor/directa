#!/bin/zsh
# Summarizes every daemon death recorded in the boot incident files that
# ddirecta writes (one per boot, docs/macos-lifecycle.md "Daemon telemetry").
#
# Usage: scripts/daemon-deaths.sh [incidents-dir]
#   incidents-dir defaults to $DIRECTA_INCIDENTS_DIR, else
#   ~/Library/Logs/directa/daemon/incidents.
#
# A death is an incident whose previous run left telemetry and did not end
# with its clean-exit mark. Clean exits and first boots are counted, not
# summarized. Fails loudly on a missing or empty directory, a missing jq, or
# a file with no incident header; prints nothing but the summaries otherwise.
# Lines that are not JSON are skipped, since the copied telemetry can end in a
# line the kill tore in half.
#
# Blind spots: the time of death is bounded by the previous run's last
# telemetry line (at most one sampling interval earlier than the kill), and
# kernel lines appear only if `log show` still held them at boot.
set -euo pipefail

JQ=/usr/bin/jq
[[ -x "$JQ" ]] || { echo "daemon-deaths: $JQ not found; macOS 15 or later ships it" >&2; exit 2 }

DIR="${1:-${DIRECTA_INCIDENTS_DIR:-$HOME/Library/Logs/directa/daemon/incidents}}"
[[ -d "$DIR" ]] || { echo "daemon-deaths: no incidents directory at $DIR" >&2; exit 1 }

FILES=("$DIR"/*.ndjson(N))
(( ${#FILES} > 0 )) || { echo "daemon-deaths: no incident files (*.ndjson) in $DIR" >&2; exit 1 }

SUMMARY_PROGRAM='
def ts: (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)
  + ((try capture("\\.(?<f>[0-9]+)Z$").f catch "0") | ("0." + .) | tonumber);
def clock: sub("^[0-9-]+T"; "") | sub("Z$"; "");
def mb: . / 1048576 | . * 10 | round / 10;
def secs: . * 10 | round / 10;
def orNone(f): if length == 0 then "    none" else map(f) | join("\n") end;

(map(select(.entry == "incident")) | first) as $h
| if $h == null then error("no incident header line") else . end
| (map(select(.entry == "snapshot" or .entry == "mark"))) as $prev
| (map(select(.entry == "system-log"))) as $logs
| (map(select(.entry == "diagnostic-report"))) as $reports
| (map(select(.entry == "search-finished")) | first) as $search
| ($h.previousLastLineAt // null) as $lastAt
| ($prev | map(select(.entry == "snapshot"))) as $snaps
| ($prev | map(select(.entry == "mark"))) as $marks
| (if $lastAt then ($lastAt | ts) else null end) as $lastT
| ($snaps | map(select($lastT != null and ((.time | ts) >= $lastT - 60)))) as $final
| ($final | max_by(.threads.total // 0)) as $peak
| ($snaps | last) as $lastSnap
| ($marks | map(select(.event == "stop-began" or .event == "restart-began")) | last) as $lastStop
| [
  "== death before boot \($h.time) (previous pid \($h.previousPid // "?"), new pid \($h.daemonPid))",
  "  last telemetry line: \($lastAt // "none") (\($h.gapSeconds // "?")s before boot)",
  (if $h.launchd then
     "  launchd: exit code \($h.launchd.exitCode // "-"), signal \($h.launchd.terminatingSignal // "-"), exit reason \($h.launchd.exitReason // "-"), immediate reason \($h.launchd.immediateReason // "-"), runs \($h.launchd.runs // "-")",
     ($h.launchd.rawLines | map(select(startswith("last "))) | map("    " + .) | join("\n"))
   else "  launchd: \($h.launchdNote // "no record")" end),
  (if $search == null then "  system log: search never finished (daemon died again, or still running)"
   else "  system log: \($search.outcome), \($search.matches) matching lines\(if $search.logShowSeconds then ", \($search.logShowSeconds)s" else "" end)\(if $search.windowStart then ", window \($search.windowStart | clock) to \($search.windowEnd | clock)" else "" end)"
   end),
  ($logs | .[0:20] | orNone("    \(.time | clock) \(.process): \(.message | .[0:240])")),
  "  diagnostic reports:",
  ($reports | orNone("    \(.path)\n      \((.excerpt // "(no entry for the daemon)") | .[0:400])")),
  (if $lastStop == null then "  last stop or restart: none in the copied telemetry"
   else
     ($marks | map(select((.event == "stop-ended" or .event == "restart-ended") and .label == $lastStop.label and ((.time | ts) >= ($lastStop.time | ts)))) | first) as $end
     | "  last \($lastStop.event | sub("-began"; "")) began \((($lastT // ($lastStop.time | ts)) - ($lastStop.time | ts)) | secs)s before the last line: \($lastStop.label)\n    \(if $end then "ended \($end.outcome // "?") after \($end.seconds)s" else "never ended before the death" end)"
   end),
  (if $peak == null then "  final 60s: no snapshots"
   else
     "  final 60s: peak \($peak.threads.total) threads (limit \($peak.threads.limit // "unknown")) at \($peak.time | clock), workqueue \($peak.threads.workqueue.total // "?") total / \($peak.threads.workqueue.blocked // "?") blocked / \($peak.threads.workqueue.running // "?") running, limits hit \($peak.threads.workqueue.limitsExceeded // [] | if length == 0 then "none" else join(",") end)",
     "    by name: \($peak.threads.byName | to_entries | sort_by(-.value) | map("\(.key)=\(.value)") | join(", "))",
     "    by state: \($peak.threads.byState | to_entries | map("\(.key)=\(.value)") | join(", "))",
     "  final 60s memory: footprint peak \($final | map(.memory.footprint // 0) | max | mb) MB (last \($lastSnap.memory.footprint // 0 | mb) MB, lifetime peak \($lastSnap.memory.footprintLifetimePeak // 0 | mb) MB), compressed peak \($final | map(.memory.compressed // 0) | max | mb) MB, fds peak \($final | map(.fileDescriptors // 0) | max), pressure \($lastSnap.system.memoryPressure // "?")"
   end),
  ([$final[] | .lanes // [] | .[]] | group_by(.name)
   | if length == 0 then "  final 60s lanes: no lane data"
     else "  final 60s lanes: " + (map("\(.[0].name) (width \(.[0].width)) peak queued \(map(.queued) | max), peak running \(map(.running) | max), longest queue wait \(map(.oldestQueuedSeconds) | max)s") | join("; "))
     end),
  (if $lastSnap == null then "  in flight at last snapshot: no snapshots"
   else
     "  lanes at last snapshot: \($lastSnap.lanes // [] | if length == 0 then "none recorded" else map("\(.name) \(.running)/\(.width) running, \(.queued) queued, oldest \(.oldestQueuedSeconds)s") | join("; ") end)",
     "  in flight at last snapshot (\($lastSnap.time | clock), \($lastSnap.activity.connectedClients) clients, \($lastSnap.exitWatches) exit watches):",
     ($lastSnap.activity.longestRunning | orNone("    \(.kind) \(.seconds)s \(.label)"))
   end),
  "  last marks:",
  ($marks | .[-10:] | orNone("    \(.time | clock) \(.event)\(if .kind then " " + .kind else "" end)\(if .seconds then " " + (.seconds | tostring) + "s" else "" end) \(.label // "")\(if .outcome then " -> " + .outcome else "" end)"))
]
| join("\n")
'

deaths=0
clean=0
first_boot=0
for file in "${FILES[@]}"; do
  kind=$("$JQ" -Rnr '[inputs | fromjson?] | map(select(.entry == "incident")) | first
    | if . == null then "invalid"
      elif .previousExitedCleanly then "clean"
      elif (.previousLineCount // 0) == 0 then "first"
      else "death" end' "$file") \
    || { echo "daemon-deaths: cannot parse $file" >&2; exit 1 }
  case "$kind" in
    death)
      (( deaths > 0 )) && print
      "$JQ" -Rnr "[inputs | fromjson?] | $SUMMARY_PROGRAM" "$file" \
        || { echo "daemon-deaths: cannot summarize $file" >&2; exit 1 }
      print "  file: $file"
      (( ++deaths ))
      ;;
    clean) (( ++clean )) ;;
    first) (( ++first_boot )) ;;
    *) echo "daemon-deaths: $file has no incident header line" >&2; exit 1 ;;
  esac
done

(( deaths > 0 )) && print
print "$deaths deaths, $clean clean exits, $first_boot boots with no previous telemetry, in ${#FILES} incident files under $DIR"
