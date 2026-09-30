import DirectaKit
import Foundation
@preconcurrency import Network
import os

/** Routes decoded requests to the registry and supervisor pool. One instance per
    daemon; connection handling fans out but every method lands here. */
public actor Router {
    /** Live launchd job control, present only when this process is the
        SMAppService agent. Its absence is what makes the adoption pid match
        and the leftover-job reap in `recoverAtStartup` fail closed to a plain
        bounce+respawn: a test or `ddirecta --foreground` never gets real
        launchd side effects, no matter what it injects, because there is
        nothing to call. See `AgentJobs`. */
    private let agentJobs: AgentJobs?
    private let events: EventStore
    private let launcher: any ProcessLauncher
    private let paths: DirectaPaths
    private let portProbe: PortProbe
    private let registry: Registry
    /** Handed to every supervisor this router creates. */
    private let stopTiming: StopTiming
    private var supervisors: [String: ServerSupervisor] = [:]
    /** devservers.json views cached by mtime; a save invalidates naturally. */
    private var configCache: [String: (mtime: Date, view: ProjectConfigView)] = [:]
    /** Held resource locks keyed `project::resource`. Persisted to locks.json so
        a daemon crash mid-hold can still resume the paused servers when the
        holder is gone. Stale holders (dead pids) evaporate on access. */
    private var resourceLocks: [String: LockHolder] = [:]
    /** Machine kill switch for the watch sweep, for the moment someone wants
        their server to stop bouncing right now. An init parameter so tests can
        set it without touching the environment. */
    private let watchEnabled: Bool
    /** True from before the listener accepts until boot restore has finished.
        Defaults to false so a directly constructed Router (every test, and any
        embedder) serves immediately; only the daemon's boot sequence raises it. */
    private var restoring = false

    public init(
        agentJobs: AgentJobs? = LaunchdJobLauncher.runningAsAgent ? .live : nil,
        launcher: any ProcessLauncher, paths: DirectaPaths, portProbe: PortProbe = .live,
        registry: Registry,
        stopTiming: StopTiming = .standard,
        watchEnabled: Bool = ProcessInfo.processInfo.environment[WatchPolicy.disableEnvironmentKey] != "1"
    ) {
        self.agentJobs = agentJobs
        self.watchEnabled = watchEnabled
        self.events = EventStore(url: paths.eventsFile)
        self.launcher = launcher
        self.paths = paths
        self.portProbe = portProbe
        self.registry = registry
        self.stopTiming = stopTiming
        self.resourceLocks =
            Self.normalizedLocks(
                AtomicFile.loadDefensively(LocksFile.self, from: paths.locksFile)?.locks ?? [:])
    }

    /** Raised before the listener accepts and lowered once `recoverAtStartup`
        returns. Two explicit calls rather than a flag hidden inside recovery,
        because the window has to open earlier than recovery starts: the whole
        point is that a client connecting before then gets an answer. */
    public func setRestoring(_ value: Bool) {
        restoring = value
    }

    /** Everything that reads or changes supervised state is refused while boot
        restore runs, since the state is half rebuilt and a caller acting on it
        would draw the wrong conclusion. `daemon.info` is how a client learns
        that is why, and `daemon.shutdown` is the way out of a restore that
        never finishes. */
    public static func isServableWhileRestoring(_ method: WireMethod) -> Bool {
        switch method {
        case .daemonInfo, .daemonShutdown:
            return true
        default:
            return false
        }
    }

    private static func lockKey(project: String, resource: String) -> String {
        "\(canonicalProjectPath(project))::\(resource)"
    }

    private static func normalizedLocks(_ locks: [String: LockHolder]) -> [String: LockHolder] {
        var out: [String: LockHolder] = [:]
        for (key, holder) in locks {
            guard let separator = key.range(of: "::") else {
                out[key] = holder
                continue
            }
            let project = String(key[key.startIndex..<separator.lowerBound])
            let resource = String(key[separator.upperBound...])
            out[lockKey(project: project, resource: resource)] = holder
        }
        return out
    }

    /** Decodes the typed request for `method` and returns the encoded response
        frame. Any thrown WireError becomes the error envelope; anything else maps
        to internal-error so a client never sees a bare hang. */
    public func handle(line: Data) async -> Data {
        await handle(line: line, head: try? JSONCoding.decoder().decode(WireRequestHead.self, from: line))
    }

    /** `head` is `line`'s already-decoded `{id, method}`, nil when it did not
        decode, for a caller that read it first. */
    public func handle(line: Data, head: WireRequestHead?) async -> Data {
        let decoder = JSONCoding.decoder()
        guard let head else {
            return (try? NDJSON.encodeLine(
                WireResponse<WireEmpty>(
                    error: WireError(code: .usage, message: "unparseable request frame"),
                    id: "?", ok: false))) ?? Data()
        }
        do {
            guard let method = WireMethod(rawValue: head.method) else {
                throw WireError(code: .usage, message: WireError.unknownMethodMessage(head.method))
            }
            guard !restoring || Self.isServableWhileRestoring(method) else {
                throw WireError(
                    code: .daemonStarting,
                    hint: "run: directa daemon status",
                    message: "the daemon is still restoring supervised servers and is not serving requests yet")
            }
            switch method {
            case .daemonInfo:
                return try respond(id: head.id, result: await daemonInfo())
            case .daemonShutdown:
                let frame = try respond(id: head.id, result: WireEmpty())
                Task { [weak self] in
                    guard let self else { return }
                    await self.drainAll()
                    /** Deliberate shutdown stays down: the intent marker keeps
                        auto-bootstrap from resurrecting the daemon, and exit 0
                        satisfies KeepAlive={SuccessfulExit:false}. */
                    try? Data().write(to: self.paths.stoppedIntentFile)
                    await self.exitDaemon()
                }
                return frame
            case .serverRegister:
                let request = try decoder.decode(WireRequest<RegisterParams>.self, from: line)
                let project = canonicalProjectPath(request.params.project)
                /** register validates like a committed spec: a spec `config check`
                    would reject must not be spawnable through this seam. */
                let specErrors = request.params.spec.validationErrors()
                guard specErrors.isEmpty else {
                    throw WireError(
                        code: .configInvalid,
                        hint: "run: directa config check",
                        message: specErrors.joined(separator: "; "))
                }
                try await registry.register(project: project, spec: request.params.spec)
                let supervisor = await supervisor(project: project, spec: request.params.spec)
                await events.post(
                    kind: .registered, project: project, server: request.params.spec.name)
                return try respond(id: head.id, result: ServerResult(server: await supervisor.status()))
            case .serverEnsure:
                let request = try decoder.decode(WireRequest<EnsureParams>.self, from: line)
                let project = canonicalProjectPath(request.params.project)
                let target = ServerTargetParams(
                    name: request.params.name, port: request.params.port, project: project)
                let supervisor = try await resolvedSupervisor(target)
                try await prepareSpawn(
                    target: target, supervisor: supervisor, portOverride: request.params.port,
                    userInitiated: true)
                let result = await supervisor.ensure(timeoutSeconds: request.params.timeoutSeconds)
                DirectaLog.daemon.info(
                    "ensure \(target.name)@\(project) -> \(result.server.phase.rawValue)")
                return try respond(id: head.id, result: result)
            case .serverStart:
                let request = try decoder.decode(WireRequest<ServerTargetParams>.self, from: line)
                let project = canonicalProjectPath(request.params.project)
                let target = ServerTargetParams(
                    name: request.params.name, port: request.params.port, project: project)
                let supervisor = try await resolvedSupervisor(target)
                try await prepareSpawn(
                    target: target, supervisor: supervisor, portOverride: request.params.port,
                    userInitiated: true)
                return try respond(id: head.id, result: ServerResult(server: await supervisor.start()))
            case .serverStatus:
                let request = try decoder.decode(WireRequest<ProjectParams>.self, from: line)
                /** Empty project means machine-wide; do not canonicalize it or it
                    becomes the daemon cwd and the sweep never runs. */
                let project = request.params.project.isEmpty
                    ? ""
                    : canonicalProjectPath(request.params.project)
                let params = ProjectParams(name: request.params.name, project: project)
                return try respond(id: head.id, result: try await statusList(params))
            case .projectTrust:
                let request = try decoder.decode(WireRequest<ProjectOnlyParams>.self, from: line)
                try await registry.setTrusted(
                    project: canonicalProjectPath(request.params.project))
                return try respond(id: head.id, result: WireEmpty())
            case .projectForget:
                let request = try decoder.decode(WireRequest<ProjectOnlyParams>.self, from: line)
                /** Canonicalized like every other arm: the recorded key is
                    already canonical and canonicalizes to itself after its
                    directory is gone, so the `project` string a prior
                    `server.status` returned, or any spelling that resolves to
                    it, reaches every piece of the teardown. */
                let project = canonicalProjectPath(request.params.project)
                guard await registry.project(project) != nil else {
                    throw WireError(
                        code: .notFound,
                        hint: "run: directa status --json",
                        message: "\(project) is not a project directa tracks")
                }
                guard !FileManager.default.fileExists(atPath: project) else {
                    throw WireError(
                        code: .projectStillExists,
                        hint: "run: directa status --json",
                        message: "\(project) still exists on disk; forgetting it would drop trust for a live checkout")
                }
                let servers = await forgetMissingProject(project)
                return try respond(id: head.id, result: ProjectForgetResult(servers: servers))
            case .logsRemoveOrphan:
                let request = try decoder.decode(WireRequest<LogsRemoveOrphanParams>.self, from: line)
                return try respond(
                    id: head.id, result: await removeOrphanLogDirectory(named: request.params.directory))
            case .projectCheck:
                let request = try decoder.decode(WireRequest<ProjectOnlyParams>.self, from: line)
                let project = canonicalProjectPath(request.params.project)
                let url = ProjectConfigLoader.configURL(project: project)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return try respond(
                        id: head.id,
                        result: CheckResult(
                            errors: [
                                "no devservers.json at \(url.path) (run: directa config init)"
                            ]))
                }
                do {
                    guard let view = try ProjectConfigLoader.load(project: project) else {
                        return try respond(
                            id: head.id, result: CheckResult(errors: ["cannot read \(url.path)"]))
                    }
                    let hosts = await effectiveHosts(project: project, view: view)
                    let worktree = await CheckoutIdentity.worktreeDisplay(project: project)
                    return try respond(
                        id: head.id,
                        result: CheckResult(
                            errors: view.errors,
                            host: view.host,
                            serverHosts: hosts.isEmpty ? nil : hosts,
                            servers: view.specs.map(\.name),
                            warnings: view.warnings,
                            worktree: worktree?.label))
                } catch let error as WireError {
                    return try respond(id: head.id, result: CheckResult(errors: [error.message]))
                }
            case .projectInitConfig:
                let request = try decoder.decode(WireRequest<InitConfigParams>.self, from: line)
                return try respond(id: head.id, result: try await initConfig(request.params))
            case .projectWriteConfig:
                let request = try decoder.decode(WireRequest<WriteConfigParams>.self, from: line)
                let project = canonicalProjectPath(request.params.project)
                let url = ProjectConfigLoader.configURL(project: project)
                /** writeConfig edits a project's committed config in place, so it
                    may only target a project directa already tracks or one whose
                    devservers.json already exists. Without this a wire client
                    could hand any path and AtomicFile.write, which creates
                    intermediate directories, would drop a devservers.json
                    anywhere on disk. Creating a config for a brand-new project is
                    `config init`, not this method. */
                let known = await registry.project(project) != nil
                let configExists = FileManager.default.fileExists(atPath: url.path)
                guard known || configExists else {
                    throw WireError(
                        code: .notFound,
                        hint: "run: directa config init in the project, or register a server there first",
                        message: "refusing to write devservers.json for a project directa does not track: \(project)")
                }
                let currentHash = (try? Data(contentsOf: url)).map {
                    DirectaPaths.hash8(String(decoding: $0, as: UTF8.self))
                } ?? ""
                guard currentHash == request.params.baselineHash else {
                    throw WireError(
                        code: .configInvalid,
                        hint: "reload the file and re-apply your edit",
                        message: "devservers.json changed on disk since it was loaded (an editor or another session saved it)")
                }
                let parsed: ProjectFileConfig
                do {
                    parsed = try JSONCoding.decoder().decode(
                        ProjectFileConfig.self, from: Data(request.params.content.utf8))
                } catch {
                    throw ProjectConfigLoader.configError(from: error, at: url)
                }
                let view = ProjectConfigLoader.validate(config: parsed, project: project)
                guard view.errors.isEmpty else {
                    throw WireError(
                        code: .configInvalid,
                        hint: "run: directa config check",
                        message: view.errors.joined(separator: "; "))
                }
                try AtomicFile.write(Data(request.params.content.utf8), to: url)
                configCache[project] = nil
                return try respond(
                    id: head.id,
                    result: CheckResult(
                        host: view.host, servers: view.specs.map(\.name), warnings: view.warnings))
            case .groupUp:
                let request = try decoder.decode(WireRequest<GroupParams>.self, from: line)
                var params = request.params
                params.project = canonicalProjectPath(params.project)
                return try respond(id: head.id, result: try await groupUp(params))
            case .groupDown:
                let request = try decoder.decode(WireRequest<GroupParams>.self, from: line)
                var params = request.params
                params.project = canonicalProjectPath(params.project)
                return try respond(id: head.id, result: try await groupDown(params))
            case .serverStop:
                let request = try decoder.decode(WireRequest<ServerTargetParams>.self, from: line)
                let target = ServerTargetParams(
                    name: request.params.name, port: request.params.port,
                    project: canonicalProjectPath(request.params.project))
                let supervisor = try await resolvedSupervisor(target)
                let stopped = await supervisor.stop(reason: "requested by stop")
                DirectaLog.daemon.info("stop \(target.name)@\(target.project)")
                return try respond(id: head.id, result: ServerResult(server: stopped))
            case .serverRestart:
                let request = try decoder.decode(WireRequest<RestartParams>.self, from: line)
                var params = request.params
                params.project = canonicalProjectPath(params.project)
                return try respond(
                    id: head.id,
                    result: try await restartServers(
                        params, reason: "requested by restart", userInitiated: true))
            case .serverWait:
                let request = try decoder.decode(WireRequest<WaitParams>.self, from: line)
                let target = ServerTargetParams(
                    name: request.params.name,
                    project: canonicalProjectPath(request.params.project))
                let supervisor = try await resolvedSupervisor(target)
                let reason = await supervisor.wait(
                    for: request.params.condition, timeoutSeconds: request.params.timeoutSeconds)
                return try respond(
                    id: head.id, result: EnsureResult(reason: reason, server: await supervisor.status()))
            case .lockAcquire:
                let request = try decoder.decode(WireRequest<LockParams>.self, from: line)
                var params = request.params
                params.project = canonicalProjectPath(params.project)
                let result = try await acquireLock(params)
                return try respond(id: head.id, result: result)
            case .lockStatus:
                let request = try decoder.decode(WireRequest<LockStatusParams>.self, from: line)
                let params = LockStatusParams(
                    project: canonicalProjectPath(request.params.project),
                    resource: request.params.resource)
                return try respond(id: head.id, result: await lockStatus(params))
            case .lockRelease:
                let request = try decoder.decode(WireRequest<LockParams>.self, from: line)
                var params = request.params
                params.project = canonicalProjectPath(params.project)
                let result = try await releaseLock(params)
                return try respond(id: head.id, result: result)
            case .logsQuery:
                let request = try decoder.decode(WireRequest<LogsQueryParams>.self, from: line)
                let target = ServerTargetParams(
                    name: request.params.name,
                    project: canonicalProjectPath(request.params.project))
                if let refusal = request.params.refusal() { throw refusal }
                let supervisor = try await resolvedSupervisor(target)
                var since = request.params.since
                if let markID = request.params.sinceMark {
                    guard let markDate = await supervisor.resolveMark(markID) else {
                        throw WireError(
                            code: .notFound,
                            hint: "run: directa logs \(ShellWord.argument(request.params.name)) --stream mark",
                            message: "no mark with id '\(markID)' in \(request.params.name)'s log")
                    }
                    since = markDate
                }
                let window = await supervisor.logQuery(LogQueryOptions(request.params, since: since))
                return try respond(
                    id: head.id,
                    result: LogsQueryResult(cursor: window.cursor, lines: window.lines, totals: window.totals))
            case .logsMark:
                let request = try decoder.decode(WireRequest<MarkParams>.self, from: line)
                let project = canonicalProjectPath(request.params.project)
                let label = request.params.label ?? "cli"
                var marks: [PlacedMark] = []
                if request.params.all == true {
                    for spec in await registry.specs(project: project) {
                        let supervisor = await supervisor(project: project, spec: spec)
                        marks.append(await supervisor.placeMark(label: label, text: request.params.text))
                    }
                } else if let name = request.params.name {
                    let target = ServerTargetParams(name: name, project: project)
                    let supervisor = try await resolvedSupervisor(target)
                    marks.append(await supervisor.placeMark(label: label, text: request.params.text))
                } else {
                    throw WireError(code: .usage, message: "mark needs a server name or --all")
                }
                return try respond(id: head.id, result: MarkResult(marks: marks))
            case .eventsQuery:
                let request = try decoder.decode(WireRequest<EventsQueryParams>.self, from: line)
                if let refusal = request.params.refusal() { throw refusal }
                /** Empty/nil project means machine-wide; only a real project path
                    is canonicalized, matching how EventStore.query keys the feed. */
                let project = request.params.project.map(canonicalProjectPath)
                var since = request.params.since
                if let markID = request.params.sinceMark, let project {
                    for spec in await registry.specs(project: project) {
                        let supervisor = await supervisor(project: project, spec: spec)
                        if let markDate = await supervisor.resolveMark(markID) {
                            since = markDate
                            break
                        }
                    }
                    if since == nil, request.params.since == nil {
                        throw WireError(
                            code: .notFound,
                            message: "no mark with id '\(markID)' in this project's logs")
                    }
                }
                let events = await events.query(
                    project: project, since: since, tail: request.params.tail)
                return try respond(id: head.id, result: EventsQueryResult(events: events))
            case .serverWhy:
                let request = try decoder.decode(WireRequest<ServerTargetParams>.self, from: line)
                let project = canonicalProjectPath(request.params.project)
                let target = ServerTargetParams(name: request.params.name, project: project)
                _ = try await resolvedSupervisor(target)
                let merged = try await mergedSpecs(project: project)
                var statuses: [String: ServerStatus] = [:]
                for status in await annotatedStatuses(merged.specs.map { (project: project, spec: $0) }) {
                    statuses[status.server] = status
                }
                let specsByName = Dictionary(uniqueKeysWithValues: merged.specs.map { ($0.name, $0) })
                let paths = self.paths
                /** One shot at the project's event history, read before the
                    diagnosis runs rather than from inside a closure `describe`
                    calls per server: `EventStore.query` is an actor method,
                    `WhyEngine` stays a plain synchronous rule engine over data
                    the caller already assembled. Read only when a server
                    stopped by a signal, the one finding that consults it, since
                    the query decodes the whole events log. Last write per
                    server wins, which is the most recent `stopped` event since
                    `query` returns oldest first. */
                var lastStoppedDetail: [String: String] = [:]
                if statuses.values.contains(where: { $0.phase == .stopped && $0.lastExit?.signal != nil }) {
                    for event in await events.query(project: project) where event.kind == .stopped {
                        if let detail = event.detail {
                            lastStoppedDetail[event.server] = detail
                        }
                    }
                }
                let result = WhyEngine.diagnose(
                    target: request.params.name,
                    statuses: statuses,
                    specs: specsByName,
                    evidenceLines: { server in
                        let since =
                            statuses[server]?.lastExit?.at
                            ?? statuses[server]?.uptimeSec.map {
                                Date().addingTimeInterval(TimeInterval(-$0))
                            }
                        return LogQuery.run(
                            current: paths.structuredLogFile(project: project, server: server),
                            options: LogQueryOptions(
                                since: since, streams: [.err, .out, .sys], tail: 40)
                        ).map(\.contextLine)
                    },
                    lastStopDetail: { lastStoppedDetail[$0] })
                return try respond(id: head.id, result: result)
            case .serverUnregister:
                let request = try decoder.decode(WireRequest<ServerTargetParams>.self, from: line)
                /** Canonicalized like every other project-scoped method: the
                    supervisor pool is keyed on canonical paths, so a symlinked
                    or trailing-slash spelling from the app or a deep link
                    dropped the registry row and left the supervisor resident. */
                let project = canonicalProjectPath(request.params.project)
                let name = request.params.name
                /** A name declared only in the project's committed
                    devservers.json was never written into the registry, so
                    unregistering it is not the no-op `Registry.unregister`
                    makes of it: the caller asked to remove something specific
                    and nothing by that name is there to remove. */
                guard await registry.spec(project: project, name: name) != nil else {
                    throw WireError(
                        code: .notFound,
                        hint: "run: directa status --json",
                        message: "'\(name)' is not registered as an ad hoc server for \(project)")
                }
                let id = serverID(project: project, name: name)
                /** A server still running when it is unregistered must be
                    stopped through the normal stop path first, awaiting its
                    actual exit: dropping the supervisor while it keeps running
                    leaves an unmanaged process alive. `stop()` no-ops
                    instantly for one already terminal, so this costs nothing
                    on the common path. Either way the row ends with no boot
                    intent, or a server also declared in devservers.json comes
                    back on the next daemon launch: a stop that gave up short
                    of a terminal phase never reached the `recordOutcome` that
                    clears it, so its row is retired; a finished one may have
                    joined a restart's non-deliberate stop, which keeps it, so
                    it is cleared. The supervisor is dropped before the registry
                    write, so a failed write still leaves no removed supervisor
                    resident to answer every later start of this name as
                    stopped. */
                let stopGaveUp =
                    await removeSupervisor(
                        id: id, name: name, project: project, reason: RemovalReason.unregistered)
                    == .gaveUp
                if !stopGaveUp {
                    await clearBootIntent(name: name, project: project)
                }
                try await registry.unregister(project: project, name: name)
                await events.post(kind: .unregistered, project: project, server: name)
                /** A stop that gave up may leave the process still writing
                    into the log directory, so it stays; doctor's leftover-log
                    finding covers it once nothing claims it. */
                if !stopGaveUp {
                    await removeLogDirIfProjectIsForgotten(project)
                }
                return try respond(id: head.id, result: WireEmpty())
            }
        } catch let error as WireError {
            return (try? NDJSON.encodeLine(WireResponse<WireEmpty>(error: error, id: head.id, ok: false)))
                ?? Data()
        } catch {
            let wrapped = WireError(code: .internalError, message: String(describing: error))
            return (try? NDJSON.encodeLine(WireResponse<WireEmpty>(error: wrapped, id: head.id, ok: false)))
                ?? Data()
        }
    }

    /** Drain-stops every supervisor in parallel: a serial drain of N servers at
        up to 7s grace each would blow through launchd's ExitTimeOut. The drain
        is not a deliberate stop: resume-on-boot intent survives so the next
        boot restores what was running. */
    public func drainAll() async {
        await withTaskGroup(of: Void.self) { group in
            for supervisor in supervisors.values {
                group.addTask {
                    _ = await supervisor.stop(deliberate: false, reason: "daemon shutting down")
                }
            }
        }
    }

    /** How long a project's checkout path must be observed continuously
        missing before it is forgotten, and how often the daemon's timer sweep
        checks: one rule for every automatic trigger (boot restore, machine-wide
        status, the timer sweep), so a fast poller (the app's machine-wide
        status, every 2s) cannot forget a project any sooner than the timer
        sweep would, and a network mount blip or a slow unmount never costs a
        project its trust and log history. */
    public static let missingProjectSweepIntervalSeconds: Double = 30

    /** First-observed-missing timestamp per project path, cleared the moment a
        stat succeeds again. Shared by every caller of `pruneMissingProjects`. */
    private var missingProjectFirstMissedAt: [String: Date] = [:]

    /** Projects `forgetMissingProject` is tearing down right now. */
    private var forgetting: Set<String> = []

    /** Forget registered projects whose checkout path has been missing for at
        least `missingProjectSweepIntervalSeconds`, continuously, across
        however many callers ask: boot restore, machine-wide status, and the
        timer sweep all funnel through this one debounced rule. Boot restore
        is the first call of a daemon's life, so it can only record a first
        miss, never forget. Forgetting stops children, bounces orphan pids,
        and drops registry/state/locks/supervisors. `now` is a parameter
        rather than `Date()` read inline so tests can move time forward
        without sleeping. */
    @discardableResult
    public func pruneMissingProjects(now: Date = Date()) async -> Int {
        var pruned = 0
        let projects = await registry.allProjects()
        missingProjectFirstMissedAt = missingProjectFirstMissedAt.filter { projects.contains($0.key) }
        for project in projects {
            let exists = FileManager.default.fileExists(atPath: project)
            switch MissingProjectPolicy.decide(
                exists: exists, firstMissedAt: missingProjectFirstMissedAt[project], now: now,
                sweepIntervalSeconds: Self.missingProjectSweepIntervalSeconds)
            {
            case .present:
                missingProjectFirstMissedAt[project] = nil
            case .waiting(let since):
                missingProjectFirstMissedAt[project] = since
            case .forget:
                missingProjectFirstMissedAt[project] = nil
                await forgetMissingProject(project)
                pruned += 1
            }
        }
        return pruned
    }

    /** Startup recovery: record a first miss for each vanished checkout (the
        forget itself waits for a later sweep), reconcile persisted locks,
        then restore servers with boot intent. A recorded pid that is
        still a registered launchd child job (agent mode only) is adopted: its
        exit is re-watched through the shared `ExitWatcher` feeding
        `recordOutcome`, and its health is re-monitored, so a jetsam SIGKILL of
        the daemon no longer bounces a dev server that never actually died. A
        recorded pid that is gone, or live but without a kernel start time
        consistent with the recorded one (a recycled number), becomes
        crashed(daemon-restart) and is never signaled; a proven live orphan
        that is not a matching launchd child job (foreground/test mode, or a
        pid launchd never knew about) is group-killed instead, since there is
        no launchd job label to bootout once a fresh watch on it fires. A row
        with no restore intent that still names a proven live run (a removal
        whose stop gave up) is only bounced. What comes back:
        any server whose start intent survives (resumeOnBoot), which a machine
        shutdown's drain leaves set, plus the classic daemon-crash case of a
        phase left running/starting. A deliberate stop clears the flag, so only
        those stay down. Servers still paused under a live resource lock are left
        alone: starting them would fight the harness.

        Specs resolve through the merged view (devservers.json + ad-hoc registry),
        the same path ensure/status use. Config-defined servers are never written
        into registry.json, so a registry-only lookup would silently skip every
        committed server on boot. A rename/delete with no matching spec drops the
        orphaned state row instead of retrying forever.

        Adoption bypasses `prepareSpawn`'s trust gate deliberately: it re-attaches
        to a process a prior *trusted* daemon already spawned, acting on
        `state.json` rather than re-materializing a project's committed config,
        so it never opens the untrusted-config surface `userInitiated` guards.
        `reconcileLocksAtStartup` above does not assume a supervised child is
        dead: it only reconciles locks held by external harness processes, a
        different identity than the server pid adoption re-attaches to. */
    public func recoverAtStartup() async {
        await pruneMissingProjects()
        await reconcileLocksAtStartup()
        /** Loaded once per boot restore, not per server: `launchctl list` is a
            shell-out, and every server's adoption check and the leftover-job
            reap at the end need the same snapshot. Empty outside agent mode
            (`agentJobs == nil`), which is what makes every match below fail
            closed to the pre-existing bounce+respawn path; nil in agent mode
            when launchd gave no answer, which defers instead. */
        var listed: [LaunchdJobs.ChildJob]? = []
        var adoptableChildJobs: [pid_t: LaunchdJobs.ChildJob] = [:]
        if let agentJobs {
            listed = await Self.childJobsForRecovery(agentJobs)
            adoptableChildJobs = Dictionary(
                (listed ?? []).compactMap { job in job.pid.map { ($0, job) } },
                uniquingKeysWith: { first, _ in first })
        }
        var toStart: [(project: String, spec: ServerSpec)] = []
        for (id, persisted) in await registry.allPersistedState() {
            guard let parsed = parseServerID(id) else { continue }
            let project = parsed.project
            let name = parsed.name
            /** `pruneMissingProjects` above only forgets a path missing for a
                full sweep interval, so a project on its first miss is still
                here to iterate. Boot restore must never spawn (or adopt, or
                bounce) a server for a project that is not on disk right now,
                even mid-debounce: the automatic sweep will finish forgetting
                it on its own schedule. */
            guard FileManager.default.fileExists(atPath: project) else {
                DirectaLog.daemon.info("recover skip \(name)@\(project): project path is missing")
                continue
            }
            let leftActive = persisted.phase == .running || persisted.phase == .starting
            let wantsRestore = persisted.resumeOnBoot ?? false
            guard persisted.pid != nil || leftActive || wantsRestore else { continue }
            if isPausedUnderLiveLock(project: project, name: name) {
                DirectaLog.daemon.info(
                    "recover skip \(name)@\(project): paused under a live resource lock")
                continue
            }
            switch await resolveSpecForRecover(project: project, name: name) {
            case .missing:
                DirectaLog.daemon.info(
                    "recover skip \(name)@\(project): no matching spec (renamed or removed)")
                /** Nothing will supervise this name again, so a recorded run
                    still alive is bounced before its row goes, with the same
                    start-time proof adoption needs: a recycled pid is left
                    alone. */
                if let identity = ProcessTree.provenIdentity(
                    pid: persisted.pid, startedAt: persisted.startedAt)
                {
                    await bounceOrphan(identity, project: project, name: name)
                }
                try? await registry.removeState(serverID: id)
                continue
            case .unavailable:
                DirectaLog.daemon.info(
                    "recover defer \(name)@\(project): config unreadable; keeping resume intent")
                continue
            case .found(let spec):
                let restores = leftActive || wantsRestore
                /** A bare pid match is not proof: the number may have been
                    recycled during the daemon-down window (a reboot hands it
                    to an unrelated app, and the pid space is only ~100k wide).
                    Adopting or bouncing it is mutative, so both need the
                    kernel start time to be consistent with the moment this
                    pid was last recorded running. Without that proof the
                    process is someone else's and is never signaled; the
                    recorded run is treated as gone. */
                if let identity = ProcessTree.provenIdentity(
                    pid: persisted.pid, startedAt: persisted.startedAt)
                {
                    /** Without a job listing, whether this run is an adoptable
                        child job is unknown, and bouncing it would stop a
                        server recovery may well have kept. The row stays as
                        it is for the next boot to decide. */
                    if restores, listed == nil {
                        DirectaLog.daemon.error(
                            "recover defer \(name)@\(project): launchd's job list is unavailable; leaving live pid \(identity.pid) alone")
                        continue
                    }
                    /** A row with no restore intent (a removal whose stop gave
                        up retired it) keeps its pid only so its leftover run
                        can be bounced here: it is never adopted or restarted. */
                    if restores, let job = adoptableChildJobs[identity.pid],
                        await adoptSurvivor(
                            boundPort: persisted.boundPort, job: job, name: name, pid: identity.pid,
                            project: project, spec: spec, startedAt: persisted.startedAt)
                    {
                        continue
                    }
                    await bounceOrphan(identity, project: project, name: name)
                } else if leftActive {
                    await events.post(
                        kind: .crashed, project: project, server: name,
                        detail: DaemonRestartDetail.crashed)
                }
                guard restores else {
                    try? await registry.updateState(serverID: id, writer: .router) { entry in
                        entry.pid = nil
                        entry.startedAt = nil
                    }
                    continue
                }
                try? await registry.updateState(serverID: id, writer: .router) { entry in
                    entry.lastExit = entry.lastExit ?? LastExit(at: Date())
                    entry.phase = .crashed
                    entry.pid = nil
                    entry.startedAt = nil
                }
                toStart.append((project: project, spec: spec))
            }
        }
        for item in toStart {
            let supervisor = await self.supervisor(project: item.project, spec: item.spec)
            do {
                try await self.prepareSpawn(
                    target: ServerTargetParams(name: item.spec.name, project: item.project),
                    supervisor: supervisor)
            } catch let error as WireError {
                DirectaLog.daemon.error(
                    "recover skip \(item.spec.name)@\(item.project): \(error.message)")
                continue
            } catch {
                DirectaLog.daemon.error(
                    "recover skip \(item.spec.name)@\(item.project): \(error.localizedDescription)")
                continue
            }
            DirectaLog.daemon.info("recover start \(item.spec.name)@\(item.project)")
            _ = await supervisor.start()
        }
        /** Second pass: drop leftover rows for renamed/deleted servers even when
            they carry no resume intent (e.g. a deliberate stop under the old
            name). Only when the config is readable so a parse blip cannot wipe
            state. */
        for (id, _) in await registry.allPersistedState() {
            guard let parsed = parseServerID(id) else { continue }
            let project = parsed.project
            let name = parsed.name
            /** Same guard as the first pass: a project mid-debounce (missing,
                but not yet forgotten) must not have its state rows read as
                orphaned just because its config is unreadable right now. */
            guard FileManager.default.fileExists(atPath: project) else { continue }
            if case .missing = await resolveSpecForRecover(project: project, name: name) {
                DirectaLog.daemon.info("recover prune \(name)@\(project): orphaned state row")
                try? await registry.removeState(serverID: id)
            }
        }
        /** SIGKILL of the agent (jetsam) skips LaunchdJobLauncher's defer
            bootout, so one-shot child labels accumulate in the gui domain.
            Reap only when `agentJobs` is set: tests and `--foreground` never
            registered those jobs and have no `AgentJobs` value to reap
            through, so they never touch a real launchd domain, the user's
            included. The listing is the one taken before restore, so a job a
            restore started just now is never in it; `keepingPids` protects
            every listed job a supervisor adopted. With no listing there is
            nothing to judge stale. */
        if let agentJobs, let listed {
            var keepingPids: Set<pid_t> = []
            for supervisor in supervisors.values {
                if let pid = await supervisor.status().pid.flatMap(ProcessTree.narrowed) {
                    keepingPids.insert(pid)
                }
            }
            let staleJobs = LaunchdJobs.stale(listed, keepingPids: keepingPids)
            for job in staleJobs {
                await agentJobs.bootOut(job)
            }
            if !staleJobs.isEmpty {
                DirectaLog.daemon.info("reaped \(staleJobs.count) leftover child launchd job(s)")
            }
        }
    }

    /** The child jobs recovery judges adoption and the leftover reap on, or
        nil when `launchctl list` gave no answer twice: one retry covers a
        launchd that was briefly slow at boot, and a second failure defers
        every decision that needs the listing rather than reading it as "no
        jobs", which would bounce every survivor recovery could have kept. */
    private static func childJobsForRecovery(_ agentJobs: AgentJobs) async -> [LaunchdJobs.ChildJob]? {
        for attempt in 1...2 {
            switch await agentJobs.listChildJobs() {
            case .listed(let jobs):
                return jobs
            case .unavailable(let reason):
                DirectaLog.daemon.error("recover: launchd job list attempt \(attempt) of 2 failed: \(reason)")
            }
        }
        return nil
    }

    /** Attaches a fresh supervisor to a launchd child job (`job`) that survived
        the daemon's own jetsam SIGKILL, instead of the bounce+respawn
        `recoverAtStartup` falls back to when nothing matches. Materializes the
        spec exactly as `prepareSpawn` would for a fresh spawn (overlay, then
        effective port, then `PortMaterializer`) but never claims or binds the
        port: the live child already holds it. `boundPort`/`startedAt` come from
        the persisted state so the adopted run keeps its rebind and its uptime.
        Returns false when the spec's port claim no longer resolves (the error
        `prepareSpawn` would refuse a spawn with) or the exit watch could not
        be armed, which records no phase, pid, or state and sends the caller
        down the same bounce+respawn path as a pid with no matching job. */
    private func adoptSurvivor(
        boundPort: Int?, job: LaunchdJobs.ChildJob, name: String, pid: pid_t, project: String,
        spec: ServerSpec, startedAt: Date?
    ) async -> Bool {
        let overlaid = Self.overlaid(spec, project: project)
        let declaredPort = overlaid.spec.port
        let effective = overlaid.overlayPort ?? boundPort ?? declaredPort
        let claim: PortClaim
        do {
            claim = try Self.claim(spec: overlaid.spec, effectivePort: effective)
        } catch {
            DirectaLog.daemon.error(
                "recover adopt \(name)@\(project): \(error.message); bouncing pid \(pid) instead")
            return false
        }
        let supervisor = await self.supervisor(project: project, spec: spec)
        await materializeSpawnSpec(
            overlaid.spec, claim: claim, declaredPort: declaredPort, effectivePort: effective,
            on: supervisor)
        guard await supervisor.adopt(
            pid: pid, label: job.label, boundPort: boundPort, startedAt: startedAt)
        else {
            DirectaLog.daemon.error(
                "recover adopt \(name)@\(project): cannot watch pid \(pid) for exit; bouncing it instead")
            return false
        }
        DirectaLog.daemon.info(
            "recover adopt \(name)@\(project): pid \(pid) still alive as \(job.label)")
        return true
    }

    /** Group-kill a live non-child left over from a prior daemon (or a prune that
        could not stop through the supervisor). `root` is read moments before
        this call, so the identity checks here only cover the gap between that
        read and each signal; a caller holding a pid from disk proves it first
        with `ProcessTree.startTimeConsistent`, or a recycled pid is killed. */
    private func bounceOrphan(
        _ root: ProcessIdentity, project: String, name: String
    ) async {
        guard ProcessTree.shouldSignal(
            snapshotted: root, live: ProcessTree.identity(of: root.pid))
        else {
            DirectaLog.daemon.info(
                "orphan bounce skip \(name)@\(project): pid \(root.pid) gone or reused")
            return
        }
        let pid = root.pid
        /** The shape of the supervisor's stop. A server is spawned as a
            session leader (createSession), so its session id is its own pid;
            sweeping the session as well as the parent chain catches an orphan
            descendant that setpgid'd or setsid'd out of the group, and the
            root's unique id reaches one that also left the session and
            reparented, the same union stop() and the crash path use. */
        let candidates = ProcessTree.liveDescendants(rootPid: pid, rootIdentity: root, snapshot: [])
        ProcessTree.signalTree(descendants: candidates, rootIdentity: root, signal: SIGTERM)
        /** The grace ends early only once the root and every SIGTERM candidate
            have exited, polled by identity so a recycled number reads as gone:
            a descendant that ignores SIGTERM outlives a root that obeys it.
            Shorter than an ordinary stop's grace: an orphan bounce runs during
            boot restore, where a prior daemon's leftover child should yield
            quickly so the fresh supervisor can claim the port. */
        let orphanBounceGraceSeconds = 2.0
        let graceDeadline = ContinuousClock.now.advanced(by: .seconds(orphanBounceGraceSeconds))
        while ContinuousClock.now < graceDeadline,
            ProcessTree.isRunning(root) || candidates.contains(where: ProcessTree.isRunning)
        {
            try? await Task.sleep(for: .milliseconds(50))
        }
        /** A fresh union, since a child may have appeared during the grace,
            plus every SIGTERM candidate, since the root's exit may have hidden
            one from every live source; each is signaled only while it still
            names the identity recorded for it, and the group only while the
            root does. */
        ProcessTree.signalTree(
            descendants: ProcessTree.liveDescendants(
                rootPid: pid, rootIdentity: root, snapshot: [], priorCandidates: candidates),
            rootIdentity: root, signal: SIGKILL)
        await events.post(
            kind: .crashed, project: project, server: name,
            detail: DaemonRestartDetail.orphanBounced(pid: pid))
    }

    /** Stops a resident supervisor for removal and drops it from the pool,
        retiring its state row when the stop gave up
        (`retireRemovedState`). Nil when no supervisor was resident. */
    private func removeSupervisor(
        id: String, name: String, project: String, reason: String
    ) async -> ServerSupervisor.RemovalOutcome? {
        guard let supervisor = supervisors[id] else { return nil }
        let outcome = await supervisor.stopForRemoval(reason: reason)
        if outcome == .gaveUp {
            await retireRemovedState(name: name, project: project, writer: supervisor.writerID)
        }
        supervisors[id] = nil
        return outcome
    }

    /** Retires the state row of a supervisor whose removal stop gave up
        (`Registry.retireState`) as stopped with no restore intent. The run's
        pid and start time stay, so a later daemon launch can prove and bounce
        a process that outlived the stop (`recoverAtStartup`). A save failure
        is logged at error level, which persists, and the removal goes on: the
        retirement already holds in memory, which is what refuses that
        supervisor's late write for the rest of this daemon's life. */
    private func retireRemovedState(name: String, project: String, writer: UUID) async {
        let id = serverID(project: project, name: name)
        var final = await registry.persistedState(serverID: id) ?? PersistedServerState()
        final.phase = .stopped
        final.resumeOnBoot = nil
        do {
            try await registry.retireState(serverID: id, final: final, writer: writer)
        } catch {
            DirectaLog.daemon.error(
                "removing \(name)@\(project): could not save its retired state (\(error.localizedDescription)); the next daemon launch may try to restore it")
        }
    }

    /** Clears resume-on-boot on a row that carries it, through the router's
        own write. Never inserts a row. A save failure is logged at error
        level and the unregister goes on, with the flag already cleared in
        memory. */
    private func clearBootIntent(name: String, project: String) async {
        let id = serverID(project: project, name: name)
        guard await registry.persistedState(serverID: id)?.resumeOnBoot != nil else { return }
        do {
            try await registry.updateState(serverID: id, writer: .router) { $0.resumeOnBoot = nil }
        } catch {
            DirectaLog.daemon.error(
                "unregister \(name)@\(project): could not save its cleared restore-at-launch flag (\(error.localizedDescription)); the next daemon launch may try to restore it")
        }
    }

    /** Removes a project's log directory once `serverUnregister` has dropped
        its last ad hoc server AND nothing supervised is still resident for it.
        The registry only tracks ad hoc servers and trust, not the config-defined
        servers `devservers.json` declares, so a project can still have a live,
        merely un-registered supervisor even after its registry row disappears;
        deleting the directory out from under that supervisor's spool files
        would be the exact bug this guards against. Never stops or signals
        anything itself: a live supervisor means "not yet", not "force it". */
    private func removeLogDirIfProjectIsForgotten(_ project: String) async {
        guard await registry.project(project) == nil else { return }
        let prefix = "\(project)::"
        guard !supervisors.keys.contains(where: { $0.hasPrefix(prefix) }) else { return }
        removeProjectLogDir(project)
    }

    /** Suppressed on purpose past the existence check: a permissions error or
        a file another process still has open leaves the directory behind
        rather than crashing the daemon over a cleanup step, and doctor's
        orphan-log-dir finding catches whatever this leaves; but a genuine
        failure must not vanish silently, so it is logged at error level
        (which persists), and the common case of a project with no log
        directory at all is not logged as one. */
    private func removeProjectLogDir(_ project: String) {
        let logDir = paths.projectLogDir(project: project)
        guard FileManager.default.fileExists(atPath: logDir.path) else { return }
        do {
            try FileManager.default.removeItem(at: logDir)
        } catch {
            DirectaLog.daemon.error(
                "could not remove log directory for \(project): \(error.localizedDescription)")
        }
    }

    /** Stop and forget one vanished checkout. Config is unreadable once the path
        is gone, so this walks supervisors + registry + state directly instead of
        groupDown / mergedSpecs. `project` must be the canonical registry key,
        since the supervisor, state, and lock matches below compare raw
        strings. Returns the
        sorted ad hoc and persisted-state server names it dropped, for a caller
        (`project.forget`) that reports what actually happened rather than
        assuming success. */
    @discardableResult
    private func forgetMissingProject(_ project: String) async -> [String] {
        /** The teardown suspends in every server's stop, so a second forget of
            the same project (the sweep and `project.forget`, or two requests)
            can land mid-way; it does nothing and reports nothing rather than
            stopping, retiring, and unregistering the same servers again. */
        guard forgetting.insert(project).inserted else { return [] }
        defer { forgetting.remove(project) }
        let prefix = "\(project)::"
        /** Snapshot identities before teardown: a composite tree can outlive a
            no-op stop (phase already crashed after the checkout vanished),
            so we keep the recorded ProcessIdentity and bounce only while that
            start time still matches. */
        var liveRoots: [(identity: ProcessIdentity, name: String)] = []
        var names = Set(await registry.specs(project: project).map(\.name))
        for (id, supervisor) in supervisors where id.hasPrefix(prefix) {
            guard let name = parseServerID(id)?.name else { continue }
            names.insert(name)
            let status = await supervisor.status()
            if let pid = status.pid.flatMap(ProcessTree.narrowed),
                let identity = ProcessTree.identity(of: pid)
            {
                liveRoots.append((identity: identity, name: name))
            }
        }
        for (id, persisted) in await registry.allPersistedState() where id.hasPrefix(prefix) {
            guard let name = parseServerID(id)?.name else { continue }
            names.insert(name)
            /** A pid read from disk may have been recycled since it was
                recorded, so it is bounced only with start-time proof. */
            if let identity = ProcessTree.provenIdentity(pid: persisted.pid, startedAt: persisted.startedAt),
                !liveRoots.contains(where: { $0.identity.pid == identity.pid })
            {
                liveRoots.append((identity: identity, name: name))
            }
        }
        let sortedNames = names.sorted()
        DirectaLog.daemon.info(
            "prune missing project \(project) (\(sortedNames.joined(separator: ",")))")
        for name in sortedNames {
            /** `stop()` no-ops for a server already in a terminal phase
                (recordOutcome never runs, so nothing posts its own `.stopped`
                event). A live one's recordOutcome posts `.stopped` with this
                same detail, either before the bounded stop returns or, for a
                stop that gave up still `.stopping`, whenever the exit finally
                lands; posting it here too would double the event. Only the
                terminal case needs the manual post. A stop that gave up also
                retires the row, so that late recordOutcome cannot recreate it
                after `removeState` below. */
            let outcome = await removeSupervisor(
                id: serverID(project: project, name: name), name: name, project: project,
                reason: RemovalReason.projectPathGone)
            if outcome == .alreadyTerminal {
                await events.post(
                    kind: .stopped, project: project, server: name, detail: RemovalReason.projectPathGone)
            }
        }
        for entry in liveRoots {
            guard ProcessTree.shouldSignal(
                snapshotted: entry.identity, live: ProcessTree.identity(of: entry.identity.pid))
            else { continue }
            await bounceOrphan(entry.identity, project: project, name: entry.name)
        }
        configCache[project] = nil
        let lockKeys = resourceLocks.keys.filter { $0.hasPrefix(prefix) }
        if !lockKeys.isEmpty {
            for key in lockKeys {
                resourceLocks[key] = nil
            }
            persistLocks()
        }
        try? await registry.removeState(forProject: project)
        try? await registry.removeProject(project)
        /** Only here, after every supervisor above is stopped and dropped and
            every live root bounced. Unlike unregister, a stop that gave up
            does not keep the directory: the checkout is gone, so no project
            will ever claim it again. */
        removeProjectLogDir(project)
        for name in sortedNames {
            await events.post(
                kind: .unregistered, project: project, server: name, detail: RemovalReason.projectPathGone)
        }
        return sortedNames
    }

    private enum RecoverSpec {
        case found(ServerSpec)
        /** Config loaded cleanly and the name is absent: rename/delete. */
        case missing
        /** Config threw (invalid JSON, etc.): keep intent for a later boot. */
        case unavailable
    }

    /** Prefer the merged config+registry view. Only treat a name as gone when
        the config is readable and does not contain it (and the registry does
        not either). A parse error must not drop resume-on-boot. */
    private func resolveSpecForRecover(project: String, name: String) async -> RecoverSpec {
        do {
            let merged = try await mergedSpecs(project: project)
            if let spec = merged.specs.first(where: { $0.name == name }) {
                return .found(spec)
            }
            return .missing
        } catch {
            if let spec = await registry.spec(project: project, name: name) {
                return .found(spec)
            }
            return .unavailable
        }
    }

    /** Every registry project plus every project with a resident supervisor:
        the set of projects the daemon claims, not the narrower set with a
        currently readable config (a trusted project mid-edit on an invalid
        devservers.json still claims its log directory). */
    private func claimedProjects(registryProjects: [String]) -> Set<String> {
        var claimed = Set(registryProjects)
        for id in supervisors.keys {
            if let parsed = parseServerID(id) { claimed.insert(parsed.project) }
        }
        return claimed
    }

    /** `logs.removeOrphan`: removes one leftover log directory while holding
        the claim set. The registry read is the only suspension; from the
        supervisor scan to `removeItem` the actor runs nothing else, and a
        start creates a project's log directory only from a supervisor already
        resident in `supervisors`, so a project started concurrently is either
        claimed here or has not created its directory yet. */
    private func removeOrphanLogDirectory(named name: String) async -> LogsRemoveOrphanResult {
        let registryProjects = await registry.allProjects()
        let claimed = claimedProjects(registryProjects: registryProjects)
        let directory = paths.logsDir.appending(path: name)
        let removal = OrphanProjectLogs.remove(
            directory, logsDir: paths.logsDir,
            claimedSlugDirs: DirectaPaths.projectLogDirNames(projects: claimed))
        return LogsRemoveOrphanResult(path: directory, removal: removal)
    }

    private func daemonInfo() async -> DaemonInfo {
        let claimed = claimedProjects(registryProjects: await registry.allProjects())
        return DaemonInfo(
            claimedProjects: claimed.sorted(),
            dataDir: paths.dataDir.path,
            daemonVersion: DirectaVersion.version,
            logsDir: paths.logsDir.path,
            pid: Int(getpid()),
            proto: DirectaVersion.proto,
            restoring: restoring ? true : nil,
            searchPath: ProcessInfo.processInfo.environment["PATH"],
            socketPath: paths.socketPath
        )
    }

    private func exitDaemon() -> Never {
        DaemonTelemetry.exit(code: 0, reason: "daemon.shutdown request")
    }

    /** Writes a devservers.json from what the daemon already knows, which is the
        only way back for a file that was gitignored and lost. The projection runs
        over the merged view, never a supervisor's spec: a running spec has been
        materialized, so its argv holds this machine's substituted port. */
    private func initConfig(_ params: InitConfigParams) async throws -> InitConfigResult {
        let project = canonicalProjectPath(params.project)
        let url = ProjectConfigLoader.configURL(project: project)
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists, params.mode == .create {
            throw WireError(
                code: .alreadyExists,
                hint: "run: directa config init --force",
                message: "\(url.path) already exists; pass --force to replace it")
        }
        if exists, params.mode == .replace, params.force != true {
            throw WireError(
                code: .alreadyExists,
                hint: "run: directa config init --force",
                message: "\(url.path) already exists; pass --force to replace it")
        }
        var specs: [ServerSpec] = []
        var host: String?
        if params.fromDaemon != false {
            if let merged = try? await mergedSpecs(project: project) {
                specs = merged.specs
                host = merged.host
            } else {
                specs = await registry.specs(project: project)
            }
        }
        for extra in params.servers ?? [] {
            specs.removeAll { $0.name == extra.name }
            specs.append(extra)
        }
        specs.sort { $0.name < $1.name }
        guard !specs.isEmpty else {
            throw WireError(
                code: .notFound,
                hint: "run: directa register --name <name> --cmd <word>",
                message: "the daemon knows no servers for \(project), so there is nothing to write")
        }
        var config = ConfigProjection.file(
            host: params.host ?? host, project: project, specs: specs)
        var notRecovered: [String] = []
        if params.mode == .merge, exists {
            guard let existingData = try? Data(contentsOf: url),
                let existing = try? JSONCoding.decoder().decode(
                    ProjectFileConfig.self, from: existingData)
            else {
                throw WireError(
                    code: .configInvalid,
                    hint: "run: directa config check",
                    message: "cannot parse \(url.path), so merging into it would lose it")
            }
            var merged = existing
            for (name, entry) in config.servers {
                guard let next = ConfigProjection.merge(
                    entry: entry, force: params.force == true, into: merged, name: name)
                else {
                    throw WireError(
                        code: .alreadyExists,
                        hint: "run: directa register --name \(ShellWord.argument(name)) --write --force",
                        message: "\(url.path) already declares '\(name)'; pass --force to replace that entry")
                }
                merged = next
            }
            config = merged
        } else if exists {
            /** lifecycle exists only in the file and has no runtime counterpart,
                so a rewrite from daemon state drops it. Report it only when the
                file being replaced actually had one: naming a key the reader
                never wrote sends them looking for something that was never
                there. */
            let previous = (try? Data(contentsOf: url)).flatMap {
                try? JSONCoding.decoder().decode(ProjectFileConfig.self, from: $0)
            }
            if let lifecycle = previous?.lifecycle, !lifecycle.isEmpty, config.lifecycle == nil {
                notRecovered = ["lifecycle"]
            }
        }
        let view = ProjectConfigLoader.validate(config: config, project: project)
        guard view.errors.isEmpty else {
            throw WireError(
                code: .configInvalid,
                hint: "run: directa config check",
                message: "the projected config does not validate: \(view.errors.joined(separator: "; "))")
        }
        let data = try JSONCoding.fileEncoder().encode(config)
        let content = String(decoding: data, as: UTF8.self) + "\n"
        let hosts = await effectiveHosts(project: project, view: view)
        let worktree = await CheckoutIdentity.worktreeDisplay(project: project)
        let check = CheckResult(
            errors: view.errors,
            host: view.host,
            serverHosts: hosts.isEmpty ? nil : hosts,
            servers: view.specs.map(\.name),
            warnings: view.warnings,
            worktree: worktree?.label)
        guard params.dryRun != true else {
            return InitConfigResult(
                check: check, content: content,
                notRecovered: notRecovered.isEmpty ? nil : notRecovered, path: url.path,
                written: false)
        }
        try AtomicFile.write(Data(content.utf8), to: url)
        configCache[project] = nil
        return InitConfigResult(
            check: check, content: content,
            notRecovered: notRecovered.isEmpty ? nil : notRecovered, path: url.path, written: true)
    }

    /** The servers whose effective host differs from the project's, answered
        before anything starts. Same resolver the spawn path runs, so `config
        check` can answer before a start. A linked worktree changes nothing
        about the host (its name surfaces as the `worktree` display value);
        only a `directa.local.json` overlay or a per-server override differs. */
    private func effectiveHosts(project: String, view: ProjectConfigView) async -> [EffectiveHost] {
        let defaultSlugHost = "\(ProjectConfigLoader.defaultSlug(project: project)).localhost"
        let declaredHost = view.host
        let overlay = LocalOverlay.load(project: project)
        return view.specs.compactMap { spec -> EffectiveHost? in
            let resolved = EffectiveHostResolver.server(
                defaultSlugHost: defaultSlugHost, declaredHost: declaredHost,
                overlayHost: overlay?.servers?[spec.name]?.host,
                server: spec.name, specHost: spec.host)
            return resolved.effective == declaredHost ? nil : resolved
        }
    }

    /** Resolve effective port, apply overlay/materialization, and
        either auto-rebind a sibling conflict or refuse with port-held. Every
        start-shaped path funnels through here, which is also why the trust gate
        lives here rather than at each call site.

        `force` resolves and validates even for a server that is currently up,
        which is what lets `restart` raise every refusal before it stops
        anything. The port pre-check treats a listener the target itself owns as
        free, so a running server does not report its own port as held.

        `userInitiated` is the security boundary: an explicit command (ensure,
        start, up, restart) acting on a server declared in the committed
        devservers.json IS the user's approval, so it records trust and proceeds.
        An autonomous path (boot restore, the watch sweep) must not act on a
        project's committed config until that approval was given, so it refuses.
        A spec that came from `register` rather than the file carries its own
        approval and is never gated. */
    private func prepareSpawn(
        target: ServerTargetParams, supervisor: ServerSupervisor, portOverride: Int? = nil,
        force: Bool = false, userInitiated: Bool = false
    ) async throws {
        if !force {
            /** Phase, not `hasLiveRun`: a live port-failed run still resolves
                afresh, since `start` replaces it. */
            let current = await supervisor.status()
            if current.phase.isActive { return }
        }
        let merged = try await mergedSpecs(project: target.project)
        guard let committed = merged.specs.first(where: { $0.name == target.name }) else {
            throw ProjectConfigLoader.serverNotFound(name: target.name, project: target.project)
        }
        if merged.fileNames.contains(target.name) {
            let trusted = await registry.isTrusted(project: target.project)
            if userInitiated {
                if !trusted {
                    do {
                        try await registry.setTrusted(project: target.project)
                    } catch {
                        /** The command still proceeds, but a dropped trust write
                            means a later autonomous restore of this project will
                            refuse it with nothing pointing back here; surface it
                            so a drifted trust state is diagnosable. */
                        DirectaLog.daemon.error(
                            "failed to record trust for \(target.project): \(error)")
                    }
                }
            } else if !trusted {
                throw WireError(
                    code: .notTrusted,
                    hint: "run: directa ensure \(ShellWord.argument(target.name)) --project \(ShellWord.argument(target.project))",
                    message:
                        "refusing to start '\(target.name)' from \(target.project)/devservers.json: this project's committed config has not been approved. Start a server there once by hand to approve it.")
            }
        }
        let overlaid = Self.overlaid(committed, project: target.project)
        let spec = overlaid.spec
        try await lockGate(project: target.project, spec: spec)
        /** The declared host stays the spawn host: a linked worktree keeps it
            (its name surfaces as a display label, never a subdomain), so URLs
            already carry the right host and only the port can differ. */
        let declaredPort = spec.port
        let id = serverID(project: target.project, name: target.name)
        let persistedBound = await registry.persistedState(serverID: id)?.boundPort
        var effective = portOverride ?? overlaid.overlayPort ?? persistedBound ?? declaredPort
        var conflict: PortConflict?
        /** Whether the claim at the final `effective` already passed the
            pre-check below with no await since, so a second pass would only
            repeat it. */
        var claimChecked = false
        if let port = effective {
            let draftClaim = try Self.claim(spec: spec, effectivePort: port)
            let evidence = await portEvidence(for: draftClaim)
            if let busy = await firstBusyPort(in: draftClaim, evidence: evidence, excluding: id) {
                let holder = evidence.holds.holder(of: busy, excluding: id)
                var holderIsSibling = false
                if let holder, draftClaim.relative.contains(busy) {
                    holderIsSibling = await CheckoutIdentity.shareCommonDir(target.project, holder.project)
                }
                if let holder, holderIsSibling {
                    let rebound = await allocateSiblingPort(
                        declared: declaredPort ?? port, excluding: id, holds: evidence.holds,
                        project: target.project, spec: spec)
                    conflict = PortConflict(
                        declaredPort: declaredPort ?? port,
                        effectivePort: rebound,
                        holder: "\(holder.server)@\(holder.project)",
                        message:
                            "port \(busy) held by sibling '\(holder.server)' in \(holder.project); rebound to \(rebound)",
                        state: .rebound)
                    effective = rebound
                    try? await registry.updateState(serverID: id, writer: .router) { $0.boundPort = rebound }
                } else if let holder {
                    DirectaLog.daemon.error(
                        "port-held \(busy) by \(holder.server)@\(holder.project) for \(target.name)")
                    throw WireError(
                        code: .portHeld,
                        hint: "run: directa stop \(ShellWord.argument(holder.server)) --project \(ShellWord.argument(holder.project))",
                        message:
                            "port \(busy) is held by managed server '\(holder.server)' in \(holder.project)"
                    )
                } else {
                    let squatter = await portProbe.listenerInfo(busy)
                    if let squatter {
                        throw WireError(
                            code: .portHeld,
                            hint: "run: kill \(squatter.pid)  (verify first: ps -p \(squatter.pid))",
                            message:
                                "port \(busy) is held by unmanaged pid \(squatter.pid) (\(squatter.command))"
                        )
                    }
                    throw WireError(
                        code: .portHeld,
                        message: "port \(busy) already has a listener that directa does not manage"
                    )
                }
            } else {
                claimChecked = true
            }
        }
        let claim = try Self.claim(spec: spec, effectivePort: effective)
        if !claimChecked {
            let evidence = await portEvidence(for: claim)
            if let busy = await firstBusyPort(in: claim, evidence: evidence, excluding: id) {
                throw WireError(
                    code: .portHeld,
                    message: "port \(busy) is still busy after rebind resolution")
            }
        }
        await materializeSpawnSpec(
            spec, claim: claim, declaredPort: declaredPort, effectivePort: effective,
            portConflict: conflict, on: supervisor)
    }

    /** `spec` with this checkout's `directa.local.json` entry for it applied,
        and that entry's own port, which outranks a persisted rebind when the
        effective port is chosen. */
    private static func overlaid(_ spec: ServerSpec, project: String) -> (
        overlayPort: Int?, spec: ServerSpec
    ) {
        let overlayServer = LocalOverlay.load(project: project)?.servers?[spec.name]
        return (
            overlayPort: overlayServer?.port,
            spec: LocalOverlay.apply(spec: spec, overlay: overlayServer, project: project)
        )
    }

    /** The ports a spawn at `effectivePort` claims, or config-invalid when the
        spec's port declarations contradict each other there. */
    private static func claim(spec: ServerSpec, effectivePort: Int?) throws(WireError) -> PortClaim {
        let resolved = PortClaim.resolve(spec: spec, effectivePort: effectivePort)
        guard let claim = resolved.claim, resolved.error == nil else {
            throw WireError(
                code: .configInvalid, hint: "run: directa config check",
                message: resolved.error ?? "invalid port claim")
        }
        return claim
    }

    /** Hands a supervisor the spec it spawns or adopts under: the overlaid spec
        with the effective port substituted (`PortMaterializer`), and the port
        bookkeeping status reports. The one tail of `prepareSpawn` and
        `adoptSurvivor`. */
    private func materializeSpawnSpec(
        _ spec: ServerSpec, claim: PortClaim, declaredPort: Int?, effectivePort: Int?,
        portConflict: PortConflict? = nil, on supervisor: ServerSupervisor
    ) async {
        await supervisor.updateSpec(PortMaterializer.materialize(spec: spec, effectivePort: effectivePort))
        await supervisor.setPortMeta(
            claim: claim, declaredPort: declaredPort, effectivePort: effectivePort,
            portConflict: portConflict)
    }

    /** One port check's evidence: which of `claim`'s ports have a listener,
        then every managed hold. Probed before the ownership read, never
        after: every run has its phase set before it spawns, so a listener
        seen here belongs to a run the read finds. Reading the phase first let
        a run spawned between the read and the probe (a concurrent ensure of
        this very server winning the single flight) look like an unmanaged
        squatter. */
    private func portEvidence(for claim: PortClaim) async -> (holds: ManagedHolds, listening: Set<Int>) {
        var listening: Set<Int> = []
        for port in claim.allPorts {
            let isListening = await portProbe.isListening(port)
            if isListening { listening.insert(port) }
        }
        return (holds: await managedHolds(), listening: listening)
    }

    /** First claimed port that is held (managed or unmanaged). Absolutes and
        relatives are treated the same for freeness; only sibling rebind cares
        which set a conflict came from. */
    private func firstBusyPort(
        in claim: PortClaim, evidence: (holds: ManagedHolds, listening: Set<Int>),
        excluding targetID: String
    ) async -> Int? {
        var ownPorts: Set<Int>?
        for port in claim.allPorts {
            if evidence.holds.holder(of: port, excluding: targetID) != nil { return port }
            guard evidence.listening.contains(port) else { continue }
            /** A listener the target itself holds is not a conflict for the
                target: it is the run about to be replaced (`start` stops a
                live port-failed run first), or a concurrent ensure that just
                won the single flight. The holder lookup excludes the target
                by id, so without this the target's own socket falls through
                to the unmanaged-squatter branch. */
            if ownPorts == nil { ownPorts = await heldPorts(id: targetID) }
            if ownPorts?.contains(port) != true { return port }
        }
        return nil
    }

    /** The ports one resident server holds right now; empty when it has no
        supervisor or holds nothing. */
    private func heldPorts(id: String) async -> Set<Int> {
        guard let supervisor = supervisors[id] else { return [] }
        let snapshot = await supervisor.portSnapshot()
        return snapshot.status.heldPorts(claim: snapshot.claim)
    }

    /** The whole rebound block must clear every port a live managed server
        holds, span members included, not only the ports it listens on. */
    private func allocateSiblingPort(
        declared: Int, excluding targetID: String, holds: ManagedHolds, project: String,
        spec: ServerSpec
    ) async -> Int {
        await SiblingRebind.search(
            isListening: portProbe.isListening, reserved: holds.ports(excluding: targetID), spec: spec,
            start: CheckoutIdentity.siblingPortCandidate(declared: declared, project: project))
    }

    /** Wait until every claimed port is free, or return the first still-busy port. */
    private func waitForClaimFree(claim: PortClaim, budgetSeconds: Double = 2) async -> Int? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(budgetSeconds))
        while true {
            var busy: Int?
            for port in claim.allPorts {
                let listening = await portProbe.isListening(port)
                if listening {
                    busy = port
                    break
                }
            }
            if busy == nil { return nil }
            if ContinuousClock.now >= deadline { return busy }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /** One managed server and every port it holds right now. */
    private struct ManagedHold: Sendable {
        let id: String
        let ports: Set<Int>
        let project: String
        let server: String
    }

    /** Every managed hold, read once per request and looked up by port. A
        port maps to a list rather than one hold so a lookup can skip the
        server the check is for, whichever request asks. */
    private struct ManagedHolds: Sendable {
        let byPort: [Int: [ManagedHold]]

        init(_ holds: [ManagedHold]) {
            var byPort: [Int: [ManagedHold]] = [:]
            for hold in holds {
                for port in hold.ports { byPort[port, default: []].append(hold) }
            }
            self.byPort = byPort
        }

        func holder(of port: Int, excluding id: String) -> ManagedHold? {
            byPort[port]?.first { $0.id != id }
        }

        func ports(excluding id: String) -> Set<Int> {
            Set(byPort.compactMap { port, holds in holds.contains { $0.id != id } ? port : nil })
        }
    }

    /** Every managed server that holds ports right now, with the ports it
        holds. The resident supervisor pool answers for servers this daemon has
        been asked about; state.json answers for the rest, since the pool is
        built lazily and a server started before this daemon's first request
        for it has no entry there at all. A persisted row counts only while its
        phase holds ports and its recorded pid is still alive. */
    private func managedHolds() async -> ManagedHolds {
        var holds: [ManagedHold] = []
        for (id, other) in supervisors {
            let snapshot = await other.portSnapshot()
            let ports = snapshot.status.heldPorts(claim: snapshot.claim)
            guard !ports.isEmpty else { continue }
            holds.append(
                ManagedHold(
                    id: id, ports: ports, project: snapshot.status.project,
                    server: snapshot.status.server))
        }
        var specsByProject: [String: [ServerSpec]] = [:]
        for (id, persisted) in await registry.allPersistedState() {
            guard supervisors[id] == nil, persisted.phase.holdsPort, let pid = persisted.pid,
                ProcessTree.isAlive(pid), let parsed = parseServerID(id)
            else { continue }
            if specsByProject[parsed.project] == nil {
                specsByProject[parsed.project] = (try? await mergedSpecs(project: parsed.project))?.specs ?? []
            }
            guard let committed = specsByProject[parsed.project]?.first(where: { $0.name == parsed.name })
            else { continue }
            /** The spec the run was spawned from: the checkout's overlay can
                move its port and reshape its claim. */
            let spec = Self.overlaid(committed, project: parsed.project).spec
            let bound = persisted.boundPort ?? spec.port
            let ports = Set(
                PortClaim.resolve(spec: spec, effectivePort: bound).claim?.allPorts ?? bound.map { [$0] } ?? [])
            guard !ports.isEmpty else { continue }
            holds.append(ManagedHold(id: id, ports: ports, project: parsed.project, server: parsed.name))
        }
        return ManagedHolds(holds)
    }

    /** The merged project view: committed devservers.json specs (source of
        truth for their names) plus ad-hoc registry entries. Throws
        config-invalid when the file exists but cannot be used. */
    private func mergedSpecs(project: String) async throws -> (
        host: String?, specs: [ServerSpec], fileNames: Set<String>
    ) {
        let project = canonicalProjectPath(project)
        var specs: [String: ServerSpec] = [:]
        for spec in await registry.specs(project: project) {
            specs[spec.name] = spec
        }
        var fileNames: Set<String> = []
        var host: String?
        if let view = try loadConfig(project: project) {
            guard view.errors.isEmpty else {
                throw WireError(
                    code: .configInvalid,
                    hint: "run: directa config check",
                    message: "devservers.json is invalid: \(view.errors.joined(separator: "; "))")
            }
            host = view.host
            for spec in view.specs {
                specs[spec.name] = spec
                fileNames.insert(spec.name)
            }
        }
        return (
            host: host, specs: specs.values.sorted { $0.name < $1.name }, fileNames: fileNames
        )
    }

    private func loadConfig(project: String) throws -> ProjectConfigView? {
        let url = ProjectConfigLoader.configURL(project: project)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let mtime = attributes[.modificationDate] as? Date
        else {
            configCache[project] = nil
            return nil
        }
        if let cached = configCache[project], cached.mtime == mtime {
            return cached.view
        }
        guard let view = try ProjectConfigLoader.load(project: project) else { return nil }
        configCache[project] = (mtime: mtime, view: view)
        return view
    }

    /** Acquire: refuse if another live holder owns it; when `pause` is set, stop
        active declarers without retiring boot intent; persist the hold and return
        who was paused and who was left running. */
    private func acquireLock(_ params: LockParams) async throws -> LockResult {
        let key = Self.lockKey(project: params.project, resource: params.resource)
        await releaseOrphanedLock(key: key)
        if let holder = resourceLocks[key], holder.pid != params.holderPid {
            throw WireError(
                code: .resourceLocked,
                hint: "wait for pid \(holder.pid) to finish, or verify it: ps -p \(holder.pid)",
                message:
                    "resource '\(params.resource)' is locked by pid \(holder.pid) since \(JSONCoding.formatISO8601(holder.since))"
            )
        }
        /** Same holder re-acquiring (retry after a blip) keeps the existing pause
            set rather than double-stopping, and must answer with everything the
            first acquire did: dropping `live` or `statePath` here would leave the
            retrying client unable to judge the resource for the rest of the hold. */
        if let existing = resourceLocks[key], existing.pid == params.holderPid {
            /** Throws for the same reason the first acquire does. Reaching here
                with an unreadable config means the config broke during the hold,
                since the first acquire would already have refused it, and a
                state path resolved from no specs at all is a worse answer than
                saying the config is now unreadable. */
            let merged = try await mergedSpecs(project: params.project)
            return LockResult(
                live: existing.live, paused: existing.paused,
                statePath: try LockResource.statePath(
                    project: params.project, resource: params.resource, specs: merged.specs))
        }
        var live: [String] = []
        var paused: [String] = []
        let shouldPause = params.pause ?? false
        /** Not `try?`. Swallowing the merge failure left `specs` empty, so no
            declarer was found, nothing was paused, and the lock reported success:
            the caller then ran its migration against a live server holding the
            resource open, which is the exact accident `lock` exists to prevent.
            A broken config has to refuse the hold rather than grant a hold that
            protects nothing. `config init` on the same failure already throws. */
        let merged = try await mergedSpecs(project: params.project)
        for spec in merged.specs
        where LockResource.declares(resource: params.resource, spec: spec) {
            let supervisor = await supervisor(project: params.project, spec: spec)
            let status = await supervisor.status()
            guard status.hasLiveRun else { continue }
            guard shouldPause else {
                /** Sound for the whole hold: lockGate refuses to start a
                    declarer while a live holder owns the resource, so this set
                    can only shrink. */
                live.append(spec.name)
                continue
            }
            /** Non-retiring stop: boot intent survives so a daemon crash
                mid-hold can still bring the server back if the holder is gone. */
            _ = await supervisor.stop(
                deliberate: false, reason: "paused for lock \(params.resource)")
            paused.append(spec.name)
            DirectaLog.daemon.info(
                "lock \(params.resource) paused \(spec.name)@\(params.project)")
        }
        live.sort()
        paused.sort()
        /** Refusing here is correct when directa cannot tell which state the lock
            guards: taking it anyway would report on the wrong file. */
        let statePath = try LockResource.statePath(
            project: params.project, resource: params.resource, specs: merged.specs)
        resourceLocks[key] = LockHolder(
            live: live.isEmpty ? nil : live, pause: shouldPause, paused: paused,
            pid: params.holderPid, resumeTimeoutSeconds: params.resumeTimeoutSeconds, since: Date())
        persistLocks()
        return LockResult(
            live: live.isEmpty ? nil : live, paused: paused, statePath: statePath)
    }

    /** Who holds a resource right now, if anyone. A dead holder is released
        first, so a stale row reads as no holder rather than as a phantom the
        caller then waits on. */
    private func lockStatus(_ params: LockStatusParams) async -> LockStatusResult {
        let key = Self.lockKey(project: params.project, resource: params.resource)
        await releaseOrphanedLock(key: key)
        return LockStatusResult(holder: resourceLocks[key])
    }

    /** Release: only the matching holder clears the lock; then ensure everyone
        that was paused. */
    private func releaseLock(_ params: LockParams) async throws -> LockResult {
        let key = Self.lockKey(project: params.project, resource: params.resource)
        guard let holder = resourceLocks[key], holder.pid == params.holderPid else {
            return LockResult(paused: [])
        }
        resourceLocks[key] = nil
        persistLocks()
        let timeout = params.resumeTimeoutSeconds ?? holder.resumeTimeoutSeconds ?? 60
        await resumePaused(
            names: holder.paused, project: params.project, resource: params.resource,
            timeoutSeconds: timeout)
        return LockResult(paused: holder.paused)
    }

    /** Drop dead holders and resume what they paused. Called from gate/acquire
        and at startup so a crashed harness (or a dead CLI after a daemon bounce)
        never leaves servers stopped. */
    private func releaseOrphanedLock(key: String) async {
        guard let holder = resourceLocks[key] else { return }
        guard !ProcessTree.isAlive(holder.pid) else { return }
        guard let separator = key.range(of: "::") else {
            resourceLocks[key] = nil
            persistLocks()
            return
        }
        let project = String(key[key.startIndex..<separator.lowerBound])
        let resource = String(key[separator.upperBound...])
        DirectaLog.daemon.info(
            "lock \(resource) holder pid \(holder.pid) is gone; resuming \(holder.paused.joined(separator: ","))"
        )
        resourceLocks[key] = nil
        persistLocks()
        await resumePaused(
            names: holder.paused, project: project, resource: resource,
            timeoutSeconds: holder.resumeTimeoutSeconds ?? 60)
    }

    private func resumePaused(
        names: [String], project: String, resource: String, timeoutSeconds: Double
    ) async {
        guard !project.isEmpty else { return }
        for name in names {
            do {
                let merged = try await mergedSpecs(project: project)
                guard let spec = merged.specs.first(where: { $0.name == name }) else { continue }
                let supervisor = await supervisor(project: project, spec: spec)
                let id = serverID(project: project, name: name)
                let bound = await registry.persistedState(serverID: id)?.boundPort ?? spec.port
                let resolved = PortClaim.resolve(spec: spec, effectivePort: bound)
                if let claim = resolved.claim, let busy = await waitForClaimFree(claim: claim) {
                    DirectaLog.daemon.error(
                        "lock \(resource) resume refused \(name)@\(project): port \(busy) still busy")
                    continue
                }
                try await prepareSpawn(
                    target: ServerTargetParams(name: name, project: project), supervisor: supervisor)
                _ = await supervisor.ensure(timeoutSeconds: timeoutSeconds)
                DirectaLog.daemon.info("lock \(resource) resumed \(name)@\(project)")
            } catch let error as WireError {
                DirectaLog.daemon.error(
                    "lock \(resource) could not resume \(name)@\(project): \(error.message)")
            } catch {
                DirectaLog.daemon.error(
                    "lock \(resource) could not resume \(name)@\(project): \(error.localizedDescription)"
                )
            }
        }
    }

    /** At boot: dead holders resume their paused set; live holders stay loaded
        so lockGate still refuses starts under the harness. */
    private func reconcileLocksAtStartup() async {
        let keys = Array(resourceLocks.keys)
        for key in keys {
            await releaseOrphanedLock(key: key)
        }
        if !resourceLocks.isEmpty {
            DirectaLog.daemon.info(
                "rehydrated \(resourceLocks.count) live resource lock(s) after restart")
        }
    }

    private func isPausedUnderLiveLock(project: String, name: String) -> Bool {
        let prefix = "\(canonicalProjectPath(project))::"
        for (key, holder) in resourceLocks {
            guard key.hasPrefix(prefix) else { continue }
            guard ProcessTree.isAlive(holder.pid) else { continue }
            if holder.paused.contains(name) { return true }
        }
        return false
    }

    private func persistLocks() {
        /** Empty file is fine: defensive load treats missing/corrupt as {}. */
        try? AtomicFile.write(
            JSONCoding.encoder().encode(LocksFile(locks: resourceLocks)), to: paths.locksFile)
    }

    /** Refuses to start a server while an external holder owns one of its
        declared resources: restarting mid-harness-run is exactly the contention
        the lock exists to prevent. */
    private func lockGate(project: String, spec: ServerSpec) async throws {
        for declaration in spec.locks ?? [] {
            let resource = declaration.name
            let key = Self.lockKey(project: project, resource: resource)
            await releaseOrphanedLock(key: key)
            if let holder = resourceLocks[key] {
                throw WireError(
                    code: .resourceLocked,
                    hint: "the holder releases it when done; check: ps -p \(holder.pid)",
                    message:
                        "server '\(spec.name)' holds resource '\(resource)', locked by pid \(holder.pid) since \(JSONCoding.formatISO8601(holder.since))"
                )
            }
        }
    }

    private func resolvedSupervisor(_ params: ServerTargetParams) async throws -> ServerSupervisor {
        let merged = try await mergedSpecs(project: params.project)
        guard let spec = merged.specs.first(where: { $0.name == params.name }) else {
            throw ProjectConfigLoader.serverNotFound(name: params.name, project: params.project)
        }
        return await supervisor(project: params.project, spec: spec)
    }

    private func statusList(_ params: ProjectParams) async throws -> ServerListResult {
        /** An empty project means machine-wide (daemon restart, doctor, the app);
            machine-wide reads skip config errors rather than failing the sweep. */
        if params.project.isEmpty {
            await pruneMissingProjects()
            var targets: [(project: String, spec: ServerSpec)] = []
            for project in await registry.allProjects() {
                var specs = (try? await mergedSpecs(project: project))?.specs
                if specs == nil {
                    specs = await registry.specs(project: project)
                }
                guard let specs else { continue }
                for spec in specs {
                    if let name = params.name, name != spec.name { continue }
                    targets.append((project: project, spec: spec))
                }
            }
            return ServerListResult(servers: await annotatedStatuses(targets))
        }
        let merged = try await mergedSpecs(project: params.project)
        let targets = merged.specs
            .filter { params.name == nil || params.name == $0.name }
            .map { (project: params.project, spec: $0) }
        return ServerListResult(
            servers: await annotatedStatuses(targets),
            trusted: await registry.isTrusted(project: params.project))
    }

    /** The supported way to read statuses for a response: every reader gets the
        latent-port-conflict annotation. A handler that calls `supervisor.status()`
        directly reports a stopped server without naming the holder keeping it
        down, so route status reads through here. The ports are probed and the
        managed holds read once for the whole list, in the order `portEvidence`
        gives, rather than once per server. */
    private func annotatedStatuses(_ targets: [(project: String, spec: ServerSpec)]) async -> [ServerStatus] {
        var statuses: [ServerStatus] = []
        for target in targets {
            statuses.append(await supervisor(project: target.project, spec: target.spec).status())
        }
        let latentPorts = Set(statuses.compactMap(Self.latentConflictPort))
        guard !latentPorts.isEmpty else { return statuses }
        var listening: Set<Int> = []
        for port in latentPorts {
            let isListening = await portProbe.isListening(port)
            if isListening { listening.insert(port) }
        }
        let holds = await managedHolds()
        var commonDirs: [String: String?] = [:]
        var annotated: [ServerStatus] = []
        for status in statuses {
            annotated.append(
                await annotateLatentPortConflict(
                    status, commonDirs: &commonDirs, holds: holds, listening: listening))
        }
        return annotated
    }

    /** `CheckoutIdentity.shareCommonDir` with each project's answer read
        once per `memo`. A checkout root answers from files, but a project
        below its checkout's root still runs git, and one status read can
        annotate many servers against the same holder. Scoped to one request
        on purpose: a checkout can become or stop being a worktree between
        requests, and nothing signals that. */
    private static func sharesCommonDir(_ a: String, _ b: String, memo: inout [String: String?]) async -> Bool {
        guard let left = await commonDir(a, memo: &memo), let right = await commonDir(b, memo: &memo) else {
            return false
        }
        return left == right
    }

    private static func commonDir(_ project: String, memo: inout [String: String?]) async -> String? {
        if let known = memo[project] { return known }
        let found = await CheckoutIdentity.gitCommonDir(project: project)
        memo[project] = .some(found)
        return found
    }

    /** The port a latent conflict is judged on: set only for a server that is
        not up and has no conflict recorded already. */
    private static func latentConflictPort(_ status: ServerStatus) -> Int? {
        guard status.portConflict == nil, !status.hasLiveRun else { return nil }
        return status.declaredPort ?? status.effectivePort
    }

    /** When a server is not up but its declared port is held, surface a latent
        conflict so session context warns before the agent runs ensure. */
    private func annotateLatentPortConflict(
        _ status: ServerStatus, commonDirs: inout [String: String?], holds: ManagedHolds, listening: Set<Int>
    ) async -> ServerStatus {
        guard let port = Self.latentConflictPort(status) else { return status }
        var annotated = status
        if let holder = holds.holder(
            of: port, excluding: serverID(project: status.project, name: status.server))
        {
            let sibling = await Self.sharesCommonDir(status.project, holder.project, memo: &commonDirs)
            annotated.portConflict = PortConflict(
                declaredPort: port,
                holder: "\(holder.server)@\(holder.project)",
                message: sibling
                    ? "port \(port) held by sibling '\(holder.server)' in \(holder.project); ensure will auto-rebind"
                    : "port \(port) held by '\(holder.server)' in \(holder.project); run: directa stop \(ShellWord.argument(holder.server)) --project \(ShellWord.argument(holder.project))",
                state: .held)
        } else if listening.contains(port) {
            let listener = await portProbe.listenerInfo(port)
            let detail = listener.map { "unmanaged pid \($0.pid) (\($0.command))" } ?? "an unmanaged listener"
            annotated.portConflict = PortConflict(
                declaredPort: port,
                holder: detail,
                message: "port \(port) held by \(detail)",
                state: .held)
        }
        return annotated
    }

    /** The one restart path. Every refusal happens before anything stops: a
        client-side `stop && ensure` takes the server down and only then discovers
        a held resource or a broken config, leaving it down. The stop is
        non-retiring because the server is coming straight back, so resume-on-boot
        survives what `stop` would otherwise clear. */
    private func restartServers(
        _ params: RestartParams, rearm: Bool = true, reason: String, userInitiated: Bool = false
    ) async throws -> GroupResult {
        let merged = try await mergedSpecs(project: params.project)
        var wanted = merged.specs
        if let names = params.names {
            for name in names where !merged.specs.contains(where: { $0.name == name }) {
                throw ProjectConfigLoader.serverNotFound(name: name, project: params.project)
            }
            wanted = merged.specs.filter { names.contains($0.name) }
        }
        var prepared: [(spec: ServerSpec, supervisor: ServerSupervisor)] = []
        for spec in wanted {
            prepared.append((spec: spec, supervisor: await supervisor(project: params.project, spec: spec)))
        }
        /** The whole resolution pass runs before any server stops, the way
            groupUp resolves the set before it spawns any of it. `prepareSpawn`
            is where the port pre-check, the sibling rebind and the second config
            parse live, so running it after the stop meant `port-held` and
            `config-invalid` arrived with the server already down: exactly the
            failure a client-side stop-then-ensure has and this command exists to
            remove. `force` is needed because the servers are still up here, and
            prepareSpawn otherwise returns early for a running server. */
        for entry in prepared {
            try await prepareSpawn(
                target: ServerTargetParams(
                    name: entry.spec.name, port: params.port, project: params.project),
                supervisor: entry.supervisor, portOverride: params.port, force: true,
                userInitiated: userInitiated)
        }
        var results: [EnsureResult] = []
        for entry in prepared {
            /** Only an explicit restart re-arms the watch. Under the sweep the
                pending stamp has to survive as far as `deferWatchRestart`, which
                reads it, and clearing it here made that a no-op for every
                refusal raised after this point. */
            if rearm { await entry.supervisor.rearmWatch() }
            let activity = DaemonActivity.shared.begin(
                .restart, label: "\(serverID(project: params.project, name: entry.spec.name)): \(reason)")
            _ = await entry.supervisor.stop(deliberate: false, reason: reason)
            let restarted = await entry.supervisor.ensure(timeoutSeconds: params.timeoutSeconds)
            DaemonActivity.shared.end(
                activity, outcome: restarted.reason?.rawValue ?? restarted.server.phase.rawValue)
            results.append(restarted)
            DirectaLog.daemon.info("restart \(entry.spec.name)@\(params.project)")
        }
        return GroupResult(results: results.sorted { $0.server.server < $1.server.server })
    }

    /** One watch sweep over the resident supervisors. `now` is a parameter and
        the restarted ids come back, so tests drive sweeps with a synthetic clock
        instead of sleeping on the daemon's timer. */
    public func sweepWatches(now: Date = Date()) async -> [String] {
        guard watchEnabled else { return [] }
        var restarted: [String] = []
        for (id, supervisor) in supervisors {
            guard let changed = await supervisor.evaluateWatch(now: now), !changed.isEmpty else {
                continue
            }
            guard let split = parseServerID(id) else { continue }
            /** `changed` comes out of WatchPaths.resolve, which builds both the
                project root and every watched path through `.standardizedFileURL`;
                for a real, existing project directory that quietly rewrites a
                `/private/var` (or `/private/tmp`, `/private/etc`) prefix to its
                shorter symlinked form. Stripping against `split.project` (built by
                the fuller `canonicalProjectPath`, which keeps the `/private`
                spelling) would silently fail to match and leave the reason
                showing the whole absolute path, so the prefix is rebuilt with the
                exact same standardization WatchPaths used. */
            let projectRoot = URL(fileURLWithPath: split.project).standardizedFileURL.path
            let relative = changed.map {
                $0.replacingOccurrences(of: projectRoot + "/", with: "")
            }
            do {
                _ = try await restartServers(
                    RestartParams(
                        names: [split.name], project: split.project, timeoutSeconds: 60),
                    rearm: false, reason: "watch change in \(relative.joined(separator: ", "))")
                await supervisor.recordWatchRestart(now)
                restarted.append(id)
                DirectaLog.daemon.info(
                    "watch restart \(split.name)@\(split.project): \(relative.joined(separator: ", "))")
            } catch {
                /** A held resource or a held port: keep the pending change so the
                    edit fires once the refusal clears rather than being dropped.
                    Logged rather than swallowed, because a watch that silently
                    never fires is indistinguishable from one that is not armed. */
                DirectaLog.daemon.info(
                    "watch restart refused for \(split.name)@\(split.project): \(String(describing: error))")
                await supervisor.deferWatchRestart(now: now)
            }
        }
        return restarted.sorted()
    }

    /** Wave-parallel group start honoring the dependency graph: a wave holds
        servers whose dependencies all settled in earlier waves. waitFor .started
        launches without blocking on health; the default blocks until healthy. */
    private func groupUp(_ params: GroupParams) async throws -> GroupResult {
        let merged = try await mergedSpecs(project: params.project)
        var wanted = merged.specs
        if let only = params.only, !only.isEmpty {
            /** --only pulls in transitive dependencies so the subset can boot. */
            var keep = Set(only)
            var changed = true
            while changed {
                changed = false
                for spec in wanted where keep.contains(spec.name) {
                    for dep in spec.dependsOn ?? [] where !keep.contains(dep) {
                        keep.insert(dep)
                        changed = true
                    }
                }
            }
            wanted = wanted.filter { keep.contains($0.name) }
        }
        /** Port ownership is checked for the whole set before anything spawns, so
            a held port refuses the rollout instead of leaving half a project up
            next to a server that lost a race it never knew it entered. Servers
            already up skip the check against their own listeners.

            Hold the prepared supervisors rather than re-resolving them per wave.
            `supervisor(project:spec:)` re-applies the committed spec to anything
            not yet up, which would discard exactly what prepareSpawn just wrote:
            the rebound port, the substituted argv, and the injected env. A second
            lookup here spawned the child on the committed port while status
            reported the rebind. */
        var prepared: [String: ServerSupervisor] = [:]
        for spec in wanted {
            let target = ServerTargetParams(
                name: spec.name, port: params.port, project: params.project)
            let supervisor = await supervisor(project: params.project, spec: spec)
            try await prepareSpawn(
                target: target, supervisor: supervisor, portOverride: params.port,
                userInitiated: true)
            prepared[spec.name] = supervisor
        }
        guard case .success(let waves) = DependencyGraph.waves(specs: wanted) else {
            throw WireError(
                code: .configInvalid,
                hint: "run: directa config check",
                message: "dependency cycle in devservers.json")
        }
        let specsByName = Dictionary(uniqueKeysWithValues: wanted.map { ($0.name, $0) })
        var results: [EnsureResult] = []
        var failed = false
        for wave in waves {
            if failed { break }
            let waveResults = await withTaskGroup(of: EnsureResult.self) { group in
                for name in wave {
                    guard let spec = specsByName[name], let supervisor = prepared[name] else {
                        continue
                    }
                    group.addTask {
                        if spec.waitFor == .started {
                            let status = await supervisor.start()
                            return EnsureResult(
                                reason: status.phase == .failed ? .failed : nil, server: status)
                        }
                        return await supervisor.ensure(timeoutSeconds: params.timeoutSeconds)
                    }
                }
                var collected: [EnsureResult] = []
                for await result in group { collected.append(result) }
                return collected
            }
            results.append(contentsOf: waveResults.sorted { $0.server.server < $1.server.server })
            if waveResults.contains(where: { $0.reason != nil }) {
                /** A broken wave stops the rollout; later waves depend on it. */
                failed = true
            }
        }
        return GroupResult(results: results)
    }

    /** Reverse-wave parallel stop. */
    private func groupDown(_ params: GroupParams) async throws -> GroupResult {
        let merged = try await mergedSpecs(project: params.project)
        guard case .success(let waves) = DependencyGraph.waves(specs: merged.specs) else {
            throw WireError(
                code: .configInvalid,
                hint: "run: directa config check",
                message: "dependency cycle in devservers.json")
        }
        let specsByName = Dictionary(uniqueKeysWithValues: merged.specs.map { ($0.name, $0) })
        var results: [EnsureResult] = []
        for wave in waves.reversed() {
            let waveResults = await withTaskGroup(of: EnsureResult.self) { group in
                for name in wave {
                    guard let spec = specsByName[name] else { continue }
                    group.addTask { [weak self] in
                        guard let self else {
                            return EnsureResult(
                                server: ServerStatus(logPath: "", phase: .stopped, project: params.project, server: name))
                        }
                        let supervisor = await self.supervisor(project: params.project, spec: spec)
                        return EnsureResult(server: await supervisor.stop(reason: "requested by down"))
                    }
                }
                var collected: [EnsureResult] = []
                for await result in group { collected.append(result) }
                return collected
            }
            results.append(contentsOf: waveResults.sorted { $0.server.server < $1.server.server })
        }
        return GroupResult(results: results)
    }

    private func supervisor(project: String, spec: ServerSpec) async -> ServerSupervisor {
        let project = canonicalProjectPath(project)
        let id = serverID(project: project, name: spec.name)
        if let existing = supervisors[id] {
            /** A live run holds a materialized spawn spec (effective port, bound
                secondary ports, rewritten url). Re-resolving committed config for
                status must not clobber that, or agents see the committed port in
                status while the child listens on the rebind, and a stale flag
                fires for a config that matches what was actually spawned. */
            let current = await existing.status()
            if !current.hasLiveRun {
                await existing.updateSpec(spec)
            }
            return existing
        }
        let worktree = await CheckoutIdentity.worktreeDisplay(project: project)
        /** The git read above suspends this actor, so a concurrent call for
            the same server may have created its supervisor meanwhile; that
            one wins and goes through the existing-supervisor path, so one
            server never has two supervisors. */
        if supervisors[id] != nil {
            return await supervisor(project: project, spec: spec)
        }
        let created = ServerSupervisor(
            events: events, launcher: launcher, paths: paths, projectPath: project,
            registry: registry, spec: spec, stopTiming: stopTiming, worktree: worktree)
        supervisors[id] = created
        return created
    }

    private func respond<R: Codable & Sendable>(id: String, result: R) throws -> Data {
        try NDJSON.encodeLine(WireResponse(id: id, ok: true, result: result))
    }
}

/** NWListener over the unix socket. Each connection gets a hello frame, then an
    NDJSON request loop; each request runs in its own Task so a slow operation
    never blocks the connection. */
public final class ControlServer: Sendable {
    private let listener: NWListener
    private let socketPath: String

    public init(router: Router, socketPath: String) throws {
        self.socketPath = socketPath
        let socketDir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: socketDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        /** The flock in daemon main guarantees we are the only live daemon, so a
            leftover socket file is always stale and safe to remove. */
        unlink(socketPath)
        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params)
        listener.newConnectionHandler = { [router] connection in
            Self.serve(connection: connection, router: router)
        }
    }

    /** How long the listener gets to reach `.ready` before `startAccepting`
        gives up. Generous: this is not a latency budget, it is the line between
        a slow start and a daemon that will never serve, and crossing it means
        the process exits so launchd can try a clean one. */
    static let listenerReadySeconds = 10.0

    /** Ceiling on one pending (not yet newline-terminated) request line. The
        largest legitimate request is a `project.writeConfig` carrying a whole
        devservers.json, which is a handful of KB even for a large monorepo; 1
        MiB is generous headroom above that while still bounding how much a
        client streaming bytes with no newline can grow the daemon's memory.
        The client side is never capped: a `directa logs` response with no
        `--tail` can legitimately run tens of MB. */
    static let maxPendingRequestBytes = 1 << 20

    /** Returns when the listener is actually accepting, which is later than
        `NWListener.start` returns: start is asynchronous, and the socket path is
        unlinked during init and only recreated on the way to `.ready`. Treating
        the call as the readiness point told clients the daemon was up while a
        connect still got ENOENT, which is how a readiness check comes to pass
        for the wrong reason.

        Throws instead of waiting forever when the listener never gets there. A
        caller suspended on a callback that will not fire is a daemon that is
        running, holding the single-instance lock, and serving nothing, with no
        line saying why. */
    public func startAccepting() async throws {
        let socketPath = self.socketPath
        /** `stateUpdateHandler` can fire more than once (a `.ready` listener can
            still fail later), and resuming a continuation twice traps, so the
            first terminal state wins and the rest are dropped. */
        let settled = OSAllocatedUnfairLock(initialState: false)
        /** The last state seen, so the deadline below can say what the listener
            was stuck in rather than only that it never arrived. */
        let lastState = OSAllocatedUnfairLock(initialState: "setup")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let claim: @Sendable () -> Bool = {
                settled.withLock { done in
                    if done { return false }
                    done = true
                    return true
                }
            }
            /** `.setup` and `.waiting` are not terminal and were both swallowed
                by the default arm below, and `.waiting` retries indefinitely by
                design, so the promise above to throw rather than wait forever was
                not one the code kept. This deadline is what keeps it. `claim()`
                already makes a second resume a no-op, so a listener that becomes
                ready as the deadline fires still wins if it got there first. */
            Task {
                try? await Task.sleep(for: .seconds(Self.listenerReadySeconds))
                guard claim() else { return }
                let stuck = lastState.withLock { $0 }
                DirectaLog.daemon.error("control listener never became ready (state: \(stuck))")
                continuation.resume(
                    throwing: WireError(
                        code: .internalError,
                        hint: "run: directa doctor",
                        message:
                            "the daemon could not start listening on \(socketPath) (listener state: \(stuck))"
                    ))
            }
            listener.stateUpdateHandler = { state in
                lastState.withLock { $0 = String(describing: state) }
                switch state {
                case .ready:
                    /** Owner-only, and it has to run here: the socket file does
                        not exist until the listener is ready, so a chmod any
                        earlier targets an empty path and silently does nothing.
                        The containing directory is 0700, making this the second
                        layer rather than the only one. */
                    if chmod(socketPath, 0o600) != 0 {
                        DirectaLog.daemon.error(
                            "cannot restrict the control socket to owner-only: errno \(errno)")
                    }
                    if claim() { continuation.resume() }
                case .failed(let error):
                    DirectaLog.daemon.error("control listener failed: \(String(describing: error))")
                    if claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    DirectaLog.daemon.debug("control listener cancelled")
                    if claim() {
                        continuation.resume(
                            throwing: WireError(
                                code: .internalError,
                                message: "control listener was cancelled before it accepted"))
                    }
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "directa.control"))
        }
    }

    /** A client that exits without a shutdown handshake (every one-shot `directa`
        invocation) surfaces as `.failed` with a peer-close errno. Those are
        routine, so they log at debug; anything else is a real listener problem
        and stays at error. */
    private static func isRoutineDisconnect(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return code == .ENETDOWN || code == .ECONNRESET || code == .EPIPE || code == .ECANCELED
    }

    private static func serve(connection: NWConnection, router: Router) {
        let queue = DispatchQueue(label: "directa.connection")
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                if isRoutineDisconnect(error) {
                    DirectaLog.daemon.debug("control connection closed by peer: \(String(describing: error))")
                } else {
                    DirectaLog.daemon.error("control connection failed: \(String(describing: error))")
                }
                connection.cancel()
            case .cancelled:
                DaemonActivity.shared.clientDisconnected()
            default:
                break
            }
        }
        DaemonActivity.shared.clientConnected()
        connection.start(queue: queue)
        let hello = try? NDJSON.encodeLine(
            WireEvent(
                event: "hello",
                params: HelloParams(daemonVersion: DirectaVersion.version, proto: DirectaVersion.proto)))
        if let hello {
            connection.send(content: hello, completion: .contentProcessed { _ in })
        }
        receiveLoop(connection: connection, router: router, buffer: NDJSONBuffer())
    }

    private static func receiveLoop(connection: NWConnection, router: Router, buffer: NDJSONBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
            /** Receive callbacks are serial per connection, so the buffer moves
                through the recursion by value rather than shared mutation. */
            var advanced = buffer
            if let data, !data.isEmpty {
                for line in advanced.feed(data) {
                    /** Begun here, on the connection queue, so a request still
                        waiting for a pool thread is counted with its age. */
                    let head = try? JSONCoding.decoder().decode(WireRequestHead.self, from: line)
                    let activity = DaemonActivity.shared.begin(.request, label: head?.method ?? "unparseable")
                    Task {
                        let response = await router.handle(line: line, head: head)
                        connection.send(content: response, completion: .contentProcessed { _ in })
                        DaemonActivity.shared.end(activity)
                    }
                }
            }
            /** A client streaming bytes with no newline would otherwise grow
                this connection's buffer without limit; no request this daemon
                serves comes anywhere near the cap, so reaching it means the
                frame will never complete and the connection is refused rather
                than left to grow forever. No request id is known yet (nothing
                has framed), the same posture `handle(line:)` takes for an
                unparseable frame. */
            if advanced.pendingByteCount > maxPendingRequestBytes {
                let refusal =
                    (try? NDJSON.encodeLine(
                        WireResponse<WireEmpty>(
                            error: WireError(
                                code: .requestTooLarge,
                                /** No hint: the cause is a client writing raw
                                    NDJSON to the socket without a directa
                                    command to run as the fix (the CLI and app
                                    never trigger this), so a literal
                                    remediation command would be dishonest. */
                                message: "request line exceeded \(maxPendingRequestBytes) bytes with no newline"),
                            id: "?", ok: false))) ?? Data()
                connection.send(
                    content: refusal, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            receiveLoop(connection: connection, router: router, buffer: advanced)
        }
    }
}
