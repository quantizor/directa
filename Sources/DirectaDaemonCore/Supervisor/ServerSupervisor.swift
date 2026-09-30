import DirectaKit
import Foundation

/** One registration in a `PhaseWaiterList`. `deadlineTask` is the sleeping
    task that expires this one waiter if the real transition never lands
    first; nil for an unbounded wait. */
private struct PhaseWaiter {
    let continuation: CheckedContinuation<Void, Never>
    let deadlineTask: Task<Void, Never>?
    let id: UUID
}

/** Callers parked until a phase transition lands. Each waiter has an id so a
    bounded one can be picked out and resumed on its own when its deadline
    fires, leaving every other registration (an unrelated caller's unbounded
    join, or another bounded wait with a later deadline) untouched. The
    transition and a deadline can never both resume one continuation: both
    run on the owning actor and never interleave, and whichever runs first
    removes the waiter. */
private struct PhaseWaiterList {
    private var waiters: [PhaseWaiter] = []

    mutating func add(_ waiter: PhaseWaiter) {
        waiters.append(waiter)
    }

    /** Resumes one waiter ahead of the transition; a no-op once the
        transition already settled it. */
    mutating func expire(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
    }

    mutating func settleAll() {
        let settled = waiters
        waiters = []
        for waiter in settled {
            waiter.deadlineTask?.cancel()
            waiter.continuation.resume()
        }
    }
}

/** How long `stop()` waits on a server. `graceSeconds` is the SIGTERM-to-SIGKILL
    window a stop gets when its caller names none; `overtimeSeconds` is the
    margin past that grace before the stop gives up waiting for the phase to
    clear (see `waitForStoppingToClear`). Injectable so tests reach the
    give-up path without a real multi-second wait. */
public struct StopTiming: Sendable {
    public let graceSeconds: Double
    public let overtimeSeconds: Double

    public init(graceSeconds: Double, overtimeSeconds: Double) {
        self.graceSeconds = graceSeconds
        self.overtimeSeconds = overtimeSeconds
    }

    public static let standard = StopTiming(graceSeconds: 7, overtimeSeconds: 10)
}

/** One actor per server: owns the child's lifecycle and serializes every mutation,
    which is what makes `ensure` single-flight (concurrent starts join the same
    in-flight attempt instead of double-spawning). */
public actor ServerSupervisor {
    /** What the stop in flight asked for, carried from the stop into
        `recordOutcome`. `deliberate` retires the resume-on-boot intent (a
        launchd drain keeps it). `reason` becomes the `stopped` event's detail
        in place of the exit code: the code says how the process ended, never
        why directa asked it to. `waitBound` is how long that stop waits for
        the phase to clear (its grace plus `stopTiming.overtimeSeconds`), so a
        `start()` joining it waits no longer than the stop itself does. */
    private struct StopRequest {
        let deliberate: Bool
        let reason: String
        let waitBound: Duration
    }

    /** The log tail a terminal run's status shows, read once rather than per
        status call: the log stops growing once the process is gone, so one
        read at the transition is both cheaper and a truer snapshot of the
        failure. `read(nil)` is a read that found nothing, which must not look
        unread and send every status call back to the log family. */
    private enum TailCache {
        case read([String]?)
        case unread
    }

    /** How a run came under supervision, which decides where its tailers
        start, what the log and event say, and whether the state row's bound
        port is written (a spawn's is left for the router). */
    private enum Supervision {
        case adopted(boundPort: Int?)
        case spawned
    }

    private enum WaiterList {
        case spawn
        case stopping
    }

    private var consecutiveFailures = 0
    private var consecutiveSuccesses = 0
    /** Committed port before override/rebind; status.declaredPort. */
    private var declaredPort: Int?
    /** Keeps the descendant snapshot fresh across the startup window; see
        startDescendantWatch. */
    private var descendantTask: Task<Void, Never>?
    /** Short enough that a worker forked a beat after startup is recorded before
        a crash can orphan it, and long enough that the sweeps cost nothing over
        a startup window. */
    private let descendantWatchIntervalMs = 200
    /** What this run binds after override/rebind/materialization. */
    private var effectivePort: Int?
    private var errTailer: SpoolTailer?
    /** Error-stream tally for the current process, captured when the phase turns
        terminal or unhealthy rather than recomputed per status call. Cleared at
        spawn so a crash loop reports this incarnation, bracketed to the run's
        start, and persisted so it survives a daemon restart. */
    private var errorSummary: ErrorSummary?
    private let events: EventStore?
    private var everHealthy = false
    private var healthTask: Task<Void, Never>?
    private var lastDescendantSnapshot: [ProcessIdentity] = []
    private var lastExit: LastExit?
    private var lastHealthAt: Date?
    private let launcher: any ProcessLauncher
    private let logStore: LogStore
    private let mainProjectSlug: String?
    /** Resolved named secondaries for this run (status.ports). */
    private var namedPorts: [String: Int]?
    private var observedPort: Int?
    private var outTailer: SpoolTailer?
    private let paths: DirectaPaths
    /** Set when a stop moves the phase to `.stopping`, cleared once the
        phase leaves it or a new run starts. */
    private var pendingStop: StopRequest?
    /** `didSet` is the one home for leaving `.stopping`: every caller that must
        not proceed until a stop (or the drain half of a crash/exit) has fully
        landed awaits `waitForStoppingToClear` instead of polling `runTask`,
        which goes nil at the top of `recordOutcome`, well before the tailer
        drains and the registry write that still have to happen. Settling here
        rather than at each of the many phase-assignment sites means a future
        one needs no special-casing to keep this correct. */
    private var phase: ServerPhase = .stopped {
        didSet {
            if oldValue == .stopping, phase != .stopping {
                stoppingWaiters.settleAll()
            }
            DaemonActivity.shared.recordPhase(phase, key: writerID.uuidString)
        }
    }
    private var pid: pid_t?
    private var portClaim: PortClaim?
    private var portConflict: PortConflict?
    private let prober: any HealthProber
    public let projectPath: String
    /** `ProcessTree.identity(of:)` outside tests; a test injects a reader to
        stand in for a pid recycled between spawn and teardown. */
    private let readIdentity: @Sendable (pid_t) -> ProcessIdentity?
    private var recentLogTail: TailCache = .unread
    private let registry: Registry
    /** Set by `stopForRemoval` to its reason, never cleared: the router has
        dropped (or is dropping) this supervisor, so a caller still holding the
        reference (a restart's `ensure`, a watch sweep) must not spawn or
        attach a run that nothing would supervise, and a spawn already in
        flight is stopped for this reason the moment its pid arrives. */
    private var removalReason: String?
    /** The run's root as it was when its pid was recorded (spawn or adopt),
        nil when that read found the root already reaped. Every teardown pass
        revalidates against this and never against a read taken at teardown
        time: a launchd job's root is reaped by launchd the moment it exits,
        so by then its pid may name a stranger. It is also the lineage walk's
        first key (ProcessTree.liveDescendants). */
    private var rootIdentity: ProcessIdentity?
    /** Bumped when a run starts and when it ends, so work that awaited across
        either (a listen scan's lsof, a log read) can tell it no longer
        belongs to the current run and must not write onto it. */
    private var runGeneration: UInt64 = 0
    private var runningSpecHash: String?
    private var runTask: Task<Void, Never>?
    /** `<project>::<name>`: the state row key, and the label telemetry gives
        this supervisor's stops and waits. */
    private let serverID: String
    private var spawnError: SpawnError?
    /** Waiters for the spawn settling (a pid, or a terminal phase). */
    private var spawnWaiters = PhaseWaiterList()
    private var spec: ServerSpec
    /** Lifetime window a self-exit must land in to count toward the stall
        streak (see recordOutcome). Overridable so tests can use fast bounds. */
    private let stallBounds: (minSeconds: Int, maxSeconds: Int)
    private var stallStreak = 0
    private var startedAt: Date?
    /** Set once the router has dropped this supervisor after a stop that never
        finished: a late `recordOutcome` must not write a row the router has
        already retired or deleted. Covers the moment before the router's
        `Registry.retireState` lands; the registry refuses `writerID` after. */
    private var stateWritesAbandoned = false
    /** Waiters for `phase` leaving `.stopping`, settled by `phase`'s `didSet`. */
    private var stoppingWaiters = PhaseWaiterList()
    private let stopTiming: StopTiming
    /** Durable why evidence across ensure truncate / daemon rehydrate. */
    private var terminalEvidence: [String]?
    /** Taken once the run has been alive for the settle window rather than at
        spawn, so a server that writes its own watched file while booting folds
        that write into the baseline instead of bouncing itself for it. */
    private var watchBaseline: WatchFingerprint?
    private var watchPending: (at: Date, stamp: WatchFingerprint)?
    /** Deliberately not cleared at spawn: the oscillation the breaker detects
        spans restarts by definition. */
    private var watchRestarts: [Date] = []
    private var watchSuspended = false
    /** Linked-worktree display identity, fixed at creation from the `worktree`
        the creator resolved (`CheckoutIdentity.worktreeDisplay`, which runs
        git, so never per status read or per spawn): status.worktree and, with
        `mainProjectSlug`, status.mainProject. A worktree project whose
        servers are stopped or restored still reports its label. Nil for a
        main checkout; the pair never alters the host. */
    private let worktreeLabel: String?
    /** Identifies this supervisor's state writes to `Registry.updateState`, so
        `Registry.retireState` refuses a dropped supervisor's late write
        without blocking a later supervisor for the same server. */
    public nonisolated let writerID = UUID()

    public init(
        events: EventStore? = nil,
        launcher: any ProcessLauncher,
        paths: DirectaPaths,
        prober: any HealthProber = NetworkHealthProber(),
        projectPath: String,
        readIdentity: @escaping @Sendable (pid_t) -> ProcessIdentity? = { ProcessTree.identity(of: $0) },
        registry: Registry,
        spec: ServerSpec,
        stallBounds: (minSeconds: Int, maxSeconds: Int) = (10, 300),
        stopTiming: StopTiming = .standard,
        worktree: WorktreeDisplay? = nil
    ) {
        /** Match Registry's normalized state keys (`/var` vs `/private/var`). */
        let project = canonicalProjectPath(projectPath)
        let id = DirectaKit.serverID(project: project, name: spec.name)
        self.events = events
        self.launcher = launcher
        self.logStore = LogStore(currentURL: paths.structuredLogFile(project: project, server: spec.name))
        self.mainProjectSlug = worktree?.mainProject
        self.paths = paths
        self.prober = prober
        self.projectPath = project
        self.readIdentity = readIdentity
        self.registry = registry
        self.serverID = id
        self.spec = spec
        self.stallBounds = stallBounds
        self.stopTiming = stopTiming
        self.worktreeLabel = worktree?.label
        if let persisted = AtomicFile.loadDefensively(StateFile.self, from: paths.stateFile)?
            .servers[id] {
            self.errorSummary = persisted.errorSummary
            self.lastExit = persisted.lastExit
            self.spawnError = persisted.spawnError
            self.stallStreak = persisted.stallStreak ?? 0
            self.terminalEvidence = persisted.terminalEvidence
            if persisted.phase == .crashed || persisted.phase == .failed {
                self.phase = persisted.phase
            }
        }
        /** `didSet` does not run for assignments inside init. */
        DaemonActivity.shared.recordPhase(phase, key: writerID.uuidString)
    }

    deinit {
        DaemonActivity.shared.forgetPhase(key: writerID.uuidString)
    }

    public func updateSpec(_ newSpec: ServerSpec) {
        spec = newSpec
    }

    /** Absolute watched paths for this run, empty when the server declares no
        `watch`, which is the whole no-configuration-needed path: everything
        below returns immediately. */
    private var watchPaths: [String] {
        WatchPaths.resolve(entries: spec.watch ?? [], project: projectPath).paths
    }

    /** One watch evaluation. Returns the changed paths only when the caller
        should restart: nil for idle, still settling, waiting out the quiet
        window, suspended, or not running. The stats happen here so the Router's
        sweep stays a fan-out. */
    public func evaluateWatch(now: Date = Date()) async -> [String]? {
        guard !watchSuspended, phase == .running || phase == .unhealthy else { return nil }
        let paths = watchPaths
        guard !paths.isEmpty, let startedAt else { return nil }
        let limits = WatchPolicy.Limits()
        guard now.timeIntervalSince(startedAt) >= limits.settleSeconds else { return nil }
        let observed = WatchFingerprint.take(paths: paths)
        guard let baseline = watchBaseline else {
            watchBaseline = observed
            return nil
        }
        let decision = WatchPolicy.decide(
            baseline: baseline, limits: limits, now: now, observed: observed,
            pending: watchPending, recentRestarts: watchRestarts)
        switch decision {
        case .idle:
            watchPending = nil
            return nil
        case .restart(let changed):
            return changed
        case .suspend(let changed):
            /** A watch that quietly stopped working is worse than one that never
                existed, so say which paths keep moving and stop. */
            watchSuspended = true
            watchPending = nil
            await logStore.append(
                stream: .sys,
                text: "watch suspended: \(changed.joined(separator: ", ")) keeps changing")
            await events?.post(
                kind: .marked, project: projectPath, server: spec.name,
                detail: "watch suspended: \(changed.joined(separator: ", "))")
            return nil
        case .waiting:
            if watchPending?.stamp != observed { watchPending = (at: now, stamp: observed) }
            return nil
        }
    }

    /** The Router refused this restart (a held resource, a held port). Keeps the
        change armed against the same observed stamp and only pushes its
        timestamp forward, so the next attempt waits out one more quiet window
        instead of retrying on every sweep for as long as the hold lasts. */
    public func deferWatchRestart(now: Date) {
        guard let pending = watchPending else { return }
        watchPending = (at: now, stamp: pending.stamp)
    }

    public func recordWatchRestart(_ at: Date) {
        watchRestarts.append(at)
        watchPending = nil
        watchBaseline = nil
    }

    /** An explicit restart re-arms a tripped breaker: the feature must not be
        dead for the rest of the daemon's life after one bad afternoon.

        The restart history goes with it, or the re-arm lasts exactly one
        evaluation: `WatchPolicy.decide` weighs the burst before anything else,
        so leaving three in-window restarts behind means the next observed change
        suspends again with no restart in between. Only an explicit restart
        clears it, which is why the watch sweep asks for `rearm: false`: an auto
        restart wiping its own breaker's evidence is the one thing the breaker
        exists to prevent. */
    public func rearmWatch() {
        watchSuspended = false
        watchPending = nil
        watchBaseline = nil
        watchRestarts.removeAll()
    }

    /** Port metadata for status/agents. Call after materializing the spawn spec. */
    public func setPortMeta(
        claim: PortClaim? = nil,
        declaredPort: Int?, effectivePort: Int?, portConflict: PortConflict? = nil
    ) {
        self.declaredPort = declaredPort
        self.effectivePort = effectivePort
        self.portClaim = claim
        self.namedPorts = claim.flatMap { $0.named.isEmpty ? nil : $0.named }
        self.portConflict = portConflict
    }

    /** The status and the claim resolved at spawn, read in one actor turn so a
        port check sees a phase and a claim that belong together. */
    public func portSnapshot() async -> (claim: PortClaim?, status: ServerStatus) {
        await fillLogTailIfUnread()
        return (claim: portClaim, status: statusSnapshot())
    }

    /** Starts the server if not already starting/running; otherwise joins the
        in-flight attempt. Returns once a pid exists or the spawn has failed; the
        phase stays `starting` until the healthcheck passes. */
    public func start() async -> ServerStatus {
        guard removalReason == nil else { return await status() }
        switch phase {
        case .running, .unhealthy:
            return await status()
        case .starting:
            await waitForSpawnSettled()
            return await status()
        case .stopping:
            /** Bounded like the stop being joined: a stop that never lands
                reports an honest `.stopping` here too, instead of holding
                this request (and the wire call behind it) forever. */
            let bound = pendingStop?.waitBound ?? stopWaitBound(graceSeconds: stopTiming.graceSeconds)
            guard await waitForStoppingToClear(timeout: bound) else {
                return await status()
            }
            return await start()
        case .failed where pid != nil:
            /** A port failure leaves its run alive. Spawning beside it would
                run two copies, and the old run's exit would later overwrite
                the new run's state, so it is stopped first; a stop that gives
                up reports its honest `.stopping`. */
            let stopped = await stop(deliberate: false, reason: "restarting after a port failure")
            guard stopped.phase != .stopping else { return stopped }
            return await start()
        case .crashed, .failed, .stopped:
            break
        }
        resetForNewRun()
        let argv = effectiveArgv()
        let cwd = effectiveCwd()
        let environment = spec.env ?? [:]
        let outURL = paths.spoolOutFile(project: projectPath, server: spec.name)
        let errURL = paths.spoolErrFile(project: projectPath, server: spec.name)
        do {
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            await recordSpawnFailure(SpawnError(errno: nil, message: "cannot create log directory: \(error)"))
            return await status()
        }
        let outFD = open(outURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        let errFD = open(errURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard outFD >= 0, errFD >= 0 else {
            if outFD >= 0 { close(outFD) }
            if errFD >= 0 { close(errFD) }
            await recordSpawnFailure(
                SpawnError(errno: Int(errno), message: "cannot open spool: \(String(cString: strerror(errno)))"))
            return await status()
        }
        runTask = Task { [launcher] in
            let outcome = await launcher.run(
                argv: argv,
                capture: SpawnCapture(
                    stderrFD: errFD, stderrPath: errURL.path, stdoutFD: outFD,
                    stdoutPath: outURL.path),
                cwd: cwd,
                environment: environment,
                onExitedBeforeWatch: { childPid in
                    await self.recordExitedBeforeWatch(pid: childPid)
                },
                onSpawn: { childPid in
                    await self.recordSpawn(pid: childPid)
                }
            )
            close(outFD)
            close(errFD)
            await self.recordOutcome(outcome)
        }
        await waitForSpawnSettled()
        return await status()
    }

    /** Attaches to a live process a prior daemon spawned, instead of spawning a
        new one: the agent-mode survivor of a jetsam SIGKILL, still registered as
        launchd child job `label` (`ControlServer.recoverAtStartup` found the
        match). Mirrors `recordSpawn` but does not spawn: `pid` is already
        running and its spool files already exist, so the tailers seed their
        offset to end-of-file instead of re-ingesting what a prior run already
        logged. `startedAt` is carried forward from the persisted state rather
        than stamped now, so uptime is not reset by the adoption itself; a
        missing value (pre-feature state) falls back to now.

        The exit watch is armed first, before anything is recorded: false
        means nothing changed here (phase, pid, registry, tailers) and the
        caller bounces the process instead. A removed supervisor returns false
        before arming, since an armed watch nobody waits on is never consumed.
        The result is a Bool rather than a status because the health monitor
        can promote a successful adopt to `.running` before this returns. The
        exit-watch task is what closes the adoption hole: without it, a
        process this attaches to and later loses (the common second-jetsam-wave
        case, or an ordinary crash) would become an undetected zombie, since
        nothing else calls `recordOutcome` for a pid this instance never
        spawned. */
    public func adopt(
        pid childPid: pid_t, label: String, boundPort: Int?, startedAt runStartedAt: Date?
    ) async -> Bool {
        guard removalReason == nil, launcher.prepareAdopt(pid: childPid) else { return false }
        resetForNewRun()
        pid = childPid
        rootIdentity = readIdentity(childPid)
        /** Set before the first await, as `start()` does, so a stop landing
            while this is still recording the run sees a live run and keeps its
            grace. The outcome waits for that recording to finish, so an exit
            the watch reports at once is never recorded ahead of it. */
        let (recorded, finishRecording) = AsyncStream<Void>.makeStream()
        runTask = Task { [launcher] in
            let outcome = await launcher.adopt(pid: childPid, label: label)
            for await _ in recorded {}
            await self.recordOutcome(outcome)
        }
        refreshDescendantSnapshot()
        await beginSupervising(
            pid: childPid, startedAt: runStartedAt ?? Date(), as: .adopted(boundPort: boundPort))
        finishRecording.finish()
        return true
    }

    /** The ensure state matrix: stopped/crashed/failed start fresh; starting joins
        the in-flight attempt; running and unhealthy are no-ops (unhealthy is
        reported, not restarted). Blocks until healthy, terminal, or timeout. */
    public func ensure(timeoutSeconds: Double) async -> EnsureResult {
        guard removalReason == nil else {
            let server = await status()
            return EnsureResult(reason: .stopped, server: server)
        }
        switch phase {
        case .running, .unhealthy:
            let server = await status()
            return EnsureResult(server: server)
        case .starting:
            break
        case .stopping:
            let budget = Self.boundedTimeoutSeconds(timeoutSeconds)
            let waitStart = ContinuousClock.now
            let cleared = await waitForStoppingToClear(timeout: .seconds(budget))
            guard cleared else {
                let server = await status()
                return EnsureResult(reason: .timeout, server: server)
            }
            /** The caller's timeout covers the whole ensure, so the rest of
                it (start and the health wait) gets only what the stop wait
                left over. */
            let waitedSeconds = waitStart.duration(to: .now) / .seconds(1)
            return await ensure(timeoutSeconds: max(0, budget - waitedSeconds))
        case .crashed, .failed, .stopped:
            let started = await start()
            if started.phase == .failed {
                return EnsureResult(reason: .failed, server: started)
            }
        }
        let outcome = await wait(for: .healthy, timeoutSeconds: timeoutSeconds)
        let server = await status()
        return EnsureResult(reason: outcome, server: server)
    }

    /** Clamp a wire-supplied timeout to a range `Duration.seconds` can represent
        without trapping: it fatally traps on a non-finite value and overflows on
        an astronomically large one. The wire is an untrusted surface, so the
        daemon guards this itself rather than trusting the client to have validated
        `--timeout`. A non-finite value means "wait as long as possible" and maps
        to the one-day ceiling. */
    nonisolated static func boundedTimeoutSeconds(_ seconds: Double) -> Double {
        seconds.isFinite ? min(max(seconds, 0), 86_400) : 86_400
    }

    /** Blocks until the condition holds. Rides through non-terminal transitions
        (another session's restart) and fails fast on crashed/failed/stopped. */
    public func wait(for condition: WaitCondition, timeoutSeconds: Double) async -> EnsureReason? {
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(Self.boundedTimeoutSeconds(timeoutSeconds)))
        while true {
            switch condition {
            case .healthy:
                if phase == .running { return nil }
                if phase == .crashed { return .crashed }
                if phase == .failed { return .failed }
                if phase == .stopped { return .stopped }
            case .stopped:
                if phase == .stopped || phase == .crashed || phase == .failed { return nil }
            }
            if ContinuousClock.now >= deadline { return .timeout }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /** SIGTERM to the process group plus every stray descendant, grace period,
        then SIGKILL the same way. The session created at spawn makes pgid == pid,
        but children that setpgid/setsid themselves (Foundation Process does this
        by default) escape the group, so teardown also sweeps the descendant tree,
        snapshotted before the first signal since orphans reparent to launchd.
        `deliberate` is true only for a user-invoked stop (directa stop/down): it
        clears the resume-on-boot intent. A launchd drain passes false so the
        machine coming back up restores what was running. `reason` is a required
        plain-English clause (for example "requested by restart", "watch change
        in <path>") written into the server's own log before the signal and
        carried onto the `stopped` event's detail: it is the only durable record
        of why directa tore the process down, since OSLog does not persist and
        the log otherwise only ever says `exited code=N`. A nil `graceSeconds`
        takes `stopTiming.graceSeconds`. */
    public func stop(
        graceSeconds requestedGrace: Double? = nil, deliberate: Bool = true, reason: String
    ) async -> ServerStatus {
        let graceSeconds = requestedGrace ?? stopTiming.graceSeconds
        let stopWaitTimeout = stopWaitBound(graceSeconds: graceSeconds)
        switch phase {
        case .failed where pid != nil:
            /** A port failure leaves its run alive, so it stops like a
                running one. */
            break
        case .stopped, .crashed, .failed:
            return await status()
        case .stopping:
            if await !waitForStoppingToClear(timeout: stopWaitTimeout) {
                await recordStuckStop(after: stopWaitTimeout)
            }
            return await status()
        case .starting, .running, .unhealthy:
            break
        }
        guard let target = pid else {
            guard phase == .starting else {
                phase = .stopped
                return await status()
            }
            /** The launcher has not reported a pid yet (a launchd job takes a
                moment to publish one). Reading `.stopped` here would let that
                run come up under a stopped phase, beside which a later start
                spawns a second copy. Wait for the spawn to settle, then stop
                whatever it produced from the top. */
            guard await waitForSpawnSettled(timeout: stopWaitTimeout) else {
                let seconds = stopWaitTimeout.components.seconds
                await logStore.append(
                    stream: .sys,
                    text: "stop waited \(seconds)s for the process to start and gave up; it may still come up")
                DirectaLog.supervisor.error(
                    "\(spec.name) stop waited \(seconds)s for the process to start and gave up; it may still come up")
                return await status()
            }
            return await stop(graceSeconds: requestedGrace, deliberate: deliberate, reason: reason)
        }
        let activity = DaemonActivity.shared.begin(.stop, label: "\(serverID): \(reason)")
        defer { DaemonActivity.shared.end(activity, outcome: phase.rawValue) }
        let pass = await beginStop(
            target: target, reason: reason, deliberate: deliberate, graceSeconds: graceSeconds)
        /** The grace ends early only once the root and every SIGTERM candidate
            have exited: a descendant still shutting down after the root is
            gone keeps the rest of its grace rather than meeting SIGKILL the
            moment the root exits. */
        let deadline = ContinuousClock.now.advanced(by: .seconds(graceSeconds))
        while ContinuousClock.now < deadline {
            let rootRunning =
                runTask != nil
                && (pass.keys.rootIdentity.map(ProcessTree.isRunning) ?? (kill(target, 0) == 0))
            if !rootRunning, !pass.candidates.contains(where: ProcessTree.isRunning) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        escalate(pass)
        if await !waitForStoppingToClear(timeout: stopWaitTimeout) {
            await recordStuckStop(after: stopWaitTimeout)
        }
        return await status()
    }

    /** A deliberate stop for a caller about to drop this supervisor (unregister,
        forgetting a vanished project). Marks it removed before the stop, so
        from here on `start`, `ensure`, and `adopt` spawn or attach nothing,
        whatever stop this one joins, and a spawn still in flight is stopped
        when its pid arrives (`recordSpawn`). On `.gaveUp` state writes are
        abandoned in the same actor turn the stop returned in, so a
        `recordOutcome` landing after the caller retires or deletes the state
        row cannot put it back. On `.stopped` a joined non-deliberate stop (a
        restart, a watch sweep) may have kept boot intent, which the caller
        clears. */
    public func stopForRemoval(reason: String) async -> RemovalOutcome {
        removalReason = reason
        let wasTerminal = !hasLiveRun
        _ = await stop(reason: reason)
        guard hasLiveRun else { return wasTerminal ? .alreadyTerminal : .stopped }
        stateWritesAbandoned = true
        return .gaveUp
    }

    private var hasLiveRun: Bool { phase.hasLiveRun(pid: pid.map(Int.init)) }

    /** How a removal stop ended, read in the actor turns the stop began and
        returned in. */
    public enum RemovalOutcome: Equatable, Sendable {
        /** No run was alive when the removal began, so `stop` did nothing and
            no `recordOutcome` posts a `stopped` event. */
        case alreadyTerminal
        /** The stop gave up short of a terminal phase: still `.stopping`, or
            still `.starting` with no pid yet. */
        case gaveUp
        /** The run was alive and its stop finished. */
        case stopped
    }

    /** How long a stop with this grace waits for the phase to clear. The
        overtime margin sits comfortably past the SIGKILL escalation (which
        fires at the grace deadline) and past the crash path's own escalation
        grace, so an ordinary teardown never trips it, and only a stop that is
        genuinely never landing (a bug elsewhere, or a child recordOutcome
        cannot reap) does. */
    private func stopWaitBound(graceSeconds: Double) -> Duration {
        .seconds(graceSeconds + stopTiming.overtimeSeconds)
    }

    /** What a teardown pass keys on besides the root pid, read together from
        the live fields so a caller captures them in one step before any await
        (a concurrent start or recordOutcome replaces both). */
    private struct TeardownKeys: Sendable {
        let rootIdentity: ProcessIdentity?
        let snapshot: [ProcessIdentity]
    }

    private var teardownKeys: TeardownKeys {
        TeardownKeys(rootIdentity: rootIdentity, snapshot: lastDescendantSnapshot)
    }

    /** A SIGTERM pass, carried into the SIGKILL pass that escalates it. */
    private struct TeardownPass: Sendable {
        /** The union the SIGTERM pass signaled over. */
        let candidates: [ProcessIdentity]
        let keys: TeardownKeys
        let signalGroup: Bool
        let target: pid_t
    }

    /** The opening of every stop of a known pid: records what the stop asked
        for, moves the phase to `.stopping`, writes the reason into the
        server's own log, and sends the SIGTERM pass. The teardown keys are
        captured before any await, since `recordOutcome` for this same exit can
        run during the log append and clear the live fields. */
    private func beginStop(
        target: pid_t, reason: String, deliberate: Bool, graceSeconds: Double
    ) async -> TeardownPass {
        pendingStop = StopRequest(
            deliberate: deliberate, reason: reason,
            waitBound: stopWaitBound(graceSeconds: graceSeconds))
        phase = .stopping
        let keys = teardownKeys
        await logStore.append(stream: .sys, text: "stopping: \(reason)")
        return terminate(target: target, keys: keys, signalGroup: true)
    }

    private func terminate(target: pid_t, keys: TeardownKeys, signalGroup: Bool) -> TeardownPass {
        TeardownPass(
            candidates: signalRun(target: target, keys: keys, signalGroup: signalGroup, signal: SIGTERM),
            keys: keys, signalGroup: signalGroup, target: target)
    }

    /** The SIGKILL pass over a freshly re-derived union (new children may have
        appeared during the grace window) plus everything the SIGTERM pass
        already reached: a descendant that ignored that pass and then became
        invisible to every live source (setsid, the now-dead root's parent
        chain, younger than the snapshot) is still re-signaled, revalidated
        against its recorded identity. The group is signaled only while the
        root still lives, and otherwise the survivors individually. */
    private func escalate(_ pass: TeardownPass) {
        signalRun(
            target: pass.target, keys: pass.keys, signalGroup: pass.signalGroup, signal: SIGKILL,
            priorCandidates: pass.candidates)
    }

    /** One revalidated teardown pass. Descendants come from every source at once
        (the startup snapshot, a fresh parent-chain sweep, the root's session
        members, and the lineage walk over kernel unique ids), so a child that
        escaped the group by setpgid or setsid is still found, even one that
        reparented after the last snapshot. With `signalGroup`, the root's
        process group is signaled only while `target` still names the process
        `keys.rootIdentity` recorded at spawn or adopt; once it has exited (or
        been recycled) the group is never touched and only the descendants that
        still match their recorded identity are signaled individually. The
        crash path, whose root is already reaped, passes `signalGroup: false`,
        so `kill(-pid)` can never follow a recycled id. This is the one home for
        turning a run's descendants into kernel signals. Returns the candidate
        union it signaled over, so an escalation pass can remember what to
        re-signal even after every live source has lost it. */
    @discardableResult
    private func signalRun(
        target: pid_t, keys: TeardownKeys, signalGroup: Bool, signal: Int32,
        priorCandidates: [ProcessIdentity] = []
    ) -> [ProcessIdentity] {
        let candidates = ProcessTree.liveDescendants(
            rootPid: target, rootIdentity: keys.rootIdentity, snapshot: keys.snapshot,
            priorCandidates: priorCandidates)
        ProcessTree.signalTree(
            descendants: candidates, rootIdentity: signalGroup ? keys.rootIdentity : nil,
            signal: signal)
        return candidates
    }

    public func status() async -> ServerStatus {
        await fillLogTailIfUnread()
        return statusSnapshot()
    }

    private var isTerminal: Bool {
        phase == .crashed || phase == .failed
    }

    /** A server rehydrated as crashed or failed after a daemon restart has no
        tail in memory (only errorSummary and terminalEvidence are persisted),
        so the first status read fills it and every later one serves that
        read; a new run clears it. */
    private func fillLogTailIfUnread() async {
        guard isTerminal, case .unread = recentLogTail else { return }
        let generation = runGeneration
        let tail = await readLogTail()
        guard generation == runGeneration, case .unread = recentLogTail else { return }
        recentLogTail = .read(tail)
    }

    private func statusSnapshot() -> ServerStatus {
        let check = EffectiveHealthcheck.resolve(spec: spec)
        let terminal = isTerminal
        let tail: [String]? =
            if terminal, case .read(let cached) = recentLogTail { cached } else { nil }
        let evidence = terminal ? (terminalEvidence ?? tail) : nil
        return ServerStatus(
            blockedOn: stallStreak >= 2 && phase == .crashed ? "interactive-auth" : nil,
            declaredPort: declaredPort ?? spec.port,
            effectivePort: effectivePort ?? spec.port,
            errorSummary: errorSummary,
            heads: spec.heads,
            healthcheck: check.kind,
            icon: spec.icon,
            lastExit: lastExit,
            lastHealthAt: lastHealthAt,
            locks: spec.locks.map { $0.map(\.name) },
            logPath: paths.structuredLogFile(project: projectPath, server: spec.name).path,
            mainProject: mainProjectSlug,
            observedPort: observedPort,
            phase: phase,
            pid: pid.map(Int.init),
            portConflict: portConflict,
            ports: namedPorts,
            project: projectPath,
            recentLogTail: tail,
            server: spec.name,
            spawnError: spawnError,
            specStale: specStaleFlag(),
            terminalEvidence: evidence,
            uptimeSec: startedAt.map { Int(Date().timeIntervalSince($0)) },
            url: spec.url,
            worktree: worktreeLabel
        )
    }

    // MARK: - Health monitoring

    private func startHealthMonitor() {
        healthTask?.cancel()
        let check = EffectiveHealthcheck.resolve(spec: spec)
        /** Default cadence when the spec sets no interval: probe every 2s. */
        let defaultHealthcheckIntervalMs = 2000
        let intervalMs = spec.healthcheck?.intervalMs ?? defaultHealthcheckIntervalMs
        /** With a real healthcheck, wait a short beat before the first probe so a
            server that binds immediately is not marked unhealthy on a startup
            blip; with no healthcheck, the resolved stabilization window is the
            delay instead. */
        let defaultInitialProbeDelayMs = 200
        let initialDelayMs: Int
        if case .none(let stabilizationMs) = check {
            initialDelayMs = stabilizationMs
        } else {
            initialDelayMs = defaultInitialProbeDelayMs
        }
        healthTask = Task { [prober, weak self] in
            try? await Task.sleep(for: .milliseconds(initialDelayMs))
            while !Task.isCancelled {
                let policy = await PowerState.shared.probePolicy()
                if case .skip = policy {
                    try? await Task.sleep(for: .milliseconds(intervalMs))
                    continue
                }
                let healthy = await prober.probe(check)
                guard !Task.isCancelled else { return }
                /** Failures inside the wake grace window carry no signal: the
                    machine (and the server) just woke up. */
                if case .ignoreFailures = policy, !healthy {
                    try? await Task.sleep(for: .milliseconds(intervalMs))
                    continue
                }
                await self?.recordProbe(success: healthy)
                try? await Task.sleep(for: .milliseconds(intervalMs))
            }
        }
    }

    private func recordProbe(success: Bool) async {
        /** Probes landing after the process died must not resurrect state. */
        guard phase == .starting || phase == .running || phase == .unhealthy else { return }
        if pid != nil {
            refreshDescendantSnapshot()
        }
        let healthyAfter = spec.healthcheck?.healthyAfter ?? 1
        let unhealthyAfter = spec.healthcheck?.unhealthyAfter ?? 3
        if success {
            consecutiveSuccesses += 1
            consecutiveFailures = 0
            lastHealthAt = Date()
            if !everHealthy {
                if consecutiveSuccesses >= healthyAfter {
                    everHealthy = true
                    /** A run that was verified healthy was not stalled; the
                        pattern the streak tracks belongs to the runs before it.
                        Gated on a real healthcheck: with none, "healthy" only
                        means the process was alive past the stabilization
                        window, which an auth-stalled server also is before it
                        dies, so resetting here would erase the streak every
                        cycle and the loop would never surface. */
                    if spec.healthcheck != nil { stallStreak = 0 }
                    phase = .running
                    DirectaLog.supervisor.info("healthy \(spec.name)@\(projectPath)")
                    scanObservedPort()
                    postHealthEvent(.healthy)
                }
            } else if phase == .unhealthy {
                phase = .running
                scanObservedPort()
                postHealthEvent(.healthy)
            }
        } else {
            consecutiveFailures += 1
            consecutiveSuccesses = 0
            /** unhealthyAfter applies only after first-healthy: a slow boot is
                `starting` until the deadline callers chose, never `unhealthy`. */
            if everHealthy, phase == .running, consecutiveFailures >= unhealthyAfter {
                phase = .unhealthy
                postHealthEvent(.unhealthy)
                /** The process is still writing, so snapshot the err tally at the
                    moment it degrades; a later recovery to running clears nothing,
                    so the count reflects the most recent unhealthy episode. */
                let generation = runGeneration
                let summary = await captureErrorSummary(since: startedAt)
                if generation == runGeneration { errorSummary = summary }
            }
        }
    }

    /** Post-healthy listen scan: dev servers auto-increment ports on conflict
        (Vite, Next), so the port actually listening is surfaced separately from
        the declared one. The run's own processes are the root plus the
        refreshed descendant snapshot, which keeps a worker that setsid'd and
        reparented away from the root's parent chain. */
    private func scanObservedPort() {
        guard let rootPid = pid else { return }
        refreshDescendantSnapshot()
        let pids = [rootPid] + lastDescendantSnapshot.map(\.pid)
        let expected = effectivePort ?? spec.port
        let generation = runGeneration
        Task { [weak self] in
            let ports = await PortGuard.listeningPorts(pids: pids)
            await self?.applyListenScan(
                expected: expected, generation: generation, ours: pids.map(Int.init),
                ports: ports)
        }
    }

    private func applyListenScan(
        expected: Int?, generation: UInt64, ours: [Int], ports: [Int]
    ) async {
        guard generation == runGeneration else { return }
        await recordObservedPort(generation: generation, ports: ports)
        guard let expected else { return }
        let owners = await PortGuard.listenerPids(port: expected)
        await recordPortOwnership(expected: expected, generation: generation, owners: owners, ours: ours)
    }

    /** The managed server whose recorded pid holds one of these listeners, if
        any. This is what separates "another directa server took the port" from
        "the listener is simply not my child", which look identical from lsof
        alone. Returns the server name and its project separately: the internal
        id is `<project>::<name>`, which is not a string to show a reader. */
    private func managedOwner(among foreign: [Int]) async -> (name: String, project: String)? {
        let candidates = Set(foreign)
        for (id, entry) in await registry.allPersistedState() where id != serverID {
            guard let pid = entry.pid, candidates.contains(pid) else { continue }
            /** A recorded pid is not an identity: macOS recycles pid numbers, so
                a stale row left by a killed daemon can name a pid that now
                belongs to something else entirely. Accusing on the number alone
                would blame an innocent server and take this one down with it.
                The recorded server's process must have started no later than the
                moment directa recorded it starting; a recycled pid was born long
                after. One second of slack covers the spawn-to-record gap. */
            guard let startedAt = entry.startedAt,
                let narrowed = ProcessTree.narrowed(pid),
                let identity = ProcessTree.identity(of: narrowed),
                ProcessTree.startTimeConsistent(
                    processStart: identity.wallClockStart, persistedStartedAt: startedAt, tolerance: 1),
                let parsed = parseServerID(id)
            else { continue }
            return parsed
        }
        return nil
    }

    /** A passing healthcheck proves something answered, never that this server
        answered. When every listener on the expected port sits outside this
        server's process tree, something else is serving on it.

        Two rules keep this from firing on healthy setups:

        Positive identification only. An empty listener list means lsof told us
        nothing, and lsof can be missing, restricted, or slow; treating silence
        as proof would fail healthy servers whenever the instrument is
        unavailable. Absence of evidence ends the check.

        Failing needs a named managed thief. A listener outside the process tree
        is not by itself a fault: a container-backed server (docker compose) or
        anything that daemonizes has its socket held by a process directa never
        parented, and killing those runs would be wrong. Only when the owning pid
        belongs to another server this daemon supervises is theft proven, and
        only then does the phase change. Everything else is annotated so a reader
        can see the ambiguity without the server being taken down for it. */
    private func recordPortOwnership(
        expected: Int, generation: UInt64, owners: [Int], ours: [Int]
    ) async {
        guard phase == .running || phase == .starting else { return }
        guard portConflict == nil else { return }
        guard !owners.isEmpty else { return }
        let mine = Set(ours)
        let foreign = owners.filter { !mine.contains($0) }
        guard !foreign.isEmpty else { return }
        let described = await BlockingLane.system.run {
            foreign.map { "pid \($0) (\(PortGuard.commandForPid($0)))" }.joined(separator: ", ")
        }
        let thief = await managedOwner(among: foreign)
        /** We hold a listener too, so the server is serving; the port is just
            not exclusively ours and a probe may reach either side. */
        if owners.contains(where: { mine.contains($0) }) {
            portConflict = PortConflict(
                declaredPort: declaredPort ?? expected,
                effectivePort: expected,
                holder: described,
                message:
                    "port \(expected) is held by this server and also by \(described); a health probe may reach either one",
                state: .shared)
            DirectaLog.supervisor.error(
                "port-shared \(spec.name)@\(projectPath) port \(expected) with \(described)")
            return
        }
        guard let thief else {
            /** Outside the tree but unattributable: could be this server's own
                container or daemonized helper. Say so, change nothing. */
            portConflict = PortConflict(
                declaredPort: declaredPort ?? expected,
                effectivePort: expected,
                holder: described,
                message:
                    "port \(expected) is held by \(described), which is outside this server's process tree; that is expected for a container-backed or daemonizing server, but a health probe cannot tell that apart from another process answering for it",
                state: .foreign)
            DirectaLog.supervisor.info(
                "port-foreign-unattributed \(spec.name)@\(projectPath) port \(expected) owned by \(described)")
            return
        }
        await failRun(
            conflict: PortConflict(
                declaredPort: declaredPort ?? expected,
                effectivePort: expected,
                holder: "\(thief.name)@\(thief.project)",
                message:
                    "healthcheck passed but managed server '\(thief.name)' in \(thief.project) owns port \(expected), not this server; run: directa stop \(ShellWord.argument(thief.name)) --project \(ShellWord.argument(thief.project))",
                state: .foreign),
            error: SpawnError(
                message: "port \(expected) is owned by managed server '\(thief.name)' in \(thief.project), so the healthcheck was answered by another directa server"),
            eventDetail: "port \(expected) owned by managed server '\(thief.name)' in \(thief.project)",
            generation: generation,
            logLine: "port-foreign \(spec.name)@\(projectPath) port \(expected) owned by \(thief.name)@\(thief.project)")
    }

    private func recordObservedPort(generation: UInt64, ports: [Int]) async {
        guard !ports.isEmpty else { return }
        let expected = effectivePort ?? spec.port
        let claimPorts = Set(portClaim?.allPorts ?? expected.map { [$0] } ?? [])
        if let expected, ports.contains(expected) {
            observedPort = expected
        } else if let claimed = ports.first(where: { claimPorts.contains($0) }) {
            observedPort = claimed
        } else {
            observedPort = ports.first
        }
        /** Strict bind: primary must match. Listeners on claimed secondaries are
            expected for composites; anything outside the claim is drift. */
        guard let expected, let observed = observedPort,
            phase == .running || phase == .starting
        else { return }
        if observed == expected || claimPorts.contains(observed) {
            if observed == expected { return }
            /** Secondary claimed port observed without primary: still require primary. */
            if ports.contains(expected) { return }
        }
        guard observed != expected else { return }
        await failRun(
            conflict: PortConflict(
                declaredPort: declaredPort ?? expected,
                effectivePort: expected,
                message:
                    "server listened on \(observed) instead of \(expected); add {port} to the command, set portEnv, or use --port / directa.local.json",
                state: .drift),
            error: SpawnError(message: "port drift: expected \(expected), observed \(observed)"),
            eventDetail: "port drift \(expected)->\(observed)",
            generation: generation,
            logLine: "port-drift \(spec.name)@\(projectPath) expected \(expected) observed \(observed)")
    }

    /** Fails a live run for a port reason, leaving its process running (the
        caller decides whether to stop it). The error tally and log tail are
        read first, then the whole failure lands in one step, and only while
        the run the scan was taken for is still the current one and has not
        ended or failed already: those reads are awaits, and a run that
        stopped or failed meanwhile has its own terminal state that must not
        be overwritten. */
    private func failRun(
        conflict: PortConflict, error: SpawnError, eventDetail: String, generation: UInt64,
        logLine: String
    ) async {
        let summary = await captureErrorSummary(since: startedAt)
        let tail = await readLogTail()
        guard generation == runGeneration,
            phase == .running || phase == .starting || phase == .unhealthy
        else { return }
        portConflict = conflict
        phase = .failed
        spawnError = error
        errorSummary = summary
        storeTerminalTail(tail)
        healthTask?.cancel()
        DirectaLog.supervisor.error(logLine)
        await events?.post(kind: .failed, project: projectPath, server: spec.name, detail: eventDetail)
        let evidence = terminalEvidence
        await registryUpdate { entry in
            entry.errorSummary = summary
            entry.phase = .failed
            entry.spawnError = error
            entry.terminalEvidence = evidence
        }
    }

    /** Log access for the router: queries and marks flow through the store so
        ordering against process output is exact. */
    public func logQuery(_ options: LogQueryOptions) async -> LogWindow {
        await logStore.window(options)
    }

    public func placeMark(label: String, text: String) async -> PlacedMark {
        let mark = await logStore.appendMark(label: label, text: text)
        await events?.post(kind: .marked, project: projectPath, server: spec.name, detail: "\(mark.id) \(text)")
        return PlacedMark(at: mark.at, id: mark.id, server: spec.name)
    }

    public func resolveMark(_ markID: String) async -> Date? {
        await logStore.resolveMark(markID)
    }

    private func postHealthEvent(_ kind: EventKind) {
        Task { [events, projectPath, name = spec.name] in
            await events?.post(kind: kind, project: projectPath, server: name)
        }
    }

    // MARK: - Internal bookkeeping

    private func effectiveArgv() -> [String] {
        if spec.shell == true {
            return ["/bin/zsh", "-lc", spec.command.joined(separator: " ")]
        }
        return spec.command
    }

    private func effectiveCwd() -> String {
        guard let cwd = spec.cwd, !cwd.isEmpty, cwd != "." else { return projectPath }
        return (projectPath as NSString).appendingPathComponent(cwd)
    }

    /** Clears everything the previous run left and enters `.starting`, the
        common opening of `start()` and `adopt()`. */
    private func resetForNewRun() {
        runGeneration += 1
        phase = .starting
        pendingStop = nil
        spawnError = nil
        errorSummary = nil
        terminalEvidence = nil
        everHealthy = false
        observedPort = nil
        recentLogTail = .unread
        lastDescendantSnapshot = []
        consecutiveFailures = 0
        consecutiveSuccesses = 0
        runningSpecHash = Self.specHash(spec)
    }

    private func startTailers(startAtEnd: Bool) async {
        let out = SpoolTailer(
            startAtEnd: startAtEnd, store: logStore, stream: .out,
            url: paths.spoolOutFile(project: projectPath, server: spec.name))
        let err = SpoolTailer(
            startAtEnd: startAtEnd, store: logStore, stream: .err,
            url: paths.spoolErrFile(project: projectPath, server: spec.name))
        outTailer = out
        errTailer = err
        await out.start()
        await err.start()
    }

    /** Everything a run whose pid is known gets once it is under supervision,
        spawned or adopted: its start time, tailers, the `started` log line and
        event, health and descendant watches, and a state row that restores it
        at the next boot. Settles the spawn waiters last. */
    private func beginSupervising(pid childPid: pid_t, startedAt runStartedAt: Date, as supervision: Supervision)
        async
    {
        startedAt = runStartedAt
        switch supervision {
        case .adopted:
            await startTailers(startAtEnd: true)
            await logStore.append(stream: .sys, text: "adopted pid=\(childPid)")
            await events?.post(
                kind: .started, project: projectPath, server: spec.name,
                detail: DaemonRestartDetail.adopted(pid: childPid))
        case .spawned:
            await startTailers(startAtEnd: false)
            await logStore.append(stream: .sys, text: "started pid=\(childPid)")
            await events?.post(kind: .started, project: projectPath, server: spec.name, detail: "pid \(childPid)")
        }
        startHealthMonitor()
        startDescendantWatch()
        await registryUpdate { entry in
            if case .adopted(let boundPort) = supervision { entry.boundPort = boundPort }
            entry.lastExit = nil
            entry.phase = .starting
            entry.pid = Int(childPid)
            entry.resumeOnBoot = true
            entry.spawnError = nil
            entry.startedAt = runStartedAt
        }
        spawnWaiters.settleAll()
    }

    private func recordSpawn(pid childPid: pid_t) async {
        pid = childPid
        /** Nil when a short-lived root was already reaped before this hop ran:
            teardown then never signals the group, and the lineage walk keys on
            the snapshot's ids alone. */
        rootIdentity = readIdentity(childPid)
        refreshDescendantSnapshot()
        if let removalReason {
            await stopRemovedSpawn(target: childPid, reason: removalReason)
            return
        }
        await beginSupervising(pid: childPid, startedAt: Date(), as: .spawned)
    }

    /** A pid that arrives after `stopForRemoval` (its stop gave up while the
        launcher had not published one yet): nothing supervises this run any
        more, so it is torn down instead of recorded, through the same passes
        as any stop. This runs inside the launcher's own spawn callback, and
        the run cannot finish until that returns, so it signals SIGTERM and
        leaves the SIGKILL escalation to a task after the grace rather than
        awaiting the exit. `recordOutcome` then lands `.stopped`, its state
        writes abandoned when the removal already gave up. */
    private func stopRemovedSpawn(target: pid_t, reason: String) async {
        let grace = stopTiming.graceSeconds
        let pass = await beginStop(target: target, reason: reason, deliberate: true, graceSeconds: grace)
        spawnWaiters.settleAll()
        Task {
            try? await Task.sleep(for: .seconds(grace))
            self.escalate(pass)
        }
    }

    /** The launcher learned of the process only after it had already exited
        (`childPid` is nil when launchd never showed one), so this run was
        never supervised. Starts the tailers from the top of the
        spool files so `recordOutcome` drains what the child wrote before
        dying, and stamps `startedAt` so the error tally brackets this run.
        Deliberately not `recordSpawn`: no pid is recorded (the number may
        already name another process, and the crash sweep would follow it), no
        `started` event, no health monitor, and no state write, so the boot
        intent stays whatever an earlier supervised run left. `recordOutcome`
        settles the spawn waiters. */
    private func recordExitedBeforeWatch(pid childPid: pid_t?) async {
        startedAt = Date()
        await startTailers(startAtEnd: false)
        let subject = childPid.map { "pid=\($0)" } ?? "process"
        await logStore.append(stream: .sys, text: "\(subject) exited before directa could watch it")
    }

    /** Merges rather than replaces. A refresh that runs after the root has
        exited but before `recordOutcome` walks a parent chain the root no
        longer heads, since its children reparent to launchd at exit, and
        replacing the snapshot with that empty walk would erase the only record
        of a setsid descendant, which neither the group nor the session
        reaches. An earlier entry stays while its pid still names the same
        process, so exited and recycled entries drop out and the snapshot never
        grows past the live tree. */
    private func refreshDescendantSnapshot() {
        guard let pid else { return }
        let fresh: [ProcessIdentity]
        switch ProcessTree.descendants(of: pid) {
        case .failed(let errno):
            DirectaLog.supervisor.error(
                "\(spec.name)@\(projectPath) could not read the process table to record the descendants of pid \(pid) (errno \(errno)); keeping the earlier record")
            fresh = []
        case .ok(let found):
            fresh = found
        }
        let freshPids = Set(fresh.map(\.pid))
        let stillLive = lastDescendantSnapshot.filter { recorded in
            !freshPids.contains(recorded.pid)
                && ProcessTree.shouldSignal(snapshotted: recorded, live: ProcessTree.identity(of: recorded.pid))
        }
        lastDescendantSnapshot = fresh + stillLive
    }

    /** Re-snapshots descendants across the startup window, which is the only
        stretch of a run where staleness is unbounded.

        Why a snapshot is the only thing that can work: a child that calls
        setsid or setpgid, and anything spawned through Foundation's `Process`,
        which does so on the caller's behalf, sits in its own process group, so
        the group-directed half of teardown cannot reach it. Once the root exits,
        its children reparent to launchd and no parent-pid walk can find them
        either. Whatever was recorded while the root still parented them is all
        teardown has.

        Servers commonly fork their workers a beat after starting, and until the
        first health probe nothing else refreshes the snapshot: with no
        healthcheck declared that first probe is a full stabilization window
        away, so one sample shortly after spawn would miss a worker that
        appeared in between, and a crash would orphan it for good. Health
        probes take over afterward, which bounds staleness to the probe
        interval for the rest of the run.

        The sweep is a whole-process-table sysctl measured at well under a
        millisecond, and this runs only while the server is still starting, so
        the cost is a handful of sweeps per run. */
    private func startDescendantWatch() {
        descendantTask?.cancel()
        let intervalMs = descendantWatchIntervalMs
        descendantTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(intervalMs))
                guard !Task.isCancelled, let self else { return }
                guard await self.refreshDescendantSnapshotWhileStarting() else { return }
            }
        }
    }

    /** Returns false once there is nothing left to watch, so the task ends
        rather than polling a server that is already running or gone. */
    private func refreshDescendantSnapshotWhileStarting() -> Bool {
        guard pid != nil, phase == .starting else { return false }
        refreshDescendantSnapshot()
        return true
    }

    /** Snapshot the err-stream tally for the run that just started at
        `windowStart`. Reads only from that point forward, so a crash loop reports
        the current incarnation rather than the whole log history. The read runs
        on `BlockingLane.system`, off this actor, and every line it must count
        is already written: a tailer's append reaches the file before it
        returns. */
    private func captureErrorSummary(since windowStart: Date?) async -> ErrorSummary? {
        let current = paths.structuredLogFile(project: projectPath, server: spec.name)
        return await BlockingLane.system.run {
            LogQuery.summarize(current: current, streams: [.err], since: windowStart)
        }
    }

    /** Last structured lines (out/err/sys), for crash/failure forensics, read
        through the log store so the read is ordered against its appends. */
    private func readLogTail(lines: Int = 40) async -> [String]? {
        let records = await logStore.query(LogQueryOptions(streams: [.err, .out, .sys], tail: lines))
        return records.isEmpty ? nil : records.map(\.contextLine)
    }

    /** Records `tail` as both the tail a terminal status shows and the
        evidence `why` reads. */
    private func storeTerminalTail(_ tail: [String]?) {
        recentLogTail = .read(tail)
        terminalEvidence = tail
    }

    private func recordSpawnFailure(_ error: SpawnError) async {
        spawnError = error
        await logStore.append(stream: .sys, text: "spawn failed: \(error.message)")
        await events?.post(kind: .failed, project: projectPath, server: spec.name, detail: error.message)
        pid = nil
        startedAt = nil
        runTask = nil
        healthTask?.cancel()
        healthTask = nil
        let tail = await readLogTail()
        storeTerminalTail(tail)
        let evidence = terminalEvidence
        await registryUpdate { entry in
            entry.phase = .failed
            entry.pid = nil
            entry.spawnError = error
            entry.startedAt = nil
            entry.terminalEvidence = evidence
        }
        phase = .failed
        spawnWaiters.settleAll()
    }

    private func recordOutcome(_ outcome: ProcessOutcome) async {
        runTask = nil
        /** Capture this run's teardown inputs before the awaits below: a
            concurrent start() can replace `pid` and the teardown keys while
            recordOutcome is suspended, and the crash sweep must act on the run
            that just exited, never on a newly started one. */
        let capturedPid = pid
        let capturedKeys = teardownKeys
        runGeneration += 1
        healthTask?.cancel()
        healthTask = nil
        switch outcome {
        case .spawnFailed(let error):
            await recordSpawnFailure(error)
            return
        case .exited(let code):
            lastExit = LastExit(at: Date(), code: code, signal: nil)
        case .exitedStatusUnknown:
            lastExit = LastExit(at: Date(), code: nil, signal: nil)
        case .signaled(let signal):
            lastExit = LastExit(at: Date(), code: nil, signal: signal)
        }
        let windowStart = startedAt
        if let out = outTailer { await out.stop() }
        if let err = errTailer { await err.stop() }
        outTailer = nil
        errTailer = nil
        /** After the final drain, so the lines that explain the exit are in the
            log before the snapshots are taken. */
        let tail = await readLogTail()
        storeTerminalTail(tail)
        errorSummary = await captureErrorSummary(since: windowStart)
        descendantTask?.cancel()
        descendantTask = nil
        lastDescendantSnapshot = []
        rootIdentity = nil
        pid = nil
        startedAt = nil
        observedPort = nil
        /** Read once, before the awaits below: whether directa's own stop()
            asked for THIS exit decides the boot intent, the event, and the
            descendant escalation, and `finalPhase` alone cannot tell, since an
            external graceful signal also lands `.stopped` without directa
            having asked. */
        let requestedStop = pendingStop
        /** SIGTERM, SIGINT, and SIGHUP are what a well-behaved external
            supervisor, an IDE stop button, or a forwarded Ctrl-C sends for a
            graceful shutdown; directa did not ask for it, but nothing else
            looks like a crash either. SIGKILL cannot be graceful (the process
            never runs its own handler for it), and neither can any other
            signal or a nonzero self-exit, so those stay `crashed`. */
        let externalGracefulSignal: Int? = {
            guard case .signaled(let signal) = outcome, requestedStop == nil else { return nil }
            return Self.externalGracefulSignals.contains(signal) ? signal : nil
        }()
        let finalPhase: ServerPhase =
            requestedStop != nil || externalGracefulSignal != nil ? .stopped : .crashed
        let exit = lastExit
        /** A deliberate stop retires the boot intent; a drain, an external
            signal, or a crash all keep whatever was recorded at start so the
            next boot restores it. */
        let retireIntent = requestedStop?.deliberate == true
        let cause = exit?.code.map { "code=\($0)" } ?? exit?.signal.map { "signal=\($0)" } ?? "unknown"
        await logStore.append(stream: .sys, text: "exited \(cause)")
        /** A directa-requested stop's detail says why directa asked it down
            (the reason stop() logged before signalling); an external graceful
            signal says the signal and that it came from outside directa, since
            nothing else in directa's own log explains it; a crash says how the
            process died. */
        let eventDetail: String
        if let requestedStop {
            eventDetail = requestedStop.reason
        } else if let externalGracefulSignal {
            eventDetail = ExternalSignalDetail.format(signal: externalGracefulSignal)
        } else {
            eventDetail = cause
        }
        await events?.post(
            kind: finalPhase == .stopped ? .stopped : .crashed,
            project: projectPath, server: spec.name, detail: eventDetail)
        let errors = errorSummary
        let evidence = finalPhase == .stopped ? nil : terminalEvidence
        if finalPhase == .stopped { terminalEvidence = nil }
        /** A run that exits on its own, nonzero, after tens of seconds and never
            passed a healthcheck is the shape of a start command waiting on an
            interactive credential prompt the daemon context cannot answer (a
            biometric unlock, a secrets CLI): the process sits silent, times
            out, and dies, and whoever called ensure retries into the same wall.
            Two in a row is the loop the operator is inside; one is noise. The
            window keeps a long-lived worker's eventual death and an instant
            failure (a compile error) out of the classification. */
        if finalPhase == .crashed, let exitCode = exit?.code, exitCode != 0,
            let windowStart,
            Double(stallBounds.minSeconds)...Double(stallBounds.maxSeconds)
                ~= Date().timeIntervalSince(windowStart),
            spec.healthcheck == nil || !everHealthy
        {
            stallStreak += 1
        } else {
            stallStreak = 0
        }
        let streak = stallStreak
        await registryUpdate { entry in
            entry.errorSummary = errors
            entry.lastExit = exit
            entry.phase = finalPhase
            entry.pid = nil
            entry.stallStreak = streak == 0 ? nil : streak
            if retireIntent { entry.resumeOnBoot = nil }
            entry.startedAt = nil
            entry.terminalEvidence = evidence
        }
        phase = finalPhase
        pendingStop = nil
        spawnWaiters.settleAll()
        /** An external graceful signal lands `.stopped` too, but directa's own
            stop() never ran its SIGTERM/SIGKILL escalation over this run's
            descendants, so they need the same sweep an ordinary crash gets or
            an orphaned worker can outlive it holding a listener. */
        if requestedStop == nil {
            await escalateCrashDescendants(rootPid: capturedPid, keys: capturedKeys)
        }
    }

    /** The crash path's counterpart to stop()'s SIGKILL escalation, and the one
        signalling path for a self-exit's descendants. A single SIGTERM pass is
        not enough: a descendant that ignores it (a disposition inherited across
        fork/exec when the root passed SIG_IGN down) survives holding its
        listeners, and the resume or ensure that comes after races it for the
        port and crashes. The root is already reaped, so the process group is
        never touched: the recorded root identity only seeds the lineage walk,
        and only the descendants that still match their recorded identity are
        swept, drawn from the snapshot, a parent-chain sweep, the session, and
        the lineage walk at once. Runs after the waiters settle so the short
        grace never delays a status answer, and the SIGKILL pass rides the
        prior pass's union so a descendant every live source has since lost is
        still re-signaled. */
    private func escalateCrashDescendants(rootPid: pid_t?, keys: TeardownKeys) async {
        guard let rootPid else { return }
        let pass = terminate(target: rootPid, keys: keys, signalGroup: false)
        try? await Task.sleep(for: .milliseconds(Self.crashEscalationGraceMilliseconds))
        escalate(pass)
    }

    /** How long a crashed run's descendants get to answer SIGTERM before the
        SIGKILL pass. Deliberately shorter than stop()'s seven-second grace: the
        phase is already published, so this only bounds how long an
        old-generation listener can compete with the next spawn. */
    nonisolated private static let crashEscalationGraceMilliseconds = 1_000

    /** The signals a graceful external stop can plausibly send: SIGTERM (the
        default `kill`), SIGINT (Ctrl-C forwarded to the child), SIGHUP (a
        terminal or controlling session going away). SIGKILL is deliberately
        excluded: a process cannot run a handler for it, so it can never be
        the polite half of a shutdown request. */
    nonisolated private static let externalGracefulSignals: Set<Int> = [
        Int(SIGHUP), Int(SIGINT), Int(SIGTERM),
    ]

    /** State persistence failures (full disk, permissions) must not kill the
        supervisor, but they must not vanish either: crash forensics silently
        missing is the suppression the repo rules forbid. */
    private func registryUpdate(_ mutate: @escaping @Sendable (inout PersistedServerState) -> Void) async {
        guard !stateWritesAbandoned else { return }
        do {
            try await registry.updateState(serverID: serverID, writer: .supervisor(writerID), mutate)
        } catch {
            FileHandle.standardError.write(
                Data("ddirecta: state persistence failed for \(serverID): \(error)\n".utf8))
        }
    }

    private static func specHash(_ spec: ServerSpec) -> String {
        guard let data = try? JSONCoding.encoder().encode(spec) else { return "" }
        return DirectaPaths.hash8(String(decoding: data, as: UTF8.self))
    }

    private func specStaleFlag() -> Bool? {
        guard pid != nil, let running = runningSpecHash else { return nil }
        return running == Self.specHash(spec) ? nil : true
    }

    /** Parks the caller on `list` while `pending` holds, until the transition
        settles the list or `timeout` expires this one waiter. `pending` is
        checked again inside the continuation closure, which closes the
        lost-wakeup window between the caller's own check and the
        registration. */
    private func park(
        on list: WaiterList, timeout: Duration?, activity kind: ActivityKind,
        while pending: () -> Bool
    ) async {
        let id = UUID()
        let activity = DaemonActivity.shared.begin(kind, label: serverID)
        defer { DaemonActivity.shared.end(activity, outcome: phase.rawValue) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard pending() else {
                continuation.resume()
                return
            }
            let deadlineTask = timeout.map { timeout in
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.expireWaiter(id: id, on: list)
                }
            }
            let waiter = PhaseWaiter(continuation: continuation, deadlineTask: deadlineTask, id: id)
            switch list {
            case .spawn: spawnWaiters.add(waiter)
            case .stopping: stoppingWaiters.add(waiter)
            }
        }
    }

    private func expireWaiter(id: UUID, on list: WaiterList) {
        switch list {
        case .spawn: spawnWaiters.expire(id: id)
        case .stopping: stoppingWaiters.expire(id: id)
        }
    }

    /** Blocks until the in-flight start has either produced a pid or gone
        terminal; the phase itself stays `starting` until first-healthy. A nil
        `timeout` waits for as long as the launcher takes, which `run` bounds
        on its own. Returns false only when the deadline fired first. */
    @discardableResult
    private func waitForSpawnSettled(timeout: Duration? = nil) async -> Bool {
        guard phase == .starting, pid == nil else { return true }
        await park(on: .spawn, timeout: timeout, activity: .spawnWait) {
            phase == .starting && pid == nil
        }
        return phase != .starting || pid != nil
    }

    /** Blocks until `phase` leaves `.stopping`, settled by its `didSet`
        wherever a stop's own recordOutcome (or a concurrent one for the same
        run) lands `.stopped`/`.crashed`. Waiting on the phase rather than on
        `runTask == nil` matters: `runTask` goes nil well before recordOutcome
        finishes draining the tailers and writing the registry, so a caller
        that resumed on that alone would recurse against a phase that had not
        actually moved.

        `timeout` bounds only the CALLER's wait: only recordOutcome ever
        moves `phase` off `.stopping`, so a caller whose deadline fires still
        reports an honest `.stopping`, never a phase this function invents.
        Every caller is bounded so a stop recordOutcome never lands on cannot
        hang the wire request that asked for it: `stop()` and `start()` by
        the stop's own wait bound, `ensure()` by its own timeout. Returns
        false only when the deadline fired first. */
    private func waitForStoppingToClear(timeout: Duration) async -> Bool {
        guard phase == .stopping else { return true }
        await park(on: .stopping, timeout: timeout, activity: .stopWait) { phase == .stopping }
        return phase != .stopping
    }

    /** A stop whose bounded wait expired: recorded in the server's sys stream
        (what `logs`, `why`, and `monitor` read) and as an OSLog error, which
        macOS persists. No event kind fits a stop still in flight. */
    private func recordStuckStop(after bound: Duration) async {
        let seconds = bound.components.seconds
        await logStore.append(
            stream: .sys,
            text: "stop did not complete within \(seconds)s; server may still be tearing down")
        DirectaLog.supervisor.error(
            "\(spec.name) stop did not complete within \(seconds)s; server may still be tearing down")
    }
}
