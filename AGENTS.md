directa

Charter: this file holds only one-line rules that prevent a recurring defect class (each naming its guardrail or depth doc), everyday commands, and a map of every doc and module. Everything else lives in a named home in this repo: a spec, docs/architecture.md, docs/standards/, or a script's header. Never narration, history, backlog, drifting figures, code trivia an agent can grep, or a second copy of a fact homed elsewhere. A misplaced line moves home in the change that finds it, leaving the rule and a pointer.

An agent-friendly coordinator for many devservers and their unique configurations. A macOS menu bar app and CLI over a launchd-supervised daemon, built so coding agents never lose track of running servers across compaction and session boundaries. All Swift, no Xcode.

Docs
- docs/design.md: design rationale, config model, and daemon internals (teardown, output capture, boot recovery); a ratified plan snapshot that keeps the old devctl names and predates later deviations, so this file and the contract win where they disagree
- docs/cli-contract.md: the CLI JSON contract and every command's behavior
- docs/macos-lifecycle.md: macOS process, launchd, SMAppService, jetsam, DMG, and daemon telemetry notes
- docs/releasing.md: release, signing, notarization, DMG, and the Homebrew cask bump
- docs/architecture.md: the codebase map in depth, the reasoning behind each command, and the mechanism behind each invariant below
- docs/standards/testing.md: test targets, the one-home test helpers, and how to measure coverage
- CONTRIBUTING.md: commit and changeset hygiene with examples, adding a harness adapter, release secrets
- .changeset/README.md: writing a changeset
- README.md: install, quick start, environment variables
- BACKLOG.md: open work, maintainer-local and gitignored (a fresh clone does not have it; a contributor without it reports a deficiency as a GitHub issue)

Identity and stack
- Apple silicon on macOS 26+ is the only compatibility constraint (Package.swift platforms, the bundle's LSMinimumSystemVersion, and the cask's depends_on move together); releases are arm64-only by decision, so no universal build. The toolchain is whatever Xcode builds for it (CI: the macos-26 runner's default); swift-tools-version 6.2, Swift 6 language mode with strict concurrency, single SPM package.
- Isolation is set per target in Package.swift: .defaultIsolation(nil) everywhere except DirectaApp, which is .defaultIsolation(MainActor.self).
- Deps (exactly two): swift-argument-parser (CLI only) and swift-subprocess (daemon only; pre-1.0, revision-pinned, isolated behind the ProcessLauncher protocol so a posix_spawn fallback can swap in without touching callers). The revision pin is load-bearing; do not loosen it.
- Three products, one daemon: ddirecta owns all server processes; directa (CLI) and directa.app (SwiftUI MenuBarExtra) are thin clients over a unix socket (default ~/Library/Application Support/directa/daemon.sock; DIRECTA_SOCKET overrides; /tmp fallback near the sun_path limit), NDJSON protocol. directa daemon install/uninstall/start/stop/restart manage the LaunchAgent (dev.quantizor.directa); tests and the smoke gate run ddirecta --foreground.

Codebase map (depth: docs/architecture.md)
- Sources/DirectaKit: shared core, the unit-test target of record.
  - Model/Models.swift: specs, phases, ServerStatus. displayPort is the one home for which port field a human sees; ServerPhase.hasLiveRun(pid:) (surfaced as ServerStatus.hasLiveRun) for whether a process is alive; ServerStatus.heldPorts(claim:) for which ports a server holds. ServerSpec.validationErrors screens a registered spec like a committed one.
  - Protocol/Wire.swift: JSONCoding, typed request/response/event frames, NDJSON framing, stable error codes.
  - Client/DaemonClient.swift: the socket client actor the CLI and app share.
  - Paths/Paths.swift: path constants, canonical project path, AtomicFile, SHA-256. agent.path holds the daemon's login-shell PATH.
  - Concurrency/BlockingLane.swift: the one home for work that blocks its thread. Lanes: `repository` (git), `health` (healthcheck connects), `system` (launchctl, lsof, ps, the port pre-check's loopback probes). Each blocking helper has an async overload that hops onto its lane.
  - Process/: CoalitionIDs and ProcessUniqueIDs (proc_pidinfo readouts, both through readProcInfo); HelperCommand, the one home for running a helper command (git, launchctl, lsof, ps, a shell profile) under a deadline and output cap, answering the typed ShellOutcome.
  - Setup/: SetupPlanner (first-run and upgrade decisions), CLIOwner (directa vs Homebrew ownership), AppInstancePolicy (which of two copies quits at launch), InstallShadow.
  - Agent/: AgentContext (the session-context renderer the hook injects), DiscoveryStanza.
  - Harness/: HarnessAdapter and the per-harness adapters, HookPayload and HookPayloadGate, HookChange and HookSnapshotStore. Adding a harness: CONTRIBUTING.md.
  - Monitor/MonitorStream.swift: the pure shaper behind `directa monitor`. MonitorLimits is the one home for every monitor tunable and its hard ceiling.
  - Shell/ShellWord.swift: the one home for putting a value into a command a reader pastes.
  - Spotlight/SpotlightLabel; Net/: LoopbackProbe, PortClaim + PortMaterializer, SiblingRebind, PortCollision.
  - Config/: ProjectConfig (ProjectConfigLoader.serverNotFound is the one not-found message for a server name), ConfigProjection, EffectiveHost, LocalOverlay, LockResource, WatchPolicy + WatchPaths, MissingProjectPolicy (the one rule every automatic missing-project prune uses).
  - Resource/ResourceIdentity.swift: fingerprint of a lock resource's state.
  - Launchd/: LaunchdAdmin, LaunchdJobs, DaemonRecoveryPolicy, AgentRebindPolicy, DaemonImagePolicy, AppAgentPolicy (docs/macos-lifecycle.md).
  - DeepLink/; Update/: UpdateCheck, DirectaDistribution (the one home for the tap token, releases URL, and brew commands).
  - Logs/: LogFormat, LogQuery, LogScan, OrphanProjectLogs (removalRefusal is the one home for whether an orphan log directory may be deleted, run daemon-side only).
  - Log/DirectaLog.swift (OSLog facade); Events/: DaemonRestartBurstCounter, EventDetailFormats (the one home for event detail strings a reader interprets).
  - Telemetry/: DaemonActivity, TelemetryRecords, TelemetryCadence, TelemetryLog, DaemonIncident (docs/macos-lifecycle.md "Daemon telemetry").
- Sources/DirectaDaemonCore: daemon logic as a library.
  - Supervisor/ServerSupervisor.swift: per-server actor (spawn, spool capture, phase machine, ensure/wait, teardown). signalRun is the one signalling path.
  - Supervisor/ProcessTree.swift: liveDescendants is the one home for the four-source descendant union; narrowed/isAlive for turning a pid read off disk or the wire into a kernel call.
  - Supervisor/ProcessLauncher.swift (LaunchdJobLauncher under the SMAppService agent); Supervisor/ExitWatcher.swift, the one process-wide exit watcher.
  - Health/: HealthProber (EffectiveHealthcheck, PortGuard), PowerState.
  - Registry/Registry.swift: owner of registry.json and state.json. retireState with ServerSupervisor.stopForRemoval is the home for a removed server's row.
  - Control/: PortProbe (the seam every Router port check asks), ControlServer.swift (the Router; prepareSpawn is the one funnel every start-shaped path takes and the one home for the trust gate), AgentJobs (the one seam for launchd child jobs), Why.swift.
  - Events/EventStore.swift, LogStore/ (LogStore + SpoolTailer), Telemetry/ (TelemetrySampler, ProcessSampler, DaemonTelemetry).
- Sources/ddirecta: thin main, identical under launchd and --foreground; boot order and sweeps: docs/architecture.md.
- Sources/directa: the CLI.
  - CLI.swift: every command as a struct. GlobalOptions.resolveProject is the one home for cwd-to-project resolution. Past the size where splitting is worth asking about.
  - RestartSession.swift, MonitorCommand.swift (MonitorSession, MonitorLifetime): testable cores behind protocol seams.
  - HookSupport.swift: CLISelf, HookContext, HarnessBatch.
- Sources/DirectaApp: menu bar app, a pure DaemonClient consumer. BundledAgent is the one SMAppService.agent wrapper; SetupPerformer.canonicalPath is the one home for bundle-path comparison.
- Sources/fixture-server: test-double dev server; modes in its header comment.
- Tests: targets and helpers in docs/standards/testing.md.

Commands
- make build: release build of the three products (directa, ddirecta, DirectaApp).
- make test: the unit suites, always through make (never a bare swift test), as CI does; budget under 30s, the run prints the live timing.
- scripts/test-narrow-pool.sh [swift-testing args | --self-test]: the unit suites on a pool narrowed to a CI runner's size, failing when a pool thread stays blocked. Run after adding a test that waits on a process, semaphore, or timer, or after touching a blocking helper; --self-test after editing scripts/narrow-pool/narrow-pool.c.
- make dead-code: the unused-code gate, failing on any finding. Run only through the script (scripts/dead-code.sh), never a bare `periphery scan`. Run after deleting or moving code.
- scripts/smoke.sh: the end-to-end gate, a zsh script run directly, never through bash. Run after touching the supervisor, wire protocol, CLI, or deep links.
- scripts/smoke-deeplink.sh: Launch Services E2E for directa:// and the only gate covering the launch stand-down. Needs a GUI session; run before merging URL-scheme or app-launch work.
- scripts/smoke-launchd.sh: the real LaunchAgent lifecycle via daemon install --legacy. Mutates the user launchd domain, refuses to run if a home plist or bootstrapped job exists, and leaves nothing behind.
- scripts/smoke-cask.sh: the Homebrew cask gate, non-destructive by default (docs/releasing.md).
- scripts/sweep-swift-temp.sh [--dry-run | --list]: removes the Swift driver's leftover temp folders; make build and make test run it first. Never contain the leak by pointing TMPDIR at a per-run directory.
- scripts/daemon-deaths.sh [incidents-dir]: one summary per recorded daemon death.
- make app / make dmg / make release-dmg / make install: docs/releasing.md.
- Unified logging: `/usr/bin/log stream --predicate 'subsystem == "dev.quantizor.directa"' --level debug` (the full path, since zsh's `log` builtin shadows it). Only error level persists for `log show`; events.log is the durable history. Child output stays in spool files; OSLog is for directa's own behavior.
- Deep links: directa://open|ensure|stop|why/<project-slug>/<server>[/<head>] (query form also accepted). directa://daemon/ensure, directa://daemon/unregister, and directa://daemon/unregister-all ask the app to own SMAppService registration. directa link prints; the app handles via Launch Services; directa x-url runs the same runner for smoke.

Rules

Prose and communication
- Prose (docs, PR bodies, changeset text, commit bodies): American English, no em-dashes (use a colon, comma, or period), plain language over jargon, no attribution footers or trailers anywhere. PR and changeset descriptions lead with user-facing impact, not mechanism. Changeset bodies are changelog text: no internals, and a term of art gets a short plain-English gloss on first use. "devservers" as one word is deliberate wherever it appears in the project's own description, echoing the devservers.json a user edits; do not correct it to two words. Elsewhere in prose, "dev server" is two words.
- Error messages assume the reader knows nothing of internals: what happened, where, and the exact fix; wire errors carry a stable code and a hint that is the literal command to run.

Correctness and types
- Types are law: no unsafe casts or force-unwraps in product code to silence the checker (tests prefer #require); strict concurrency stays on. If a type will not express, restructure the code.
- Backward compatibility binds only the public surfaces: the CLI JSON contract and the wire protocol (append-only error codes; proto bump on a breaking change). All internal code is freely rewritable.
- All JSON goes through JSONCoding: sorted keys, ISO-8601 UTC with milliseconds, no interior newlines. Never construct a raw JSONEncoder or JSONDecoder; the golden tests and NDJSON line framing depend on this determinism.
- Wire methods are typed end to end: the daemon sniffs the {id, method} head, then re-decodes the full typed frame. A new method extends WireMethod plus Codable params/result types in Wire.swift; no untyped dictionaries on the wire.
- Every CLI command supports --json with a stable schema generated from the shared Codable types; failures emit {ok:false, error:{code,message,hint}} on stdout, hint being the literal remediation command. Error codes grow append-only. Golden tests in Tests/DirectaKitTests assert exact schema strings; a changed field is an API change: update docs/cli-contract.md in the same commit, then the golden.

Testing
- Tests ship with every feature and cover logic and headlessly-verifiable behavior, never visuals (how the app looks is judged by rendering and viewing). Coverage stays above 80% of lines on DirectaKit and DirectaDaemonCore (how to measure: docs/standards/testing.md).
- Tests use Swift Testing (@Test, #expect, #require), not XCTest. Suites run in parallel by default; anything sharing a daemon, socket, or port uses @Suite(.serialized).
- Prefer exact full-output assertions; validate a new test red then green; treat golden drift as a suspected regression before updating the golden.
- Derive a test's expected value from what the code should do; never build it by transforming the observed output until the two match.
- Read a file's existing tests before the first edit to it, and extend an existing suite before creating a new one.
- A state machine (the server phase machine, ensure/stop/restart interleavings, lock pause and resume) is tested across every reachable transition, including unlikely ones.
- Every test helper in docs/standards/testing.md is the one home for its job. Ports come from `TestPorts.port(offset)`, never a literal (a test enforces it); scratch directories come from `.temporaryTree`, never Foundation's temp directory (TemporaryTreeTests enforces it); a wait on timing the test does not control goes through Polling.swift, and a never-happens test asserts `!eventually(...)` over the whole window rather than sleeping.
- A gate a test holds a job on opens in a `defer` declared after the `async let` or Task that waits on it, so a failed `#require` cannot hang the run.

Inputs and error handling
- The daemon treats every client (CLI, app, deep link) as untrusted: it validates a registered spec like a committed one, clamps every timeout, screens every regex, and canonicalizes every project path at the decode seam itself; a client-side check is a convenience, never the control.
- A user-supplied regex (logs --grep) is screened before it runs: a nested unbounded quantifier is refused, because Swift's backtracking engine turns (a+)+ into minutes of CPU on a single line and the match runs on the log actor.
- A wire-supplied timeout is clamped before it becomes a Duration: Duration.seconds fatally traps on a non-finite value and overflows on an astronomically large one, so the daemon bounds every timeout it receives (ServerSupervisor.boundedTimeoutSeconds) before use. The client separately clamps its own SO_RCVTIMEO response deadline.
- Fix at the cause, never the symptom: no sleeps over races, no timeouts raised or goldens updated to green without explaining the diff, no swallowed errors. try? is a suppression unless loss is genuinely acceptable at that site. When the cause is out of reach, name the suppression as a suppression and add it to BACKLOG.md; nothing is deferred silently.

Organization and naming
- A decision or value with a named one home in the map is used from that home, never reimplemented beside it; a new shared decision gets a home and a map line here.
- Fields in type declarations, initializers, and literals are alphabetized; keep a non-alphabetical order only where the sequence is load-bearing and say why in a comment.
- Persisted names (JSON keys, file names) are plain English a non-engineer would read.
- A string a writer builds and a reader matches lives once as a shared constant (EventDetailFormats is the pattern), matched exactly, never by substring.
- A source file past roughly 4,000 lines prompts the question whether to split it (the answer can be no, for one cohesive unit).

Comments and docs
- Comments are block comments (/** ... */) so they surface as hover docs; they explain the current code's non-obvious decisions and never narrate edits or history. A comment never restates what the types already say.
- A behavior change updates its spec (docs/design.md, docs/cli-contract.md, docs/macos-lifecycle.md) in the same change, spec first.
- Docs carry no measured drift-prone numbers (timings, counts, coverage); state the budget and the command that prints the live figure. Docs track current state, never completions or history.
- When a fact changes in its home, grep the repo for every record of the old one (docs, tests, comments, CI, this file) and update each in the same change.

Security and trust
- The daemon never acts on a project's committed config before trust is recorded, enforced in prepareSpawn: an explicit command records trust, an autonomous restore or watch sweep refuses an unapproved project. writeConfig only writes for a project the daemon already tracks.
- Child output is attacker-influenceable. The SessionStart hook never emits raw log lines or command strings into agent context. The tool-change hook may quote a few sanitized err lines, only for a server that just crashed, failed, or turned unhealthy, and only lines that conversation has not seen; they stay inside the `<directa-servers>` fence.
- `directa monitor` is the one place raw child output reaches an agent, inside the same trust boundary: the agent opts in for one named server (never injected at session start); every line renders under a namespace chosen structurally from the event's own kind and stream, never parsed from content; text and label are sanitized (ANSI/OSC escapes and the Unicode control, format, and line/paragraph-separator categories removed) before rendering; a server name reaches a pasted hint only through ShellWord; and independent stdout and stderr token-bucket budgets bound what an agent sees, with every crossing and resume named. Mechanism: docs/architecture.md.
- A deletion path proves its target before removing it, daemon-side, while holding the state that decides it (OrphanProjectLogs.removalRefusal is the pattern: a real directory directly under the logs root, in the expected name shape, never a symlink or a claimed slug).
- An outbound request carries no user identifier (UpdateCheck sends a fixed User-Agent and an ETag only), and every update-check failure stays silent and out of agent context.

Persistence (no database, no migrations)
- State files load through AtomicFile.load, which separates three outcomes: a missing file starts empty, a parse failure quarantines to .corrupt-<timestamp> and continues (never fatal, since a startup parse crash under launchd KeepAlive loops forever), and a file that exists but cannot be READ (EMFILE, an I/O error) throws so the daemon refuses to start rather than erasing it on the next write. loadDefensively collapses all three to nil and is only for a rebuildable cache.
- New fields on persisted types stay optional so existing files keep parsing.
- Registry/state writes are temp + fsync + rename.
- Structured log files keep per-file monotonic timestamps (clamp on append); the since-query binary search depends on it.

Process and platform invariants
- Output capture is spool-file fds, never pipes: children must survive daemon death without SIGPIPE. Do not introduce pipe-based capture anywhere. A spool is never truncated or renamed while its child runs (the child's fd cannot be reopened or repositioned); the tailer bounds its disk use by punching holes behind what it has ingested (docs/design.md, output capture).
- Teardown signals the process group and every live descendant through signalRun over ProcessTree.liveDescendants, the union of four sources: a parent-chain snapshot, its 200ms refreshes while starting (merged in, never replacing it), a session sweep keyed on the root pid as session id (never read back with getsid), and a kernel unique-id lineage walk. Each descendant is signaled only while its pid still names the identity recorded (start time and unique id); the root's group only while its pid names the root identity recorded at spawn or adopt; the crash path withholds the group signal. The sweeps refuse the daemon's own session, unique id, and ancestors. Keep the union and the revalidation when touching stop() or the crash exit path. Mechanism: docs/design.md (Daemon internals) and docs/architecture.md.
- Nothing reachable from async code, product or test, blocks a cooperative-pool thread on a subprocess, socket, semaphore, pipe read, or sleep: product code goes through a BlockingLane, test code through offPool. A sync helper called inside an async function (including inside `#expect(...)`, whose closure is synchronous) escapes the async-overload guard; wrap it in a lane explicitly. Guardrail: scripts/test-narrow-pool.sh. Why: docs/architecture.md.
- Binary upgrades stage and rename(2); never overwrite a running signed Mach-O.
- The daemon never keeps its process image on a mounted volume: ddirecta checks its image path at boot and re-execs the canonical installed binary when it is under /Volumes. Keep that guard ahead of the single-instance flock and keep the sentinel + run-in-place fallback so it cannot loop under KeepAlive. Why: docs/macos-lifecycle.md (DMG and /Applications share a bundle id).

Performance
- Hot paths (spool tailer, log query) get temporary microbenchmarks before an approach is chosen, and a change to one is measured against the prior code; slower is a regression.
- A governor (throttle, cap) is never the fix for a cost problem; make the work itself cheaper. The common case never pays for rare-shape handling.

Git and process
- Never git stash; use temp commits. Fetch origin before starting work or rebasing; rebase rather than merge.
- A dependency change updates Package.resolved (or package-lock.json) in the same commit and is verified by a build.
- Agents never bump versions or publish. Changesets (when to write one) and release tagging: CONTRIBUTING.md. A changeset's frontmatter names the package and a bump; scripts/validate-changesets.mjs checks it in CI.
- Commit subjects and PR titles are Conventional Commits: `type(scope): description`. Imperative, lowercase after the colon, no trailing period, one line, the change in behavior or invariant, never a file list. GitHub squash uses the PR title as the `main` subject, so the title is a conventional subject too.
  - Types: feat, fix, docs, refactor, perf, test, build, ci. Do not invent a type. chore is last resort.
  - Scopes: app, cli, daemon, supervisor, hook, installer, doctor, lock, watch, launchd. Omit scope only for repo-wide work. docs, test, build, and ci may add a qualifier (`docs(agents)`, `test(cli)`, `build(cask)`).
  - Breaking: `type(scope)!:` plus a major changeset. Changesets own the version bump; commit type does not.
  - PR title names the primary change (`!` then feat then fix then the rest). Mixed-type branches list the others in the body. Version Packages PRs keep the bot title. PR body stays user-facing (impact, migration, verification). Examples: CONTRIBUTING.md.

Method
- A reported defect names a class: search for every instance (code, tests, callers, docs, config) and fix them all in the same change, or list the ones left and why.
- A failure's stated cause is a hypothesis: read the failure's own record (CI log, stack, events.log, the incident files) before building a fix.
- Verify a primitive behaves as assumed before layering a workaround on it.
- A probe, gate, or script fails loudly: an empty, missing, or unreadable input is an error, never a pass.
- After deleting or moving code, run make dead-code and also search for what it cannot see: a doc, CI step, comment, or map line whose subject is gone.
- Before calling work done: hunt the input that breaks it, run make test and scripts/smoke.sh, and separate what you observed (file:line, command output) from what you inferred.

Aesthetic and UX
- Quiet instrument panel: monochrome SF Symbols glyph, tally-light status dots (subtle breathing animation on starting), dense but calm typography, no chrome. State changes register visibly but never shout.
- Visual changes are judged by rendering and viewing, never asserted in unit tests.
- Accessibility is a quality bar, not a merge gate: every control and status indicator carries an accessibility label, and status is never conveyed by color alone.
- Text a person sees uses human-readable labels, never raw machine values.

Domain and stack
- Swift and macOS facts live in docs/macos-lifecycle.md and docs/design.md; there are no other stack docs.

Wayfinding and backlog
- This file is the index; its charter is at the top. BACKLOG.md is the only backlog, holds open work only with no narration (the open defect, its evidence, the ask; never what was fixed or tried), and the change that resolves an entry removes it; it is gitignored and maintainer-local, so keep it off the public tree.
