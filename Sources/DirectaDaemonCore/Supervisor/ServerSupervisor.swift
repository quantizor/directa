import DirectaKit
import Foundation

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
    private var phase: ServerPhase = .stopped
    private var pid: pid_t?
    private var portClaim: PortClaim?
    private var portConflict: PortConflict?
    private let prober: any HealthProber
    /** Captured when the phase turns terminal, not recomputed per status call:
        the log stops growing once the process is gone, so one read at the
        transition is both cheaper and a truer snapshot of the failure. */
    private var recentLogTail: [String]?
    private let registry: Registry
    private var runningSpecHash: String?
    private var runTask: Task<Void, Never>?
    private var spawnError: SpawnError?
    private var spawnWaiters: [CheckedContinuation<Void, Never>] = []
    private var spec: ServerSpec
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
    private var stopRequested = false
    /** Carries the stop()'s intent into recordOutcome: deliberate clears the
        resume-on-boot flag, a launchd drain keeps it. */
    private var stopWasDeliberate = true
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
        stallBounds: (minSeconds: Int, maxSeconds: Int) = (10, 300)
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
            await waitForRunTaskCompletion()
            return await start()
        case .crashed, .failed, .stopped:
            break
        }
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
            await waitForRunTaskCompletion()
            return await ensure(timeoutSeconds: timeoutSeconds)
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
        machine coming back up restores what was running. */
    public func stop(graceSeconds: Double = 7, deliberate: Bool = true) async -> ServerStatus {
        switch phase {
        case .stopped, .crashed, .failed:
            return status()
        case .stopping:
            await waitForRunTaskCompletion()
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
        phase = .stopping
        /** Capture the run's identity and its session before any signal and
            before any await: after the grace window the pid number may name a
            different process, recordOutcome for this same exit can run during the
            awaits below and clear the live fields, and signalRun revalidates
            against the captured identity so a recycled pid is never hit. */
        let rootIdentity = ProcessTree.identity(of: target)
        let sessionID = rootSessionID
        let snapshot = lastDescendantSnapshot
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
        await waitForRunTaskCompletion()
        return status()
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
            (only errorSummary is persisted), so fall back to a live read there,
            which matches the pre-capture behavior for that narrow case. */
        let tail = terminal ? (recentLogTail ?? spoolTail()) : nil
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
        Task { [weak self] in
            let pids = [rootPid] + ProcessTree.descendants(of: rootPid).pids
            let ports = PortGuard.listeningPorts(pids: pids)
            await self?.recordObservedPort(ports: ports)
            guard let expected else { return }
            let owners = PortGuard.listenerPids(port: expected)
            await self?.recordPortOwnership(
                expected: expected, owners: owners, ours: pids.map(Int.init))
        }
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
            /** Split from the back: the project is an absolute path and the name
                never contains the separator. */
            guard let separator = id.range(of: "::", options: .backwards) else { continue }
            return (
                name: String(id[separator.upperBound...]),
                project: String(id[id.startIndex..<separator.lowerBound])
            )
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
                "healthcheck passed but managed server '\(thief.name)' in \(thief.project) owns port \(expected), not this server; run: directa stop \(thief.name) --project \(thief.project)",
            state: .foreign)
        phase = .failed
        spawnError = SpawnError(
            message: "port \(expected) is owned by managed server '\(thief.name)' in \(thief.project), so the healthcheck was answered by another directa server")
        errorSummary = captureErrorSummary(since: startedAt)
        recentLogTail = spoolTail()
        terminalEvidence = recentLogTail
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
        recentLogTail = spoolTail()
        terminalEvidence = recentLogTail
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
    public func logQuery(_ options: LogQueryOptions) async -> [LogRecord] {
        await logStore.query(options)
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
        recentLogTail = spoolTail()
        terminalEvidence = recentLogTail
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
        healthTask?.cancel()
        healthTask = nil
        switch outcome {
        case .spawnFailed(let error):
            await recordSpawnFailure(error, id: id)
            return
        case .exited(let code):
            lastExit = LastExit(at: Date(), code: code, signal: nil)
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
        recentLogTail = spoolTail()
        terminalEvidence = recentLogTail
        errorSummary = captureErrorSummary(since: windowStart)
        descendantTask?.cancel()
        descendantTask = nil
        lastDescendantSnapshot = []
        rootSessionID = nil
        pid = nil
        startedAt = nil
        observedPort = nil
        let finalPhase: ServerPhase = stopRequested ? .stopped : .crashed
        stopRequested = false
        let exit = lastExit
        /** A deliberate stop retires the boot intent; a drain (or a crash) keeps
            whatever was recorded at start so the next boot restores it. */
        let retireIntent = finalPhase == .stopped && stopWasDeliberate
        let cause = exit?.code.map { "code=\($0)" } ?? exit?.signal.map { "signal=\($0)" } ?? "unknown"
        await logStore.append(stream: .sys, text: "exited \(cause)")
        await events?.post(
            kind: finalPhase == .stopped ? .stopped : .crashed,
            project: projectPath, server: spec.name, detail: cause)
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
        await escalateCrashDescendants(
            id: id, rootPid: capturedPid, sessionID: capturedSessionID,
            snapshot: capturedSnapshot)
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
        id: String, rootPid: pid_t?, sessionID: pid_t?, snapshot: [ProcessIdentity]
    ) async {
        guard let rootPid, !stopRequested else { return }
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

    /** State persistence failures (full disk, permissions) must not kill the
        supervisor, but they must not vanish either: crash forensics silently
        missing is the suppression the repo rules forbid. */
    private func registryUpdate(id: String, _ mutate: @escaping @Sendable (inout PersistedServerState) -> Void) async {
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

    private func waitForRunTaskCompletion() async {
        if let task = runTask { await task.value }
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
}
