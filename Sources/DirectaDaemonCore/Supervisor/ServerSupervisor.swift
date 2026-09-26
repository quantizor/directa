import DirectaKit
import Foundation

/** One registration in `ServerSupervisor.stoppingWaiters`. `deadlineTask` is
    the sleeping task that calls `expireStoppingWaiter(id:)` if the real
    transition never lands first. */
private struct StoppingWaiter {
    let continuation: CheckedContinuation<Void, Never>
    let deadlineTask: Task<Void, Never>
    let id: UUID
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
    public let projectPath: String

    private var consecutiveFailures = 0
    private var errTailer: SpoolTailer?
    private let events: EventStore?
    private let logStore: LogStore
    private var outTailer: SpoolTailer?
    private var consecutiveSuccesses = 0
    /** Committed port before override/rebind; status.declaredPort. */
    private var declaredPort: Int?
    /** Error-stream tally for the current process, captured when the phase turns
        terminal or unhealthy rather than recomputed per status call. Cleared at
        spawn so a crash loop reports this incarnation, bracketed to the run's
        start, and persisted so it survives a daemon restart. */
    private var errorSummary: ErrorSummary?
    private var everHealthy = false
    /** What this run binds after override/rebind/materialization. */
    private var effectivePort: Int?
    private var healthTask: Task<Void, Never>?
    private var lastExit: LastExit?
    private var lastHealthAt: Date?
    private var lastDescendantSnapshot: [ProcessIdentity] = []
    /** Invalidates an in-flight listen scan when this run dies or a new one
        starts, so a late lsof cannot write observedPort onto the next spawn. */
    private var listenScanGeneration: UInt64 = 0
    /** Keeps the descendant snapshot fresh across the startup window; see
        startDescendantWatch. */
    private var descendantTask: Task<Void, Never>?
    /** Short enough that a worker forked a beat after startup is recorded before
        a crash can orphan it, and long enough that the sweeps cost nothing over
        a startup window. */
    private let descendantWatchIntervalMs = 200
    /** The run's session, recorded at spawn while the root is certainly alive.
        Read at teardown to find descendants that left the process group, which
        the parent-pid chain can no longer reach once the root has exited. */
    private var rootSessionID: pid_t?
    private let launcher: any ProcessLauncher
    /** Resolved named secondaries for this run (status.ports). */
    private var namedPorts: [String: Int]?
    private var observedPort: Int?
    private let paths: DirectaPaths
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
                settleStoppingWaiters()
            }
        }
    }
    private var pid: pid_t?
    private var portClaim: PortClaim?
    private var portConflict: PortConflict?
    private let prober: any HealthProber
    /** Captured once the phase turns terminal, not recomputed per status call:
        the log stops growing once the process is gone, so one read at the
        transition is both cheaper and a truer snapshot of the failure. The
        extra layer of Optional tells "not read since the last spawn" (outer
        nil) apart from "read, and the log family had nothing to show" (outer
        some, inner nil); collapsing those into one nil would make the second
        case look uncached and reread the whole log family on every status()
        call, which is exactly what a server rehydrated as crashed after a
        daemon restart does today (only errorSummary and terminalEvidence are
        persisted, so this starts uncached every time). */
    private var recentLogTail: [String]??
    private let registry: Registry
    private var runningSpecHash: String?
    private var runTask: Task<Void, Never>?
    private var spawnError: SpawnError?
    private var spawnWaiters: [CheckedContinuation<Void, Never>] = []
    private var spec: ServerSpec
    /** Waiters for `phase` leaving `.stopping`; settled by `phase`'s `didSet`.
        Modeled on `spawnWaiters`/`waitForSpawnSettled`/`settleSpawnWaiters`,
        with an id so a timed-out waiter (see `waitForStoppingToClear`) can be
        picked out of the array and resumed on its own, ahead of the real
        transition. */
    private var stoppingWaiters: [StoppingWaiter] = []
    /** Lifetime window a self-exit must land in to count toward the stall
        streak (see recordOutcome). Overridable so tests can use fast bounds. */
    private let stallBounds: (minSeconds: Int, maxSeconds: Int)
    private var stallStreak = 0
    private var startedAt: Date?
    /** Taken once the run has been alive for the settle window rather than at
        spawn, so a server that writes its own watched file while booting folds
        that write into the baseline instead of bouncing itself for it. */
    private var watchBaseline: WatchFingerprint?
    private var watchPending: (at: Date, stamp: WatchFingerprint)?
    /** Deliberately not cleared at spawn: the oscillation the breaker detects
        spans restarts by definition. */
    private var watchRestarts: [Date] = []
    private var watchSuspended = false
    /** Set once the router has dropped this supervisor after a stop that never
        finished: a late `recordOutcome` must not write a row the router has
        already retired or deleted. */
    private var stateWritesAbandoned = false
    private var stopRequested = false
    private let stopTiming: StopTiming
    /** The bound the stop in flight gives its own wait for the phase to
        clear (its grace plus `stopTiming.overtimeSeconds`), set when that stop
        moves the phase to `.stopping`. `start()` joining that stop waits no
        longer than the stop itself does. */
    private var stoppingWaitBound: Duration
    /** Carries the stop()'s intent into recordOutcome: deliberate clears the
        resume-on-boot flag, a launchd drain keeps it. */
    private var stopWasDeliberate = true
    /** Carries stop()'s reason into recordOutcome, which uses it as the
        `stopped` event's detail in place of the exit code: the code says how
        the process ended, never why directa asked it to. Always set together
        with stopRequested, so it is current whenever recordOutcome reads it. */
    private var stopReason = ""
    /** Durable why evidence across ensure truncate / daemon rehydrate. */
    private var terminalEvidence: [String]?
    /** Linked-worktree display identity, computed once at creation:
        status.worktree and status.mainProject. Nil for a main checkout; the
        pair never alters the host. */
    private var worktreeLabel: String?
    private var mainProjectSlug: String?

    public init(
        events: EventStore? = nil,
        launcher: any ProcessLauncher,
        paths: DirectaPaths,
        prober: any HealthProber = NetworkHealthProber(),
        projectPath: String,
        registry: Registry,
        spec: ServerSpec,
        stallBounds: (minSeconds: Int, maxSeconds: Int) = (10, 300),
        stopTiming: StopTiming = .standard
    ) {
        self.events = events
        self.launcher = launcher
        /** Match Registry's normalized state keys (`/var` vs `/private/var`). */
        let project = canonicalProjectPath(projectPath)
        self.logStore = LogStore(currentURL: paths.structuredLogFile(project: project, server: spec.name))
        self.paths = paths
        self.prober = prober
        self.projectPath = project
        self.registry = registry
        self.spec = spec
        self.stallBounds = stallBounds
        self.stopTiming = stopTiming
        self.stoppingWaitBound = .seconds(stopTiming.graceSeconds + stopTiming.overtimeSeconds)
        /** Computed once at creation, not per status read (it shells out to git)
            and not per spawn: a worktree project whose servers are stopped or
            restored still reports its label. */
        if let display = CheckoutIdentity.worktreeDisplay(project: project) {
            self.worktreeLabel = display.label
            self.mainProjectSlug = display.mainProject
        }
        let id = serverID(project: project, name: spec.name)
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

    public func clearBoundPortMeta() {        portConflict = nil
    }

    /** Starts the server if not already starting/running; otherwise joins the
        in-flight attempt. Returns once a pid exists or the spawn has failed; the
        phase stays `starting` until the healthcheck passes. */
    public func start() async -> ServerStatus {
        switch phase {
        case .running, .unhealthy:
            return status()
        case .starting:
            await waitForSpawnSettled()
            return status()
        case .stopping:
            /** Bounded like the stop being joined: a stop that never lands
                reports an honest `.stopping` here too, instead of holding
                this request (and the wire call behind it) forever. */
            guard await waitForStoppingToClear(timeout: stoppingWaitBound) else {
                return status()
            }
            return await start()
        case .crashed, .failed, .stopped:
            break
        }
        listenScanGeneration += 1
        phase = .starting
        stopRequested = false
        spawnError = nil
        errorSummary = nil
        terminalEvidence = nil
        everHealthy = false
        observedPort = nil
        recentLogTail = nil
        lastDescendantSnapshot = []
        consecutiveFailures = 0
        consecutiveSuccesses = 0
        runningSpecHash = Self.specHash(spec)
        let id = serverID(project: projectPath, name: spec.name)
        let argv = effectiveArgv()
        let cwd = effectiveCwd()
        let environment = spec.env ?? [:]
        let outURL = paths.spoolOutFile(project: projectPath, server: spec.name)
        let errURL = paths.spoolErrFile(project: projectPath, server: spec.name)
        do {
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            await recordSpawnFailure(SpawnError(errno: nil, message: "cannot create log directory: \(error)"), id: id)
            return status()
        }
        let outFD = open(outURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        let errFD = open(errURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard outFD >= 0, errFD >= 0 else {
            if outFD >= 0 { close(outFD) }
            if errFD >= 0 { close(errFD) }
            await recordSpawnFailure(
                SpawnError(errno: Int(errno), message: "cannot open spool: \(String(cString: strerror(errno)))"),
                id: id)
            return status()
        }
        runTask = Task { [launcher] in
            let outcome = await launcher.run(
                argv: argv,
                capture: SpawnCapture(
                    stderrFD: errFD, stderrPath: errURL.path, stdoutFD: outFD,
                    stdoutPath: outURL.path),
                cwd: cwd,
                environment: environment,
                onExitedBeforeWatch: { [weak self] childPid in
                    await self?.recordExitedBeforeWatch(pid: childPid)
                },
                onSpawn: { [weak self] childPid in
                    await self?.recordSpawn(pid: childPid, id: id)
                }
            )
            close(outFD)
            close(errFD)
            await self.recordOutcome(outcome, id: id)
        }
        await waitForSpawnSettled()
        return status()
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
        caller bounces the process instead. The result is a Bool rather than a
        status because the health monitor can promote a successful adopt to
        `.running` before this returns. The exit-watch task below is what
        closes the adoption hole: without it, a process this attaches to and
        later loses (the common second-jetsam-wave case, or an ordinary crash)
        would become an undetected zombie, since nothing else calls
        `recordOutcome` for a pid this instance never spawned. */
    public func adopt(
        pid childPid: pid_t, label: String, boundPort: Int?, startedAt runStartedAt: Date?
    ) async -> Bool {
        guard launcher.prepareAdopt(pid: childPid) else { return false }
        listenScanGeneration += 1
        phase = .starting
        stopRequested = false
        spawnError = nil
        errorSummary = nil
        terminalEvidence = nil
        everHealthy = false
        observedPort = nil
        recentLogTail = nil
        lastDescendantSnapshot = []
        consecutiveFailures = 0
        consecutiveSuccesses = 0
        runningSpecHash = Self.specHash(spec)
        let id = serverID(project: projectPath, name: spec.name)
        pid = childPid
        /** Same rationale as `recordSpawn`: read now, since `getsid` on a
            reaped pid answers -1 once the process is gone. */
        let session = getsid(childPid)
        rootSessionID = session > 0 ? session : nil
        refreshDescendantSnapshot()
        let spawnedAt = runStartedAt ?? Date()
        startedAt = spawnedAt
        let out = SpoolTailer(
            startAtEnd: true, store: logStore, stream: .out,
            url: paths.spoolOutFile(project: projectPath, server: spec.name))
        let err = SpoolTailer(
            startAtEnd: true, store: logStore, stream: .err,
            url: paths.spoolErrFile(project: projectPath, server: spec.name))
        outTailer = out
        errTailer = err
        await out.start()
        await err.start()
        await logStore.append(stream: .sys, text: "adopted pid=\(childPid)")
        await events?.post(
            kind: .started, project: projectPath, server: spec.name,
            detail: DaemonRestartDetail.adopted(pid: childPid))
        startHealthMonitor()
        startDescendantWatch()
        await registryUpdate(id: id) { entry in
            entry.boundPort = boundPort
            entry.lastExit = nil
            entry.phase = .starting
            entry.pid = Int(childPid)
            entry.resumeOnBoot = true
            entry.spawnError = nil
            entry.startedAt = spawnedAt
        }
        runTask = Task { [launcher] in
            let outcome = await launcher.adopt(pid: childPid, label: label)
            await self.recordOutcome(outcome, id: id)
        }
        settleSpawnWaiters()
        return true
    }

    /** The ensure state matrix: stopped/crashed/failed start fresh; starting joins
        the in-flight attempt; running and unhealthy are no-ops (unhealthy is
        reported, not restarted). Blocks until healthy, terminal, or timeout. */
    public func ensure(timeoutSeconds: Double) async -> EnsureResult {
        switch phase {
        case .running, .unhealthy:
            return EnsureResult(server: status())
        case .starting:
            break
        case .stopping:
            let budget = Self.boundedTimeoutSeconds(timeoutSeconds)
            let waitStart = ContinuousClock.now
            guard await waitForStoppingToClear(timeout: .seconds(budget)) else {
                return EnsureResult(reason: .timeout, server: status())
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
        return EnsureResult(reason: outcome, server: status())
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
        /** The overtime margin past the grace window: comfortably past the
            SIGKILL escalation below (which fires at the grace deadline) and
            past the crash path's own 1s escalation grace, so an ordinary
            teardown never trips this, and only a stop that is genuinely never
            landing (a bug elsewhere, or a child recordOutcome cannot reap)
            does. */
        let stopWaitTimeout = Duration.seconds(graceSeconds + stopTiming.overtimeSeconds)
        switch phase {
        case .stopped, .crashed, .failed:
            return status()
        case .stopping:
            if await !waitForStoppingToClear(timeout: stopWaitTimeout) {
                await recordStuckStop(after: stopWaitTimeout)
            }
            return status()
        case .starting, .running, .unhealthy:
            break
        }
        guard let target = pid else {
            phase = .stopped
            return status()
        }
        stopRequested = true
        stopWasDeliberate = deliberate
        stopReason = reason
        stoppingWaitBound = stopWaitTimeout
        phase = .stopping
        /** Capture the run's identity and its session before any signal and
            before any await: after the grace window the pid number may name a
            different process, recordOutcome for this same exit can run during the
            awaits below and clear the live fields, and signalRun revalidates
            against the captured identity so a recycled pid is never hit. The log
            append is itself an await (actor hop to logStore), so it runs after
            this capture too, not before it. */
        let rootIdentity = ProcessTree.identity(of: target)
        let sessionID = rootSessionID
        let snapshot = lastDescendantSnapshot
        await logStore.append(stream: .sys, text: "stopping: \(reason)")
        let signaled = signalRun(
            target: target, rootIdentity: rootIdentity, sessionID: sessionID,
            snapshot: snapshot, signal: SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: .seconds(graceSeconds))
        while ContinuousClock.now < deadline {
            if runTask == nil { break }
            if kill(target, 0) != 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        /** Escalate over a freshly re-derived union (new children may have
            appeared during the grace window) plus everything the SIGTERM pass
            already reached: a descendant that ignored that pass and then became
            invisible to every live source (setsid, the now-dead root's parent
            chain, younger than the snapshot) is still re-signaled, revalidated
            against its recorded identity. signalRun SIGKILLs the group only
            while the root still lives, and otherwise the survivors
            individually. */
        signalRun(
            target: target, rootIdentity: rootIdentity, sessionID: sessionID,
            snapshot: snapshot, signal: SIGKILL, priorSignaled: signaled)
        if await !waitForStoppingToClear(timeout: stopWaitTimeout) {
            await recordStuckStop(after: stopWaitTimeout)
        }
        return status()
    }

    /** A deliberate stop for a caller about to drop this supervisor (unregister,
        forgetting a vanished project). Returns true when the stop gave up with
        the phase still `.stopping`: state writes are then abandoned in the
        same actor turn the stop returned in, so a `recordOutcome` landing
        after the caller retires or deletes the state row cannot put it back.
        False means the stop finished and its own `recordOutcome` already
        cleared the boot intent. */
    public func stopForRemoval(reason: String) async -> Bool {
        _ = await stop(reason: reason)
        guard phase == .stopping else { return false }
        abandonStateWrites()
        return true
    }

    /** Stops every later state.json write from this supervisor. One already
        inside `Registry.updateState` can still land once; the caller's
        `Registry.retireState` or `removeState` is what settles the row. */
    public func abandonStateWrites() {
        stateWritesAbandoned = true
    }

    /** One revalidated teardown pass. Descendants come from every source at once
        (the startup snapshot, a fresh parent-chain sweep, and the root's session
        members), so a child that escaped the group by setpgid or setsid is still
        found. The root's process group is signaled only while `rootPid` still
        names the process `rootIdentity` recorded; once it has exited (or been
        recycled) the group is never touched and only the descendants that still
        match their recorded identity are signaled individually. Pass
        `rootIdentity: nil` from the crash path, where the root is already reaped,
        so `kill(-pid)` can never follow a recycled id. This is the one home for
        turning a run's descendants into kernel signals. Returns the identities
        it signaled, so an escalation pass can remember what to re-signal even
        after every live source has lost it. */
    @discardableResult
    private func signalRun(
        target: pid_t, rootIdentity: ProcessIdentity?, sessionID: pid_t?,
        snapshot: [ProcessIdentity], signal: Int32,
        priorSignaled: [ProcessIdentity] = []
    ) -> [ProcessIdentity] {
        let descendants = ProcessTree.liveDescendants(
            rootPid: target, sessionID: sessionID, snapshot: snapshot,
            priorSignaled: priorSignaled)
        ProcessTree.signalTree(
            descendants: descendants, revalidate: true, rootIdentity: rootIdentity,
            rootPid: target, signal: signal)
        return descendants
    }

    public func status() -> ServerStatus {
        let check = EffectiveHealthcheck.resolve(spec: spec)
        let terminal = phase == .crashed || phase == .failed
        /** The tail is captured once at the transition and served from memory. A
            server rehydrated as crashed after a daemon restart has none in memory
            (only errorSummary and terminalEvidence are persisted), so the first
            status() call after rehydrate reads the log family and every later
            call serves the cached result; start()/adopt() clear the cache at the
            next spawn. */
        let tail: [String]?
        if terminal {
            if let cached = recentLogTail {
                tail = cached
            } else {
                let read = spoolTail()
                recentLogTail = read
                tail = read
            }
        } else {
            tail = nil
        }
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
            delay instead. Unrelated to descendantWatchIntervalMs, which happens
            to share the value but paces the process-snapshot sweep. */
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

    private func recordProbe(success: Bool) {
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
                /** The process is still writing, so snapshot the err tally at the
                    moment it degrades; a later recovery to running clears nothing,
                    so the count reflects the most recent unhealthy episode. */
                errorSummary = captureErrorSummary(since: startedAt)
                postHealthEvent(.unhealthy)
            }
        }
    }

    /** Post-healthy listen scan: dev servers auto-increment ports on conflict
        (Vite, Next), so the port actually listening is surfaced separately from
        the declared one. */
    private func scanObservedPort() {
        guard let rootPid = pid else { return }
        let expected = effectivePort ?? spec.port
        let generation = listenScanGeneration
        Task { [weak self] in
            let pids = [rootPid] + ProcessTree.descendants(of: rootPid).pids
            let ports = PortGuard.listeningPorts(pids: pids)
            await self?.applyListenScan(
                expected: expected, generation: generation, ours: pids.map(Int.init),
                ports: ports)
        }
    }

    private func applyListenScan(
        expected: Int?, generation: UInt64, ours: [Int], ports: [Int]
    ) async {
        guard generation == listenScanGeneration else { return }
        await recordObservedPort(ports: ports)
        guard let expected else { return }
        let owners = PortGuard.listenerPids(port: expected)
        await recordPortOwnership(expected: expected, owners: owners, ours: ours)
    }

    /** The managed server whose recorded pid holds one of these listeners, if
        any. This is what separates "another directa server took the port" from
        "the listener is simply not my child", which look identical from lsof
        alone. Returns the server name and its project separately: the internal
        id is `<project>::<name>`, which is not a string to show a reader. */
    private func managedOwner(among foreign: [Int]) async -> (name: String, project: String)? {
        let myID = serverID(project: projectPath, name: spec.name)
        let candidates = Set(foreign)
        for (id, entry) in await registry.allPersistedState() where id != myID {
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
                let identity = ProcessTree.identity(of: narrowed)
            else { continue }
            let processStart = Date(timeIntervalSince1970: TimeInterval(identity.startSeconds))
            guard processStart <= startedAt.addingTimeInterval(1) else { continue }
            guard let parsed = parseServerID(id) else { continue }
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
    private func recordPortOwnership(expected: Int, owners: [Int], ours: [Int]) async {
        guard phase == .running || phase == .starting else { return }
        guard portConflict == nil else { return }
        guard !owners.isEmpty else { return }
        let mine = Set(ours)
        let foreign = owners.filter { !mine.contains($0) }
        guard !foreign.isEmpty else { return }
        let described = foreign
            .map { "pid \($0) (\(PortGuard.commandForPid($0)))" }
            .joined(separator: ", ")
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
        portConflict = PortConflict(
            declaredPort: declaredPort ?? expected,
            effectivePort: expected,
            holder: "\(thief.name)@\(thief.project)",
            message:
                "healthcheck passed but managed server '\(thief.name)' in \(thief.project) owns port \(expected), not this server; run: directa stop \(ShellWord.argument(thief.name)) --project \(ShellWord.argument(thief.project))",
            state: .foreign)
        phase = .failed
        spawnError = SpawnError(
            message: "port \(expected) is owned by managed server '\(thief.name)' in \(thief.project), so the healthcheck was answered by another directa server")
        errorSummary = captureErrorSummary(since: startedAt)
        let tail = spoolTail()
        recentLogTail = tail
        terminalEvidence = tail
        healthTask?.cancel()
        DirectaLog.supervisor.error(
            "port-foreign \(spec.name)@\(projectPath) port \(expected) owned by \(thief.name)@\(thief.project)")
        await events?.post(
            kind: .failed, project: projectPath, server: spec.name,
            detail: "port \(expected) owned by managed server '\(thief.name)' in \(thief.project)")
        let id = serverID(project: projectPath, name: spec.name)
        let summary = errorSummary
        let err = spawnError
        let evidence = terminalEvidence
        await registryUpdate(id: id) { entry in
            entry.errorSummary = summary
            entry.phase = .failed
            entry.spawnError = err
            entry.terminalEvidence = evidence
        }
    }

    private func recordObservedPort(ports: [Int]) async {
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
        portConflict = PortConflict(
            declaredPort: declaredPort ?? expected,
            effectivePort: expected,
            message:
                "server listened on \(observed) instead of \(expected); add {port} to the command, set portEnv, or use --port / directa.local.json",
            state: .drift)
        phase = .failed
        spawnError = SpawnError(message: "port drift: expected \(expected), observed \(observed)")
        errorSummary = captureErrorSummary(since: startedAt)
        let tail = spoolTail()
        recentLogTail = tail
        terminalEvidence = tail
        healthTask?.cancel()
        DirectaLog.supervisor.error(
            "port-drift \(spec.name)@\(projectPath) expected \(expected) observed \(observed)")
        await events?.post(
            kind: .failed, project: projectPath, server: spec.name,
            detail: "port drift \(expected)->\(observed)")
        let id = serverID(project: projectPath, name: spec.name)
        let summary = errorSummary
        let err = spawnError
        let evidence = terminalEvidence
        await registryUpdate(id: id) { entry in
            entry.errorSummary = summary
            entry.phase = .failed
            entry.spawnError = err
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

    public func currentSpec() -> ServerSpec {
        spec
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

    private func recordSpawn(pid childPid: pid_t, id: String) async {
        pid = childPid
        /** Read now rather than at teardown: once the root exits, getsid on its
            pid answers -1 and the escaped-descendant sweep loses its key. */
        let session = getsid(childPid)
        rootSessionID = session > 0 ? session : nil
        refreshDescendantSnapshot()
        let spawnedAt = Date()
        startedAt = spawnedAt
        let out = SpoolTailer(
            store: logStore, stream: .out,
            url: paths.spoolOutFile(project: projectPath, server: spec.name))
        let err = SpoolTailer(
            store: logStore, stream: .err,
            url: paths.spoolErrFile(project: projectPath, server: spec.name))
        outTailer = out
        errTailer = err
        await out.start()
        await err.start()
        await logStore.append(stream: .sys, text: "started pid=\(childPid)")
        await events?.post(kind: .started, project: projectPath, server: spec.name, detail: "pid \(childPid)")
        startHealthMonitor()
        startDescendantWatch()
        await registryUpdate(id: id) { entry in
            entry.lastExit = nil
            entry.phase = .starting
            entry.pid = Int(childPid)
            entry.resumeOnBoot = true
            entry.spawnError = nil
            entry.startedAt = spawnedAt
        }
        settleSpawnWaiters()
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
        let out = SpoolTailer(
            store: logStore, stream: .out,
            url: paths.spoolOutFile(project: projectPath, server: spec.name))
        let err = SpoolTailer(
            store: logStore, stream: .err,
            url: paths.spoolErrFile(project: projectPath, server: spec.name))
        outTailer = out
        errTailer = err
        await out.start()
        await err.start()
        let subject = childPid.map { "pid=\($0)" } ?? "process"
        await logStore.append(stream: .sys, text: "\(subject) exited before directa could watch it")
    }

    private func refreshDescendantSnapshot() {
        guard let pid else { return }
        lastDescendantSnapshot = ProcessTree.descendants(of: pid).identities
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

        A single sample shortly after spawn was not enough. Servers commonly
        fork their workers a beat after starting, and until the first health
        probe nothing else refreshed the snapshot: with no healthcheck declared
        that first probe is a full stabilization window away, so a worker that
        appeared in between was in no snapshot at all and a crash orphaned it for
        good. Health probes take over afterward, which bounds staleness to the
        probe interval for the rest of the run.

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
        the current incarnation rather than the whole log history. */
    private func captureErrorSummary(since windowStart: Date?) -> ErrorSummary? {
        LogQuery.summarize(
            current: paths.structuredLogFile(project: projectPath, server: spec.name),
            streams: [.err], since: windowStart)
    }

    private func recordSpawnFailure(_ error: SpawnError, id: String) async {
        spawnError = error
        await logStore.append(stream: .sys, text: "spawn failed: \(error.message)")
        await events?.post(kind: .failed, project: projectPath, server: spec.name, detail: error.message)
        pid = nil
        startedAt = nil
        runTask = nil
        healthTask?.cancel()
        healthTask = nil
        let tail = spoolTail()
        recentLogTail = tail
        terminalEvidence = tail
        let evidence = terminalEvidence
        await registryUpdate(id: id) { entry in
            entry.phase = .failed
            entry.pid = nil
            entry.spawnError = error
            entry.startedAt = nil
            entry.terminalEvidence = evidence
        }
        phase = .failed
        settleSpawnWaiters()
    }

    private func recordOutcome(_ outcome: ProcessOutcome, id: String) async {
        runTask = nil
        /** Capture this run's teardown inputs before the awaits below: a
            concurrent start() can replace `pid`, `rootSessionID`, and the
            snapshot while recordOutcome is suspended, and the crash sweep must
            act on the run that just exited, never on a newly started one. */
        let capturedPid = pid
        let capturedSessionID = rootSessionID
        let capturedSnapshot = lastDescendantSnapshot
        listenScanGeneration += 1
        healthTask?.cancel()
        healthTask = nil
        switch outcome {
        case .spawnFailed(let error):
            await recordSpawnFailure(error, id: id)
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
        let tail = spoolTail()
        recentLogTail = tail
        terminalEvidence = tail
        errorSummary = captureErrorSummary(since: windowStart)
        descendantTask?.cancel()
        descendantTask = nil
        lastDescendantSnapshot = []
        rootSessionID = nil
        pid = nil
        startedAt = nil
        observedPort = nil
        /** Read once, before the reset below: retireIntent and the descendant
            escalation both need to know whether directa's own stop() asked for
            THIS exit, which `finalPhase` alone can no longer tell them now that
            an external graceful signal also lands `.stopped`. */
        let wasStopRequested = stopRequested
        /** SIGTERM, SIGINT, and SIGHUP are what a well-behaved external
            supervisor, an IDE stop button, or a forwarded Ctrl-C sends for a
            graceful shutdown; directa did not ask for it, but nothing else
            looks like a crash either. SIGKILL cannot be graceful (the process
            never runs its own handler for it), and neither can any other
            signal or a nonzero self-exit, so those stay `crashed`. */
        let externalGracefulSignal: Int? = {
            guard case .signaled(let signal) = outcome, !wasStopRequested else { return nil }
            return Self.externalGracefulSignals.contains(signal) ? signal : nil
        }()
        let finalPhase: ServerPhase =
            wasStopRequested || externalGracefulSignal != nil ? .stopped : .crashed
        stopRequested = false
        let exit = lastExit
        /** A deliberate stop retires the boot intent; a drain, an external
            signal, or a crash all keep whatever was recorded at start so the
            next boot restores it. Gated on `wasStopRequested`, not
            `finalPhase`: an external signal now also lands `.stopped` without
            directa having asked for it, and must not retire an intent nobody
            expressed. */
        let retireIntent = wasStopRequested && finalPhase == .stopped && stopWasDeliberate
        let cause = exit?.code.map { "code=\($0)" } ?? exit?.signal.map { "signal=\($0)" } ?? "unknown"
        await logStore.append(stream: .sys, text: "exited \(cause)")
        /** A directa-requested stop's detail says why directa asked it down
            (the reason stop() logged before signalling); an external graceful
            signal says the signal and that it came from outside directa, since
            nothing else in directa's own log explains it; a crash says how the
            process died. */
        let eventDetail: String
        if wasStopRequested {
            eventDetail = stopReason
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
        await registryUpdate(id: id) { entry in
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
        settleSpawnWaiters()
        /** Gated on `wasStopRequested`, not `finalPhase`: an external graceful
            signal now also lands `.stopped`, but directa's own stop() never
            ran its SIGTERM/SIGKILL escalation over this run's descendants, so
            they need the same sweep an ordinary crash gets or an orphaned
            worker can outlive it holding a listener. */
        if !wasStopRequested {
            await escalateCrashDescendants(
                rootPid: capturedPid, sessionID: capturedSessionID,
                snapshot: capturedSnapshot)
        }
    }

    /** The crash path's counterpart to stop()'s SIGKILL escalation, and the one
        signalling path for a self-exit's descendants. A self-exit used to get
        exactly one SIGTERM pass, so a descendant that ignored it (a disposition
        inherited across fork/exec when the root passed SIG_IGN down) or that
        outlived the next restart survived holding its listeners, and the resume
        or ensure that came after raced it for the port and crashed: the
        lingering-inspector-port failure. The root is already reaped, so
        `rootIdentity` is nil and the process group is never touched: only the
        descendants that still match their recorded identity are swept, drawn
        from the snapshot, a parent-chain sweep, and the session at once. Runs
        after the waiters settle so the short grace never delays a status
        answer, and the SIGKILL pass rides the prior pass's union so a
        descendant every live source has since lost is still re-signaled. */
    private func escalateCrashDescendants(
        rootPid: pid_t?, sessionID: pid_t?, snapshot: [ProcessIdentity]
    ) async {
        guard let rootPid else { return }
        let signaled = signalRun(
            target: rootPid, rootIdentity: nil, sessionID: sessionID,
            snapshot: snapshot, signal: SIGTERM)
        try? await Task.sleep(for: .milliseconds(Self.crashEscalationGraceMilliseconds))
        signalRun(
            target: rootPid, rootIdentity: nil, sessionID: sessionID,
            snapshot: snapshot, signal: SIGKILL, priorSignaled: signaled)
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
    private func registryUpdate(id: String, _ mutate: @escaping @Sendable (inout PersistedServerState) -> Void) async {
        guard !stateWritesAbandoned else { return }
        do {
            try await registry.updateState(serverID: id, mutate)
        } catch {
            FileHandle.standardError.write(
                Data("ddirecta: state persistence failed for \(id): \(error)\n".utf8))
        }
    }

    private func settleSpawnWaiters() {
        let waiters = spawnWaiters
        spawnWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func settleStoppingWaiters() {
        let waiters = stoppingWaiters
        stoppingWaiters = []
        for waiter in waiters {
            waiter.deadlineTask.cancel()
            waiter.continuation.resume()
        }
    }

    /** The bounded half of `waitForStoppingToClear`: picks its own waiter out
        of the array by id and resumes it alone, leaving every other
        registration (an unrelated caller's unbounded join, or another bounded
        wait with a later deadline) untouched. A no-op once the real
        transition already settled and removed this id first: the two can
        never both resume the same continuation because both run as
        actor-isolated methods and never interleave. */
    private func expireStoppingWaiter(id: UUID) {
        guard let index = stoppingWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = stoppingWaiters.remove(at: index)
        waiter.continuation.resume()
    }

    private static func specHash(_ spec: ServerSpec) -> String {
        guard let data = try? JSONCoding.encoder().encode(spec) else { return "" }
        return DirectaPaths.hash8(String(decoding: data, as: UTF8.self))
    }

    private func specStaleFlag() -> Bool? {
        guard pid != nil, let running = runningSpecHash else { return nil }
        return running == Self.specHash(spec) ? nil : true
    }

    /** Last structured lines (out/err/sys), for crash/failure forensics. */
    private func spoolTail(lines: Int = 40) -> [String]? {
        let records = LogQuery.run(
            current: paths.structuredLogFile(project: projectPath, server: spec.name),
            options: LogQueryOptions(streams: [.err, .out, .sys], tail: lines))
        return records.isEmpty ? nil : records.map(\.contextLine)
    }

    /** Blocks until the in-flight start has either produced a pid or gone
        terminal; the phase itself stays `starting` until first-healthy. */
    private func waitForSpawnSettled() async {
        guard phase == .starting, pid == nil else { return }
        await withCheckedContinuation { continuation in
            if phase != .starting || pid != nil {
                continuation.resume()
            } else {
                spawnWaiters.append(continuation)
            }
        }
    }

    /** Blocks until `phase` leaves `.stopping`, settled by its `didSet`
        wherever a stop's own recordOutcome (or a concurrent one for the same
        run) lands `.stopped`/`.crashed`. Replaces polling `runTask == nil`,
        which flips well before recordOutcome finishes draining the tailers and
        writing the registry, so a caller that resumed on that alone would
        recurse against a phase that had not actually moved. Checks phase again
        inside the continuation closure to guard the same lost-wakeup window
        `waitForSpawnSettled` guards.

        `timeout` bounds only the CALLER's wait: only recordOutcome ever
        moves `phase` off `.stopping`, so a caller whose deadline fires still
        reports an honest `.stopping`, never a phase this function invents.
        Every caller is bounded so a stop recordOutcome never lands on cannot
        hang the wire request that asked for it: `stop()` and `start()` by
        the stop's own wait bound, `ensure()` by its own timeout. Returns
        false only when the deadline fired first. */
    private func waitForStoppingToClear(timeout: Duration) async -> Bool {
        guard phase == .stopping else { return true }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard phase == .stopping else {
                continuation.resume()
                return
            }
            let deadlineTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expireStoppingWaiter(id: id)
            }
            stoppingWaiters.append(
                StoppingWaiter(continuation: continuation, deadlineTask: deadlineTask, id: id))
        }
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
