#!/bin/zsh
# Phase 1 smoke gate: real ddirecta + real CLI + real fixture-server.
# Asserts: registration, start, status, spool capture, whole-group death on stop,
# and child survival across a daemon kill (spool-fd capture, no SIGPIPE).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/debug"
WORK="$(mktemp -d /tmp/directa-smoke.XXXXXX)"
export DIRECTA_SOCKET="$WORK/daemon.sock"
PROJECT="$WORK/project"
mkdir -p "$PROJECT"

# The daemon's log lives under $WORK, which the exit trap deletes, so a failure
# has to carry the tail out with it or the one record of what the daemon was
# doing is gone by the time anyone reads the failure.
fail() {
  echo "SMOKE FAIL: $1" >&2
  if [[ -s "${DAEMON_LOG:-}" ]]; then
    echo "--- last daemon output ($DAEMON_LOG) ---" >&2
    tail -20 "$DAEMON_LOG" >&2
  fi
  exit 1
}
pass() { echo "  ok: $1" }

# Wait until the daemon ANSWERS OVER THE SOCKET AND HAS FINISHED RESTORING,
# never until the socket file merely exists. Three traps this avoids, all of
# which report ready for the wrong reason: a daemon killed with -9 leaves its
# socket file behind, so a file test passes instantly against a dead listener;
# `daemon status` falls back to launchd state and exits 0 without connecting, so
# it answers even when nothing is listening; and the daemon now accepts before
# boot restore finishes, so `reachable` alone would let the next command race a
# half-restored daemon and get refused. Fails loudly rather than letting a later
# command report a confusing error.
# `probe`, not `status`: zsh makes $status a read-only alias for $?, so assigning
# to it aborts the script mid-function with a message that reads like a directa
# failure rather than a naming collision.
await_daemon() {
  local label="$1" probe
  for i in {1..100}; do
    probe="$("$BIN/directa" daemon status --json 2>/dev/null || true)"
    if grep -q '"reachable":true' <<<"$probe" && ! grep -q '"restoring":true' <<<"$probe"; then
      return 0
    fi
    sleep 0.1
  done
  fail "daemon never finished restoring over $DIRECTA_SOCKET ($label); last status: ${probe:-<none>}"
}

cleanup() {
  [[ -n "${DAEMON_PID:-}" ]] && kill -9 "$DAEMON_PID" 2>/dev/null || true
  [[ -n "${CHILD_PID:-}" ]] && kill -9 "-$CHILD_PID" 2>/dev/null || true
  # Grandchildren escape the process group on purpose (that is what the teardown
  # assertions exercise), so a group kill leaves them behind. Reap them by pid.
  for stray in ${STRAY_PIDS:-}; do kill -9 "$stray" 2>/dev/null || true; done
  # Every `directa monitor` invocation started for the monitor checks below is
  # tracked here too, so a `fail` partway through that section (which exits and
  # runs this trap) cannot leave one running past this script.
  for mon in ${MONITOR_PIDS:-}; do kill -9 "$mon" 2>/dev/null || true; done
  # Orphans from a mid-smoke abort can hold fixed listen ports across reruns.
  pkill -f "$BIN/fixture-server" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "building..."
swift build --package-path "$ROOT" > /dev/null

# The daemon's own stdio goes to a file, never to this script's. Inheriting it
# means a daemon that outlives the run holds the write end of the caller's pipe
# open, so `smoke.sh | anything` never sees EOF and hangs long after the script
# itself has exited, showing no output at all to say why.
DAEMON_LOG="$WORK/ddirecta.log"
echo "starting daemon... (log: $DAEMON_LOG)"
"$BIN/ddirecta" --foreground --socket "$DIRECTA_SOCKET" --data-dir "$WORK/data" --logs-dir "$WORK/logs" \
  >>"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!
await_daemon "first boot"
pass "daemon up (pid $DAEMON_PID)"

cd "$PROJECT"
DIRECTA="$BIN/directa"

"$DIRECTA" register --name web --cmd "$BIN/fixture-server" --cmd --spawn-grandchild --json > /dev/null
pass "register"

START_JSON="$("$DIRECTA" start web --json)"
CHILD_PID="$(echo "$START_JSON" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["server"]["pid"])')"
[[ "$CHILD_PID" -gt 0 ]] || fail "no pid from start"
pass "start (child pid $CHILD_PID)"

sleep 1
SPOOL="$(echo "$START_JSON" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["server"]["logPath"])')"
grep -q heartbeat "$SPOOL" || fail "spool has no heartbeats"
grep -q grandchild "$SPOOL" || fail "fixture never spawned its grandchild"
GRANDCHILD_PID="$(grep grandchild "$SPOOL" | head -1 | awk '{print $NF}')"
pass "spool capturing output (grandchild pid $GRANDCHILD_PID)"

"$DIRECTA" wait web --healthy --timeout 10 --json > /dev/null || fail "wait --healthy did not resolve"
PHASE="$("$DIRECTA" status web --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["phase"])')"
[[ "$PHASE" == "running" ]] || fail "status phase was $PHASE, wanted running"
pass "wait --healthy resolved; status reports running"

# ensure is idempotent: same pid back, no reason.
ENSURE_PID="$("$DIRECTA" ensure web --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["server"]["pid"])')"
[[ "$ENSURE_PID" == "$CHILD_PID" ]] || fail "ensure respawned a healthy server ($CHILD_PID -> $ENSURE_PID)"
pass "ensure no-op on healthy server"

# Cross-project port conflict: a second project declaring the same port must be refused.
PROJECT2="$WORK/project2"
mkdir -p "$PROJECT2"
TCP_PORT=$((39000 + (RANDOM % 500)))
"$DIRECTA" register --name tcp --cmd "$BIN/fixture-server" --cmd --listen-tcp --cmd "$TCP_PORT" --port "$TCP_PORT" --json > /dev/null
"$DIRECTA" ensure tcp --timeout 10 --json > /dev/null || fail "tcp fixture never became healthy"
pass "tcp healthcheck (port $TCP_PORT)"
cd "$PROJECT2"
"$DIRECTA" register --name rival --cmd /bin/sleep --cmd 30 --port "$TCP_PORT" --json > /dev/null
set +e
RIVAL_OUT="$("$DIRECTA" ensure rival --timeout 5 --json 2>/dev/null)"
RIVAL_EXIT=$?
set -e
[[ "$RIVAL_EXIT" -ne 0 ]] || fail "rival ensure should have failed on held port"
echo "$RIVAL_OUT" | grep -q "port-held" || fail "rival error was not port-held: $RIVAL_OUT"
pass "cross-project port conflict refused (port-held)"
cd "$PROJECT"
"$DIRECTA" stop tcp --json > /dev/null

# Phase 3: marks, since-mark queries, events, why.
MARK_ID="$("$DIRECTA" mark web "smoke correlation point" --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["marks"][0]["id"])')"
[[ -n "$MARK_ID" ]] || fail "mark returned no id"
sleep 0.5
AFTER_COUNT="$("$DIRECTA" logs web --since-mark "$MARK_ID" --stream out --json | wc -l | tr -d ' ')"
[[ "$AFTER_COUNT" -ge 1 ]] || fail "no out lines after mark"
"$DIRECTA" logs web --grep "heartbeat" --tail 3 --json > /dev/null || fail "grep query failed"
pass "mark + since-mark + grep queries ($AFTER_COUNT lines since mark)"

"$DIRECTA" events --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert any(e["kind"]=="started" for e in d["events"]), d' || fail "events feed missing started"
pass "events feed records lifecycle"

WHY_OUT="$("$DIRECTA" why web)"
echo "$WHY_OUT" | grep -q "running and healthy" || fail "why did not report healthy: $WHY_OUT"
pass "why reports healthy chain"

"$DIRECTA" stop web --json > /dev/null
kill -0 "$CHILD_PID" 2>/dev/null && fail "child survived stop"
kill -0 "$GRANDCHILD_PID" 2>/dev/null && fail "grandchild survived stop: group-kill failed"
pass "stop killed the whole process group"

# Daemon-death survival: start again, kill the daemon, the child must keep
# running and keep writing to its spool (no SIGPIPE from dead pipes).
"$DIRECTA" start web --json > /dev/null
CHILD_PID="$("$DIRECTA" status web --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["pid"])')"
kill -9 "$DAEMON_PID"
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=""
sleep 1
kill -0 "$CHILD_PID" 2>/dev/null || fail "child died with the daemon"
# The child writes its raw spool directly; the structured log resumes when a
# daemon returns. Survival is judged on the raw spool.
RAW_SPOOL="$(dirname "$SPOOL")/out.spool"
BEFORE="$(wc -l < "$RAW_SPOOL")"
sleep 1
AFTER="$(wc -l < "$RAW_SPOOL")"
[[ "$AFTER" -gt "$BEFORE" ]] || fail "raw spool stopped growing after daemon death"
pass "child survived daemon kill and kept logging ($BEFORE -> $AFTER raw lines)"
STRAY_PIDS="${STRAY_PIDS:-} $(grep grandchild "$RAW_SPOOL" | tail -1 | awk '{print $NF}')"
kill -9 "-$CHILD_PID" 2>/dev/null || true
CHILD_PID=""

# Phase 5: a real devservers.json project with dependencies, trust, up/down.
PROJECT3="$WORK/project3"
mkdir -p "$PROJECT3"
P3_DB=$((41000 + (RANDOM % 500)))
P3_WEB=$((P3_DB + 1))
cat > "$PROJECT3/devservers.json" <<CFG
{
  "version": 1,
  "host": "smoketest.localhost",
  "servers": {
    "db": { "command": ["$BIN/fixture-server", "--listen-tcp", "$P3_DB"], "port": $P3_DB },
    "web": { "command": ["$BIN/fixture-server", "--listen-tcp", "$P3_WEB"], "dependsOn": ["db"], "heads": { "admin": "/admin" }, "port": $P3_WEB }
  }
}
CFG
# restart the smoke daemon (killed above) for the project phase
"$BIN/ddirecta" --foreground --socket "$DIRECTA_SOCKET" --data-dir "$WORK/data" --logs-dir "$WORK/logs" \
  >>"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!
# The claim under test: from the moment the listener accepts, a client gets an
# answer. Boot restore used to run with the socket unlinked, so a client in that
# window got ENOENT and reported the daemon gone, which is exactly what a daemon
# that never started looks like. Waiting on the socket FILE is the correct gate
# here and only here, because its creation IS the moment accept begins; every
# other wait in this script goes through await_daemon for the reasons above it.
for i in {1..200}; do [[ -S "$DIRECTA_SOCKET" ]] && break; sleep 0.05; done
[[ -S "$DIRECTA_SOCKET" ]] || fail "daemon never created its socket"
RESTORE_PROBE="$("$DIRECTA" daemon status --json 2>/dev/null || true)"
grep -q '"restoring":true' <<<"$RESTORE_PROBE" && RESTORE_WINDOW="observed" || RESTORE_WINDOW="already finished"
if ! RESTORE_OUT="$(cd "$PROJECT" && "$DIRECTA" status --json 2>/dev/null)"; then
  fail "a command during boot restore failed instead of waiting it out: $RESTORE_OUT"
fi
grep -q 'daemon-unreachable' <<<"$RESTORE_OUT" && fail "a restoring daemon reported itself unreachable: $RESTORE_OUT"
# Says which of the two ran, because an assertion that silently skipped the
# window it exists to cover reads identically to one that passed through it.
pass "a command racing boot restore waits instead of reporting the daemon gone (window $RESTORE_WINDOW)"
await_daemon "project phase restart"
cd "$PROJECT3"

"$DIRECTA" config check --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["errors"]==[], d; assert d["host"]=="smoketest.localhost", d' || fail "config check"
pass "config check validates devservers.json"

set +e
UP_OUT="$("$DIRECTA" up --timeout 15 --json 2>/tmp/directa-smoke-up.err)"
UP_EXIT=$?
set -e
[[ "$UP_EXIT" -eq 0 ]] || fail "up exit $UP_EXIT: $UP_OUT $(cat /tmp/directa-smoke-up.err 2>/dev/null)"
echo "$UP_OUT" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert all(r.get("reason") is None for r in d["results"]), d; assert len(d["results"])==2, d' || fail "up did not bring both servers healthy: $UP_OUT"
pass "up brings the project healthy in dependency order"

"$DIRECTA" status web --json | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin)['servers'][0]; assert d['url']=='http://smoketest.localhost:$P3_WEB/', d" || fail "derived url wrong"
pass "host signature url derived"

# A root-relative head must resolve against the server's own base, not serialize
# as `//:port/admin`, which reads as a URL everywhere it lands and works nowhere.
"$DIRECTA" status web --json | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin)['servers'][0]; assert d['heads']['admin']=='http://smoketest.localhost:$P3_WEB/admin', d" || fail "relative head did not resolve against the server base"
pass "relative head resolves against the server base"

# The same mistake on a server with no base to resolve against is caught while it
# is still cheap, rather than shipping a broken URL to every heads consumer.
BADHEAD="$WORK/badhead"
mkdir -p "$BADHEAD"
cat > "$BADHEAD/devservers.json" <<'CFG'
{ "version": 1, "servers": { "web": { "command": ["true"], "heads": { "admin": "/admin" } } } }
CFG
set +e
"$DIRECTA" config check --project "$BADHEAD" --json > "$WORK/badhead.json" 2>/dev/null
BADHEAD_EXIT=$?
set -e
[[ "$BADHEAD_EXIT" -ne 0 ]] || fail "config check accepted an unresolvable head"
/usr/bin/python3 -c "import json;d=json.load(open('$WORK/badhead.json'));assert any('head' in e and 'resolve it against' in e for e in d['errors']), d" || fail "config check did not explain the unresolvable head"
pass "config check rejects an unresolvable head"

# devservers.json is routinely gitignored per machine, so the daemon has to be
# able to write one back. What it writes must pass its own validator.
RECOVER="$WORK/recover"
mkdir -p "$RECOVER"
R_PORT=$((42500 + (RANDOM % 300)))
"$DIRECTA" register --project "$RECOVER" --name recovered --cmd "$BIN/fixture-server" --cmd --listen-tcp --cmd "$R_PORT" --port "$R_PORT" --json > /dev/null || fail "register for recovery"
"$DIRECTA" config init --project "$RECOVER" --json > "$WORK/init.json" || fail "config init"
/usr/bin/python3 -c "import json;d=json.load(open('$WORK/init.json'));assert d['written'] is True, d; assert d['check']['servers']==['recovered'], d; assert '\n  ' in d['content'], 'file should be indented'" || fail "config init result"
[[ -f "$RECOVER/devservers.json" ]] || fail "config init wrote no file"
"$DIRECTA" config check --project "$RECOVER" --json | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); assert d['errors']==[], d; assert d['servers']==['recovered'], d" || fail "recovered config does not validate"
pass "config init writes a file its own validator accepts"

set +e
"$DIRECTA" config init --project "$RECOVER" --json > "$WORK/init2.json" 2>/dev/null
INIT2_EXIT=$?
set -e
[[ "$INIT2_EXIT" -ne 0 ]] || fail "config init clobbered an existing file"
/usr/bin/python3 -c "import json;d=json.load(open('$WORK/init2.json'));assert d['error']['code']=='already-exists', d" || fail "config init did not refuse with already-exists"
"$DIRECTA" config init --project "$RECOVER" --force --json > /dev/null || fail "config init --force"
pass "config init refuses to clobber without --force"

# register --write must add one entry and leave the rest of the file alone.
"$DIRECTA" register --project "$RECOVER" --name second --cmd "$BIN/fixture-server" --port $((R_PORT + 1)) --write --json > /dev/null || fail "register --write"
/usr/bin/python3 -c "import json;d=json.load(open('$RECOVER/devservers.json'));assert sorted(d['servers'])==['recovered','second'], d" || fail "register --write lost an entry"
pass "register --write appends without disturbing the rest"

"$DIRECTA" status --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("trusted") is True, d' || fail "project not trusted after up"
pass "trust recorded by explicit up"

"$DIRECTA" down --json > /dev/null
"$DIRECTA" status --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert all(s["phase"]=="stopped" for s in d["servers"]), d' || fail "down left servers running"
pass "down stops the project"

# Derived error facts + agent context safety: a crasher writes distinctively
# tagged stderr, then dies. directa must count those lines (its own arithmetic)
# and inject a `directa why` command, while never leaking the raw child bytes
# into the context block the session hook feeds an agent.
PROJECT_CRASH="$WORK/project-crash"
mkdir -p "$PROJECT_CRASH"
cat > "$PROJECT_CRASH/devservers.json" <<CFG
{
  "version": 1,
  "host": "crash.localhost",
  "servers": {
    "flaky": { "command": ["$BIN/fixture-server", "--err-lines", "3", "--exit-after", "0.4", "--code", "1"] }
  }
}
CFG
cd "$PROJECT_CRASH"
set +e
"$DIRECTA" ensure flaky --timeout 5 --json > /dev/null 2>&1
set -e
# Poll for the terminal phase; the fixture exits shortly after start.
for i in {1..50}; do
  CRASH_PHASE="$("$DIRECTA" status flaky --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["phase"])')"
  [[ "$CRASH_PHASE" == "crashed" ]] && break
  sleep 0.1
done
[[ "$CRASH_PHASE" == "crashed" ]] || fail "crasher never reached crashed (was $CRASH_PHASE)"
"$DIRECTA" status flaky --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["servers"][0]; s=d.get("errorSummary"); assert s and s["count"]>=3, d' || fail "errorSummary did not count the stderr lines"
pass "status carries a derived error count"

CONTEXT_OUT="$("$DIRECTA" context)"
echo "$CONTEXT_OUT" | grep -q "run: directa why flaky --json" || fail "context omitted the why recommendation: $CONTEXT_OUT"
echo "$CONTEXT_OUT" | grep -q "error line" || fail "context omitted the error count line: $CONTEXT_OUT"
if echo "$CONTEXT_OUT" | grep -q "FIXTURE-ERR-TOKEN"; then
  fail "SECURITY: raw child stderr leaked into the agent context block"
fi
pass "context recommends directa why and never leaks raw child output"
cd "$PROJECT3"

# Resource locks: db declares the resource; lock --pause stops it, refuses ensure, resumes after.
/usr/bin/python3 - "$PROJECT3/devservers.json" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["servers"]["db"]["locks"] = ["data"]
json.dump(cfg, open(p, "w"))
PY
"$DIRECTA" up --timeout 15 --json > /dev/null || fail "up before lock test"
LOCK_OUT="$("$DIRECTA" lock data --pause -- sh -c "sleep 1; $DIRECTA status db --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)[\"servers\"][0]; assert d[\"phase\"]==\"stopped\", d[\"phase\"]' && $DIRECTA ensure db --timeout 3 --json > /dev/null 2>&1 && exit 44 || exit 0")"
LOCK_EXIT=$?
[[ "$LOCK_EXIT" -eq 0 ]] || fail "lock run failed ($LOCK_EXIT): db not paused or ensure not refused"
PHASE_AFTER="$("$DIRECTA" wait db --healthy --timeout 15 --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["server"]["phase"])')"
[[ "$PHASE_AFTER" == "running" ]] || fail "db did not resume after lock (phase $PHASE_AFTER)"
pass "resource lock --pause stops holder, refuses ensure, resumes after"

# Stopping a server to get exclusive access to something it holds is the heavy
# way there. The hint says so in human mode and stays out of --json stdout,
# which carries the machine-readable `locks` array instead.
"$DIRECTA" stop db 2>"$WORK/stop.err" >/dev/null || fail "stop db"
grep -q "directa lock data --" "$WORK/stop.err" || fail "stop did not hint toward lock: $(cat "$WORK/stop.err")"
"$DIRECTA" ensure db --timeout 15 --json > /dev/null || fail "re-ensure db"
"$DIRECTA" stop db --json > "$WORK/stop.json" 2>/dev/null || fail "stop db --json"
/usr/bin/python3 -c "import json;d=json.load(open('$WORK/stop.json'));assert d['server']['locks']==['data'], d" || fail "stop --json lost the locks array"
grep -q "hint:" "$WORK/stop.json" && fail "stop --json leaked the hint into stdout"
pass "stop hints toward lock in human mode and keeps --json stdout clean"

# lock runs the guarded command in the CALLER's own working directory, never
# the resolved project root: a relative file argument or a config-discovery
# tool must see what it would running unwrapped. `pwd -P` matches what the
# child's getcwd(2) reports, so the comparison tolerates no symlink drift.
mkdir -p "$PROJECT3/sub"
EXPECTED_SUBDIR="$(cd "$PROJECT3/sub" && pwd -P)"
(cd "$PROJECT3/sub" && "$DIRECTA" lock data -- sh -c "pwd -P > '$WORK/lock-cwd.txt'") \
  || fail "lock cwd check failed to run"
SEEN_SUBDIR="$(cat "$WORK/lock-cwd.txt")"
[[ "$SEEN_SUBDIR" == "$EXPECTED_SUBDIR" ]] \
  || fail "lock ran the guarded command outside the caller's cwd: expected $EXPECTED_SUBDIR, got $SEEN_SUBDIR"
pass "lock runs the guarded command in the caller's own working directory"

"$DIRECTA" down --json > /dev/null

# Deep-link and default/`--pause` lock coverage stay below; worktree coexistence first.

# Sibling worktree coexistence: shared git common-dir auto-rebinds the linked
# checkout onto a free port while main keeps the declared origin, and the host
# stays the declared one everywhere (origin-pinned app config keeps working;
# the worktree name surfaces as a display value). Fixture listens on {port} so
# materialization is load-bearing.
WT_ROOT="$WORK/wt-coexist"
mkdir -p "$WT_ROOT/main"
cd "$WT_ROOT/main"
git init -b main >/dev/null
git config user.email "smoke@directa.test"
git config user.name "directa-smoke"
echo ok > README
git add README
git commit -m init >/dev/null
mkdir -p "$WT_ROOT/worktrees"
git worktree add -b review "$WT_ROOT/worktrees/review" >/dev/null
WT_PORT=$((52000 + (RANDOM % 1000)))
cat > "$WT_ROOT/main/devservers.json" <<CFG
{
  "host": "smoke.localhost",
  "servers": {
    "web": {
      "command": ["$BIN/fixture-server", "--listen-tcp", "{port}"],
      "healthcheck": { "type": "tcp", "port": $WT_PORT },
      "port": $WT_PORT,
      "url": "http://smoke.localhost:$WT_PORT/"
    }
  },
  "version": 1
}
CFG
cp "$WT_ROOT/main/devservers.json" "$WT_ROOT/worktrees/review/devservers.json"
cd "$WT_ROOT/main"
set +e
MAIN_ENSURE="$("$DIRECTA" ensure web --timeout 15 --json 2>/tmp/directa-smoke-main-ensure.err)"
MAIN_ENSURE_EXIT=$?
set -e
[[ "$MAIN_ENSURE_EXIT" -eq 0 ]] || fail "main worktree ensure exit $MAIN_ENSURE_EXIT: $MAIN_ENSURE $(cat /tmp/directa-smoke-main-ensure.err 2>/dev/null)"
echo "$MAIN_ENSURE" | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin)['server']; assert d['phase']=='running', d; assert d.get('effectivePort')==$WT_PORT, d; assert d['url']=='http://smoke.localhost:$WT_PORT/', d; assert d.get('portConflict') is None, d" || fail "main worktree ensure: $MAIN_ENSURE"
pass "main checkout keeps declared host and port"
cd "$WT_ROOT/worktrees/review"
set +e
WT_ENSURE="$("$DIRECTA" ensure web --timeout 15 --json 2>/tmp/directa-smoke-wt-ensure.err)"
WT_ENSURE_EXIT=$?
set -e
[[ "$WT_ENSURE_EXIT" -eq 0 ]] || fail "linked worktree ensure exit $WT_ENSURE_EXIT: $WT_ENSURE $(cat /tmp/directa-smoke-wt-ensure.err 2>/dev/null)"
echo "$WT_ENSURE" | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin)['server']; assert d['phase']=='running', d; assert d.get('effectivePort')!=$WT_PORT, d; assert d.get('portConflict',{}).get('state')=='rebound', d; assert d.get('worktree')=='review', d; assert d.get('url')=='http://smoke.localhost:'+str(d.get('effectivePort'))+'/', d" || fail "linked worktree ensure: $WT_ENSURE"
pass "linked worktree auto-rebinds and keeps the declared host"
CTX="$("$DIRECTA" context)"
echo "$CTX" | grep -q 'worktree "review"' || fail "context omitted the worktree label: $CTX"
echo "$CTX" | grep -q "smoke.localhost" || fail "context omitted the live URL: $CTX"
pass "worktree context advertises the label and the live URL"
"$DIRECTA" stop web --json > /dev/null
cd "$WT_ROOT/main"
"$DIRECTA" stop web --json > /dev/null
"$DIRECTA" unregister web --json > /dev/null || true
cd "$WT_ROOT/worktrees/review"
"$DIRECTA" unregister web --json > /dev/null || true
pass "worktree coexistence cleaned up"

# switch trust: the explicit invocation is the approval, recorded before the
# branch's lifecycle argv runs. The project has no servers, so nothing but the
# pre-lifecycle record could have marked it trusted, and the marker file proves
# the playbook ran at all.
SWITCH_ROOT="$WORK/switch-project"
mkdir -p "$SWITCH_ROOT"
cd "$SWITCH_ROOT"
git init -b main >/dev/null
git config user.email "[EMAIL]"
git config user.name "directa-smoke"
cat > devservers.json <<'CFG'
{
  "version": 1,
  "host": "switchtest.localhost",
  "servers": {},
  "lifecycle": { "switch": [["/usr/bin/touch", ".directa-switch-ran"]] }
}
CFG
git add devservers.json
git commit -m init >/dev/null
"$DIRECTA" switch main > "$WORK/switch.out" 2>&1 || fail "switch exit: $(cat "$WORK/switch.out")"
[[ -f .directa-switch-ran ]] || fail "switch lifecycle playbook did not run: $(cat "$WORK/switch.out")"
"$DIRECTA" status --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("trusted") is True, d' || fail "switch did not record trust before running lifecycle"
pass "switch records trust before lifecycle runs"

# --project takes a directory, not a project name: a name lands on a
# nonexistent relative path, which used to answer an empty scoped view and let
# a stop report success against a phantom project while the real server kept
# running.
cd "$SWITCH_ROOT"
set +e
"$DIRECTA" down --project directa-no-such-project --json > "$WORK/phantom.json" 2>/dev/null
PHANTOM_EXIT=$?
set -e
[[ "$PHANTOM_EXIT" -eq 2 ]] || fail "phantom --project exit $PHANTOM_EXIT (expected usage 2): $(cat "$WORK/phantom.json" 2>/dev/null)"
/usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["ok"] is False and d["error"]["code"]=="usage", d' "$WORK/phantom.json" || fail "phantom --project error shape: $(cat "$WORK/phantom.json")"
pass "--project name-as-path is refused instead of phantom success"

# lock (default): holder stays up while the lock is held.
cd "$PROJECT3"
"$DIRECTA" up --timeout 15 --json > /dev/null || fail "up before default-hold test"
DEFAULT_HOLD_STATUS="$WORK/default-hold-status.json"
set +e
"$DIRECTA" lock data -- "$DIRECTA" status db --json > "$DEFAULT_HOLD_STATUS" 2>"$WORK/default-hold.err"
DEFAULT_HOLD_EXIT=$?
set -e
[[ "$DEFAULT_HOLD_EXIT" -eq 0 ]] || fail "default lock hold failed ($DEFAULT_HOLD_EXIT): $(head -c 400 "$DEFAULT_HOLD_STATUS" 2>/dev/null) $(cat "$WORK/default-hold.err" 2>/dev/null)"
# stdout belongs to the guarded command: lock's own chatter is on stderr, so
# this parses as plain JSON with nothing filtered out.
DEFAULT_HOLD_PHASE="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["servers"][0]["phase"])' "$DEFAULT_HOLD_STATUS")"
[[ "$DEFAULT_HOLD_PHASE" == "running" ]] || fail "default lock hold stopped db (phase $DEFAULT_HOLD_PHASE; out=$(cat "$DEFAULT_HOLD_STATUS"))"
# The lock is bare-named (no state path), so the default hold cannot fingerprint
# the change and must warn on stderr that the corruption guard is off.
grep -q "declares no state path" "$WORK/default-hold.err" || fail "default hold over an unguarded lock did not warn: $(cat "$WORK/default-hold.err")"
pass "lock leaves declarer running by default and warns when it cannot guard the state"

# The parse defect: lock's own options after the resource joined the guarded
# command, so `env --timeout 20 -- sh` died with `env: illegal option -- t`.
"$DIRECTA" lock data --timeout 20 -- sh -c 'exit 0' 2>/dev/null || fail "lock leaked its own options into the guarded command"
pass "lock options before -- do not reach the guarded command"

# A contended acquire has to name the holder rather than sit silent, and the
# fail-fast form must return at once instead of waiting out the budget.
# The guarded command marks the file once it is actually running, so the checks
# below synchronize on the hold rather than racing a sleep.
rm -f "$WORK/held"
"$DIRECTA" lock data -- sh -c "touch '$WORK/held'; sleep 6" >/dev/null 2>&1 &
HOLDER_JOB=$!
for _ in $(seq 1 100); do
  [[ -f "$WORK/held" ]] && break
  /bin/sleep 0.1
done
[[ -f "$WORK/held" ]] || fail "lock holder never started"
FAST_START=$SECONDS
set +e
"$DIRECTA" lock data --acquire-timeout 0 --json -- true > "$WORK/lockfast.json" 2>/dev/null
FAST_EXIT=$?
set -e
FAST_ELAPSED=$((SECONDS - FAST_START))
[[ "$FAST_EXIT" -ne 0 ]] || fail "--acquire-timeout 0 acquired a held lock"
[[ "$FAST_ELAPSED" -lt 3 ]] || fail "--acquire-timeout 0 waited ${FAST_ELAPSED}s instead of failing fast"
/usr/bin/python3 -c "import json;d=json.load(open('$WORK/lockfast.json'));assert d['error']['code']=='resource-locked', d" || fail "fail-fast lock lost its error code"
set +e
"$DIRECTA" lock data --acquire-timeout 20 -- true 2>"$WORK/contended.err" >/dev/null
CONTENDED_EXIT=$?
set -e
wait $HOLDER_JOB 2>/dev/null || true
[[ "$CONTENDED_EXIT" -eq 0 ]] || fail "contended lock never acquired ($CONTENDED_EXIT): $(cat "$WORK/contended.err")"
grep -qE "is held by pid [0-9]+" "$WORK/contended.err" || fail "contended lock waited silently: $(cat "$WORK/contended.err")"
grep -q "waiting up to" "$WORK/contended.err" || fail "contended lock did not say the wait is bounded"
pass "contended lock names the holder and bounds the wait"

# The silent-clobber incident: a command that changes the locked state while a
# declaring server is still up cannot be distinguished from a clean run. Declare
# where the state lives (the object form of `locks`, alongside the bare string
# form asserted above) and the change is reported.
mkdir -p "$PROJECT3/state"
echo v1 > "$PROJECT3/state/db.sqlite"
/usr/bin/python3 - "$PROJECT3/devservers.json" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["servers"]["db"]["locks"] = [{"name": "data", "path": "state"}]
json.dump(cfg, open(p, "w"))
PY
"$DIRECTA" up --timeout 15 --json > /dev/null || fail "up before identity checks"

# --pause mode: declarers stopped, so the change is the point: a note on stderr, exit 0.
"$DIRECTA" lock data --pause -- sh -c 'echo v2 > state/db.sqlite' 2>"$WORK/note.err" >/dev/null || fail "paused-mode lock failed"
grep -qE "note: 'data' state at .* changed" "$WORK/note.err" || fail "paused-mode change was not noted: $(cat "$WORK/note.err")"
pass "a change under a --pause lock is reported as a note"

# Default hold with a live declarer: the server holds the old state open, so this
# is a loud failure rather than a silent success.
set +e
"$DIRECTA" lock data --json -- sh -c 'rm -rf state && mkdir state && echo v3 > state/db.sqlite' > "$WORK/mutated.json" 2>/dev/null
MUTATED_EXIT=$?
set -e
[[ "$MUTATED_EXIT" -ne 0 ]] || fail "default hold accepted a command that replaced the locked state"
/usr/bin/python3 -c "import json;d=json.load(open('$WORK/mutated.json'));assert d['error']['code']=='resource-mutated', d; assert d['error']['hint']=='directa lock data --pause -- <command>', d" || fail "resource-mutated envelope wrong: $(cat "$WORK/mutated.json")"
pass "a default-hold command over changed state fails loudly with resource-mutated"

# And an untouched resource stays quiet, so the check cannot fire on everything.
"$DIRECTA" lock data -- true 2>"$WORK/quiet.err" >/dev/null || fail "default hold over untouched state failed"
[[ ! -s "$WORK/quiet.err" ]] || fail "default hold over untouched state was noisy: $(cat "$WORK/quiet.err")"
pass "an untouched locked resource stays silent"

# restart is one daemon-side transition: a client-side stop-then-ensure takes the
# server down and only then discovers a refusal, leaving it down.
"$DIRECTA" up --timeout 15 --json > /dev/null || fail "up before restart"
RESTART_PID_BEFORE="$("$DIRECTA" status db --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["pid"])')"
"$DIRECTA" restart db --timeout 15 --json > "$WORK/restart.json" || fail "restart db"
/usr/bin/python3 -c "import json;d=json.load(open('$WORK/restart.json'));s=d['results'][0]['server'];assert s['phase']=='running', d; assert s['pid']!=$RESTART_PID_BEFORE, d" || fail "restart did not replace the process"
pass "restart replaces the process and comes back healthy"

set +e
"$DIRECTA" lock data -- "$DIRECTA" restart db --timeout 5 --json > "$WORK/restart-locked.json" 2>/dev/null
set -e
/usr/bin/python3 -c "import json;d=json.load(open('$WORK/restart-locked.json'));assert d['error']['code']=='resource-locked', d" || fail "restart under a live lock was not refused"
"$DIRECTA" status db --json | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["servers"][0]; assert d["phase"]=="running", d' || fail "a refused restart left the server down"
pass "restart under a live lock is refused and the server stays up"

"$DIRECTA" down --json > /dev/null

# Restarting a flooding server: the stop's final log drain runs long, and the
# restart's ensure must wait for the phase to leave stopping rather than spin.
# The daemon itself, not just the restarted server, has to survive this.
FLOODPROJ="$WORK/floodproj"
mkdir -p "$FLOODPROJ"
cd "$FLOODPROJ"
FLOOD_PORT=$((44000 + (RANDOM % 500)))
"$DIRECTA" register --name flood --cmd "$BIN/fixture-server" --cmd --listen-tcp --cmd "$FLOOD_PORT" --cmd --flood --port "$FLOOD_PORT" --json > /dev/null
"$DIRECTA" ensure flood --timeout 10 --json > /dev/null || fail "flooding fixture never became healthy"
sleep 1
"$DIRECTA" restart flood --timeout 15 --json > "$WORK/flood-restart.json" || fail "restart of a flooding server did not complete"
/usr/bin/python3 -c "import json;d=json.load(open('$WORK/flood-restart.json'));s=d['results'][0]['server'];assert s['phase']=='running', d" || fail "flooding server did not come back running: $(cat "$WORK/flood-restart.json")"
kill -0 "$DAEMON_PID" 2>/dev/null || fail "daemon (pid $DAEMON_PID) died restarting a flooding server"
pass "restarting a flooding server completes and the daemon (pid $DAEMON_PID) stays up"
"$DIRECTA" stop flood --json > /dev/null

# directa monitor: a client-side polling loop over logs.query/server.status
# shaped for an agent's own streaming tool. Every check below runs against
# this script's own temp daemon/socket, never a live one.
MONPROJ="$WORK/monitor-project"
mkdir -p "$MONPROJ"
cd "$MONPROJ"
"$DIRECTA" register --name monweb --cmd "$BIN/fixture-server" --json > /dev/null
"$DIRECTA" ensure monweb --timeout 10 --json > /dev/null || fail "monitor fixture never became healthy"

MON_OUT="$WORK/monitor-out.log"
"$DIRECTA" monitor monweb --tick 0.5 > "$MON_OUT" 2>/dev/null &
MON_PID=$!
MONITOR_PIDS="${MONITOR_PIDS:-} $MON_PID"
for i in {1..50}; do grep -q "^directa monweb: monitoring" "$MON_OUT" && break; sleep 0.1; done
grep -q "^directa monweb: monitoring" "$MON_OUT" || fail "monitor never printed its start marker"
for i in {1..30}; do grep -q "monweb out| heartbeat" "$MON_OUT" && break; sleep 0.1; done
grep -q "monweb out| heartbeat" "$MON_OUT" || fail "monitor never showed a line through the pipe within a tick"
pass "monitor shows a line through a pipe within one tick"
kill -9 "$MON_PID" 2>/dev/null || true
wait "$MON_PID" 2>/dev/null || true

# Lifecycle survives an over-cap burst, and RSS stays bounded under a flood
# at max budget flags. One 20 s run covers both: a restart 2 s in exercises
# the lifecycle lines, then 18 s of RSS sampling.
# The RSS ceiling was set by measuring this exact scenario: peak observed
# while writing this check was ~12 MB (11.6-12.1 MB), settling near 11.5 MB;
# 40 MB leaves wide headroom while still catching a real leak, since nothing
# in the design accumulates for the life of a run (a fixed-size LRU, bounded
# token-bucket budgets, one query and at most one status call per tick).
"$DIRECTA" register --name monflood --cmd "$BIN/fixture-server" --cmd --flood --json > /dev/null
"$DIRECTA" ensure monflood --timeout 10 --json > /dev/null || fail "flooding fixture for monitor never became healthy"
FLOOD_MON_OUT="$WORK/monitor-flood.log"
"$DIRECTA" monitor monflood --tick 0.5 --lines-per-minute 1200 --lines-per-arm 20000 \
  --errors-per-minute 600 --errors-per-arm 5000 > "$FLOOD_MON_OUT" 2>/dev/null &
FLOOD_MON_PID=$!
MONITOR_PIDS="${MONITOR_PIDS:-} $FLOOD_MON_PID"
sleep 2
"$DIRECTA" restart monflood --timeout 15 --json > /dev/null || fail "restart under a flooding monitor failed"
MON_RSS_CEILING_KB=40000
MAX_RSS=0
for i in $(seq 1 18); do
  RSS="$(ps -o rss= -p "$FLOOD_MON_PID" 2>/dev/null | tr -d ' ')"
  [[ -n "$RSS" ]] || fail "monitor process died during the flood RSS check"
  [[ "$RSS" -gt "$MAX_RSS" ]] && MAX_RSS="$RSS"
  sleep 1
done
kill -9 "$FLOOD_MON_PID" 2>/dev/null || true
wait "$FLOOD_MON_PID" 2>/dev/null || true
grep -q "stopping: requested by restart" "$FLOOD_MON_OUT" || fail "lifecycle 'stopping' line lost inside an over-cap burst"
grep -q "started pid=" "$FLOOD_MON_OUT" || fail "lifecycle 'started' line lost inside an over-cap burst"
pass "lifecycle lines survive an over-cap flood burst across a restart"
[[ "$MAX_RSS" -le "$MON_RSS_CEILING_KB" ]] || fail "monitor RSS peaked at ${MAX_RSS}KB under flood, over the ${MON_RSS_CEILING_KB}KB ceiling"
pass "monitor RSS stays under ${MON_RSS_CEILING_KB}KB (peaked ${MAX_RSS}KB) through a flood at max budget flags"
"$DIRECTA" stop monflood --json > /dev/null 2>&1 || true
"$DIRECTA" unregister monflood --json > /dev/null 2>&1 || true

# Daemon kill and restart keeps streaming: the client's persistent connection
# goes unreachable across the kill, reports it once, and resumes once the
# daemon (restored from the same registry/data dirs) answers again.
KEEP_OUT="$WORK/monitor-keepalive.log"
"$DIRECTA" monitor monweb --tick 0.5 > "$KEEP_OUT" 2>/dev/null &
KEEP_MON_PID=$!
MONITOR_PIDS="${MONITOR_PIDS:-} $KEEP_MON_PID"
for i in {1..30}; do grep -q "monweb out| heartbeat" "$KEEP_OUT" && break; sleep 0.1; done
grep -q "monweb out| heartbeat" "$KEEP_OUT" || fail "monitor never streamed before the daemon kill"
BEFORE_LINES="$(wc -l < "$KEEP_OUT" | tr -d ' ')"
kill -9 "$DAEMON_PID"
wait "$DAEMON_PID" 2>/dev/null || true
"$BIN/ddirecta" --foreground --socket "$DIRECTA_SOCKET" --data-dir "$WORK/data" --logs-dir "$WORK/logs" \
  >>"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!
await_daemon "monitor daemon-kill recovery"
AFTER_LINES="$BEFORE_LINES"
for i in {1..50}; do
  AFTER_LINES="$(wc -l < "$KEEP_OUT" | tr -d ' ')"
  [[ "$AFTER_LINES" -gt "$BEFORE_LINES" ]] && break
  sleep 0.2
done
[[ "$AFTER_LINES" -gt "$BEFORE_LINES" ]] || fail "monitor did not resume streaming after the daemon restarted"
grep -q "the daemon is unreachable, retrying" "$KEEP_OUT" || fail "monitor never reported the daemon as unreachable across the kill"
pass "monitor survives a daemon kill and restart, resuming with a transient line ($BEFORE_LINES -> $AFTER_LINES lines)"
kill -9 "$KEEP_MON_PID" 2>/dev/null || true
wait "$KEEP_MON_PID" 2>/dev/null || true

# Linked-worktree cwd: a worktree under <repo>/.claude/worktrees/ attaches to
# its OWN server while a same-named main-checkout server keeps running, with
# a distinct label.
MON_WT_ROOT="$WORK/monitor-wt"
mkdir -p "$MON_WT_ROOT/main"
cd "$MON_WT_ROOT/main"
git init -b main >/dev/null
git config user.email "smoke@directa.test"
git config user.name "directa-smoke"
echo ok > README
git add README
git commit -m init >/dev/null
mkdir -p "$MON_WT_ROOT/main/.claude/worktrees"
git worktree add -b review "$MON_WT_ROOT/main/.claude/worktrees/review" >/dev/null
MON_WT_PORT=$((49000 + (RANDOM % 400)))
cat > "$MON_WT_ROOT/main/devservers.json" <<CFG
{
  "host": "monitorwt.localhost",
  "servers": {
    "web": {
      "command": ["$BIN/fixture-server", "--listen-tcp", "{port}"],
      "healthcheck": { "type": "tcp", "port": $MON_WT_PORT },
      "port": $MON_WT_PORT
    }
  },
  "version": 1
}
CFG
cp "$MON_WT_ROOT/main/devservers.json" "$MON_WT_ROOT/main/.claude/worktrees/review/devservers.json"
"$DIRECTA" ensure web --timeout 15 --json > /dev/null || fail "monitor worktree main ensure failed"
cd "$MON_WT_ROOT/main/.claude/worktrees/review"
"$DIRECTA" ensure web --timeout 15 --json > /dev/null || fail "monitor worktree review ensure failed"
WT_MON_OUT="$WORK/monitor-wt.log"
"$DIRECTA" monitor web --tick 1 > "$WT_MON_OUT" 2>/dev/null &
WT_MON_PID=$!
MONITOR_PIDS="${MONITOR_PIDS:-} $WT_MON_PID"
for i in {1..30}; do grep -q "^directa web@review: monitoring" "$WT_MON_OUT" && break; sleep 0.1; done
grep -q "^directa web@review: monitoring" "$WT_MON_OUT" || fail "monitor from a linked worktree cwd did not attach with the @review label: $(head -3 "$WT_MON_OUT" 2>/dev/null)"
pass "monitor from a linked-worktree cwd attaches to that worktree's server with a distinct label"
kill -9 "$WT_MON_PID" 2>/dev/null || true
wait "$WT_MON_PID" 2>/dev/null || true

# --project overrides cwd.
cd "$MONPROJ"
PROJ_OVERRIDE_OUT="$WORK/monitor-project-override.log"
# directa canonicalizes the project path (resolving /tmp -> /private/tmp);
# pwd -P matches that so the comparison below is exact, not a near-miss.
MON_WT_MAIN_CANONICAL="$(cd "$MON_WT_ROOT/main" && pwd -P)"
"$DIRECTA" monitor web --project "$MON_WT_ROOT/main" --tick 1 > "$PROJ_OVERRIDE_OUT" 2>/dev/null &
PROJ_OVERRIDE_PID=$!
MONITOR_PIDS="${MONITOR_PIDS:-} $PROJ_OVERRIDE_PID"
for i in {1..30}; do grep -q "^directa web: monitoring $MON_WT_MAIN_CANONICAL" "$PROJ_OVERRIDE_OUT" && break; sleep 0.1; done
grep -q "^directa web: monitoring $MON_WT_MAIN_CANONICAL" "$PROJ_OVERRIDE_OUT" || fail "--project did not override cwd for monitor: $(head -3 "$PROJ_OVERRIDE_OUT" 2>/dev/null)"
pass "--project overrides cwd for monitor"
kill -9 "$PROJ_OVERRIDE_PID" 2>/dev/null || true
wait "$PROJ_OVERRIDE_PID" 2>/dev/null || true
cd "$MON_WT_ROOT/main"
"$DIRECTA" stop web --json > /dev/null 2>&1 || true
cd "$MON_WT_ROOT/main/.claude/worktrees/review"
"$DIRECTA" stop web --json > /dev/null 2>&1 || true

# Reader-gone exit: the pipe's read end closes after 1 s, well inside the 2 s
# budget; polls for the real `directa monitor` process (a child of the
# pipeline below, not this job's own pid) so the timing is measured against
# the process whose lifetime is actually under test.
cd "$MONPROJ"
READER_START=$SECONDS
"$DIRECTA" monitor monweb | ( sleep 1; exit 0 ) &
READER_MON_PID=""
for i in {1..30}; do
  READER_MON_PID="$(pgrep -f "$BIN/directa monitor monweb" | head -1)"
  [[ -n "$READER_MON_PID" ]] && break
  sleep 0.05
done
[[ -n "$READER_MON_PID" ]] || fail "reader-gone check never saw the monitor process start"
MONITOR_PIDS="${MONITOR_PIDS:-} $READER_MON_PID"
for i in {1..30}; do
  kill -0 "$READER_MON_PID" 2>/dev/null || break
  sleep 0.1
done
READER_ELAPSED=$((SECONDS - READER_START))
kill -0 "$READER_MON_PID" 2>/dev/null && fail "monitor did not exit within 2 s of its reader closing (still alive after ${READER_ELAPSED}s)"
[[ "$READER_ELAPSED" -le 2 ]] || fail "monitor took ${READER_ELAPSED}s to exit after its reader closed, wanted <= 2s"
pass "monitor exits within 2 s once its stdout reader is gone"

# One poll per tick, and idle CPU, both over a quiet server (no flood
# processing overhead to skew either number): DIRECTA_MONITOR_DEBUG=1 prints
# one stderr line per logs.query call (documented at its callsite in
# MonitorCommand.swift), so 20 s at --tick 0.5 is nominally 40; negligible
# cumulative CPU time over the same real wall-clock window means the loop is
# sleeping between ticks (and the lifetime watcher blocking in the kernel),
# not spinning.
IDLE_OUT="$WORK/monitor-idle.log"
IDLE_DEBUG="$WORK/monitor-idle-debug.log"
DIRECTA_MONITOR_DEBUG=1 "$DIRECTA" monitor monweb --tick 0.5 > "$IDLE_OUT" 2>"$IDLE_DEBUG" &
IDLE_MON_PID=$!
MONITOR_PIDS="${MONITOR_PIDS:-} $IDLE_MON_PID"
sleep 20
IDLE_TIME_RAW="$(ps -o time= -p "$IDLE_MON_PID" | tr -d ' ')"
kill -9 "$IDLE_MON_PID" 2>/dev/null || true
wait "$IDLE_MON_PID" 2>/dev/null || true
[[ -n "$IDLE_TIME_RAW" ]] || fail "could not read monitor's CPU time"
IDLE_UNDER_ONE_SECOND=$(awk -F: -v t="$IDLE_TIME_RAW" 'BEGIN{n=split(t,a,":"); s=0; for(i=1;i<=n;i++) s=s*60+a[i]; print (s<1.0)?1:0}')
[[ "$IDLE_UNDER_ONE_SECOND" -eq 1 ]] || fail "monitor used ${IDLE_TIME_RAW} of CPU over 20 idle seconds, wanted well under 1s"
pass "monitor stays near-idle (<1s CPU) over 20 s attached to a quiet server"
POLL_COUNT="$(wc -l < "$IDLE_DEBUG" | tr -d ' ')"
[[ "$POLL_COUNT" -ge 34 && "$POLL_COUNT" -le 44 ]] || fail "expected ~40 polls over 20s at --tick 0.5 against a quiet server, got $POLL_COUNT"
pass "one poll per tick over 20 s at --tick 0.5 ($POLL_COUNT polls)"

cd "$MONPROJ"
"$DIRECTA" stop monweb --json > /dev/null 2>&1 || true

# watch: a config the server reads at boot changes, and the server comes back
# having read it. The pid moving is not the point; the new value in the log is.
WATCHP="$WORK/watchproj"
mkdir -p "$WATCHP"
echo v1 > "$WATCHP/app.config.json"
W_PORT=$((43100 + (RANDOM % 300)))
cat > "$WATCHP/devservers.json" <<CFG
{
  "version": 1,
  "host": "watchsmoke.localhost",
  "servers": {
    "web": {
      "command": ["$BIN/fixture-server", "--listen-tcp", "$W_PORT", "--print-file", "$WATCHP/app.config.json"],
      "healthcheck": { "type": "tcp", "port": $W_PORT },
      "port": $W_PORT,
      "watch": ["app.config.json"]
    }
  }
}
CFG
cd "$WATCHP"
"$DIRECTA" ensure web --timeout 15 --json > /dev/null || fail "ensure watch server"
# --all: the default 200-line tail could plausibly miss the boot-time config
# line by the time this asserts, given the fixture's 200ms heartbeat plus the
# restart loop below piling up lines ahead of it.
"$DIRECTA" logs web --all --json | grep -q "config: v1" || fail "watch fixture never read its config"
W_PID_BEFORE="$("$DIRECTA" status web --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["pid"])')"
# The baseline is taken once the run has been alive for the settle window, which
# is what stops a server that writes its own config during boot from bouncing
# itself. Editing before then is folded into the baseline by design, so wait it
# out rather than racing it.
/bin/sleep 3
echo v2 > "$WATCHP/app.config.json"
for _ in $(seq 1 80); do
  W_PID_NOW="$("$DIRECTA" status web --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0].get("pid"))' 2>/dev/null || echo none)"
  [[ "$W_PID_NOW" != "$W_PID_BEFORE" && "$W_PID_NOW" != "none" && "$W_PID_NOW" != "None" ]] && break
  /bin/sleep 0.25
done
[[ "$W_PID_NOW" != "$W_PID_BEFORE" ]] || fail "a watched file changed and the server never restarted (status: $("$DIRECTA" status web --json 2>&1 | head -c 400))"
"$DIRECTA" wait web --healthy --timeout 15 --json > /dev/null || fail "watch restart never became healthy"
"$DIRECTA" logs web --all --json | grep -q "config: v2" || fail "the restarted server did not read the new config"
pass "a watched file change restarts the server and it reads the new config"

# A server that declares no watch must behave exactly as before.
cd "$PROJECT3"
"$DIRECTA" up --timeout 15 --json > /dev/null || fail "up for the no-watch check"
NOWATCH_PID="$("$DIRECTA" status db --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["pid"])')"
echo changed > "$PROJECT3/state/db.sqlite"
/bin/sleep 2
"$DIRECTA" status db --json | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin)['servers'][0]; assert d['pid']==$NOWATCH_PID, d" || fail "a server with no watch was restarted"
pass "a server that declares no watch is left alone"
"$DIRECTA" down --json > /dev/null
cd "$WATCHP"
"$DIRECTA" stop web --json > /dev/null 2>&1 || true
cd "$PROJECT3"
"$DIRECTA" down --json > /dev/null

# Deep links: print URL + dispatch via x-url (no Launch Services).
cd "$PROJECT"
SLUG="$(basename "$PROJECT")"
LINK_URL="$("$DIRECTA" link ensure web)"
[[ "$LINK_URL" == "directa://ensure/${SLUG}/web" ]] || fail "link ensure printed '$LINK_URL'"
pass "link prints canonical URL ($LINK_URL)"
"$DIRECTA" x-url "$LINK_URL" --json > /dev/null || fail "x-url ensure failed"
"$DIRECTA" wait web --healthy --timeout 15 --json > /dev/null || fail "x-url ensure never healthy"
pass "x-url ensure"
"$DIRECTA" x-url "directa://stop/${SLUG}/web" --json > /dev/null || fail "x-url stop failed"
PHASE_STOP="$("$DIRECTA" status web --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["servers"][0]["phase"])')"
[[ "$PHASE_STOP" == "stopped" ]] || fail "x-url stop left phase $PHASE_STOP"
pass "x-url stop"
"$DIRECTA" x-url "directa://why/${SLUG}/web" --json > /dev/null || fail "x-url why failed"
pass "x-url why"
set +e
BAD_OUT="$("$DIRECTA" x-url 'directa://ensure/no-such-slug/web' --json 2>/dev/null)"
BAD_EXIT=$?
set -e
[[ "$BAD_EXIT" -ne 0 ]] || fail "x-url unknown slug should fail"
echo "$BAD_OUT" | grep -Eq 'not-found|"ok":false' || fail "x-url bad slug envelope: $BAD_OUT"
pass "x-url rejects unknown slug"

# Bundle advertises the custom URL scheme and ships CLI + daemon for first-run.
# Ad-hoc on purpose: the gate asserts layout and never installs this bundle, so
# it needs no signing identity and wants no warning about lacking one.
DIRECTA_ADHOC_EXPECTED=1 "$ROOT/scripts/make-app-bundle.sh" - debug
SCHEME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$ROOT/directa.app/Contents/Info.plist")"
[[ "$SCHEME" == "directa" ]] || fail "assembled Info.plist scheme was '$SCHEME'"
pass "assembled app declares CFBundleURLSchemes=directa"
ICON="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$ROOT/directa.app/Contents/Info.plist")"
[[ "$ICON" == "AppIcon" ]] || fail "assembled Info.plist CFBundleIconFile was '$ICON'"
[[ -f "$ROOT/directa.app/Contents/Resources/AppIcon.icns" ]] || fail "bundle missing Resources/AppIcon.icns"
pass "assembled app ships AppIcon.icns"
DISPLAY="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$ROOT/directa.app/Contents/Info.plist")"
[[ "$DISPLAY" == "quantizor/directa" ]] || fail "assembled Info.plist CFBundleDisplayName was '$DISPLAY'"
pass "assembled app display name is quantizor/directa"
COPYRIGHT="$(/usr/libexec/PlistBuddy -c 'Print :NSHumanReadableCopyright' "$ROOT/directa.app/Contents/Info.plist")"
[[ "$COPYRIGHT" == "Copyright © 2026 Evan Jacobs" ]] || fail "assembled Info.plist NSHumanReadableCopyright was '$COPYRIGHT'"
pass "assembled app copyright is set for the About panel"
ROLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleTypeRole' "$ROOT/directa.app/Contents/Info.plist")"
[[ "$ROLE" == "Editor" ]] || fail "assembled Info.plist CFBundleTypeRole was '$ROLE'"
pass "assembled app URL type role is Editor"
TAL="$(/usr/libexec/PlistBuddy -c 'Print :NSSupportsAutomaticTermination' "$ROOT/directa.app/Contents/Info.plist")"
[[ "$TAL" == "false" ]] || fail "assembled Info.plist NSSupportsAutomaticTermination was '$TAL'"
SUDDEN="$(/usr/libexec/PlistBuddy -c 'Print :NSSupportsSuddenTermination' "$ROOT/directa.app/Contents/Info.plist")"
[[ "$SUDDEN" == "false" ]] || fail "assembled Info.plist NSSupportsSuddenTermination was '$SUDDEN'"
pass "assembled app opts out of automatic and sudden termination"
[[ -x "$ROOT/directa.app/Contents/Resources/directa" ]] || fail "bundle missing Resources/directa"
[[ -x "$ROOT/directa.app/Contents/Resources/ddirecta" ]] || fail "bundle missing Resources/ddirecta"
pass "assembled app ships CLI and daemon in Resources"
[[ -x "$ROOT/directa.app/Contents/Helpers/ddirecta" ]] || fail "bundle missing Helpers/ddirecta"
AGENT_PLIST="$ROOT/directa.app/Contents/Library/LaunchAgents/dev.quantizor.directa.plist"
[[ -f "$AGENT_PLIST" ]] || fail "bundle missing Library/LaunchAgents/dev.quantizor.directa.plist"
BUNDLE_PROG="$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$AGENT_PLIST")"
[[ "$BUNDLE_PROG" == "Contents/Helpers/ddirecta" ]] || fail "BundleProgram was '$BUNDLE_PROG'"
# launchd caps ExitTimeOut at 60 and logs a complaint above it.
AGENT_EXIT_TIMEOUT="$(/usr/libexec/PlistBuddy -c 'Print :ExitTimeOut' "$AGENT_PLIST")"
[[ "$AGENT_EXIT_TIMEOUT" -le 60 ]] || fail "ExitTimeOut was '$AGENT_EXIT_TIMEOUT'; launchd caps it at 60"
pass "assembled app ships Helpers/ddirecta + in-bundle LaunchAgent"

# The app's own KeepAlive agent: same bundle-layout shape as the daemon's, but
# BundleProgram points at the app binary itself and there is no PATH floor to
# check (the app never spawns dev servers).
APP_AGENT_PLIST="$ROOT/directa.app/Contents/Library/LaunchAgents/dev.quantizor.directa.app.plist"
[[ -f "$APP_AGENT_PLIST" ]] || fail "bundle missing Library/LaunchAgents/dev.quantizor.directa.app.plist"
APP_BUNDLE_PROG="$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$APP_AGENT_PLIST")"
[[ "$APP_BUNDLE_PROG" == "Contents/MacOS/directa-app" ]] || fail "app agent BundleProgram was '$APP_BUNDLE_PROG'"
APP_KEEPALIVE="$(/usr/libexec/PlistBuddy -c 'Print :KeepAlive:SuccessfulExit' "$APP_AGENT_PLIST")"
[[ "$APP_KEEPALIVE" == "false" ]] || fail "app agent KeepAlive:SuccessfulExit was '$APP_KEEPALIVE'"
pass "assembled app ships its own KeepAlive LaunchAgent (dev.quantizor.directa.app)"

kill -9 "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=""

echo "SMOKE PASS"
