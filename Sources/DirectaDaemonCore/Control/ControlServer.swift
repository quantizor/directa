import DirectaKit
import Foundation
@preconcurrency import Network
import os

/** Routes decoded requests to the registry and supervisor pool. One instance per
    daemon; connection handling fans out but every method lands here. */
public actor Router {
    private let events: EventStore
    private let launcher: any ProcessLauncher
    private let paths: DirectaPaths
    private let registry: Registry
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
        launcher: any ProcessLauncher, paths: DirectaPaths, registry: Registry,
        watchEnabled: Bool = ProcessInfo.processInfo.environment["DIRECTA_NO_WATCH"] != "1"
    ) {
        self.watchEnabled = watchEnabled
        self.events = EventStore(url: paths.eventsFile)
        self.launcher = launcher
        self.paths = paths
        self.registry = registry
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
        let decoder = JSONCoding.decoder()
        guard let head = try? decoder.decode(WireRequestHead.self, from: line) else {
            return (try? NDJSON.encodeLine(
                WireResponse<WireEmpty>(
                    error: WireError(code: .usage, message: "unparseable request frame"),
                    id: "?", ok: false))) ?? Data("{\"id\":\"?\",\"ok\":false}\n".utf8)
        }
        do {
            guard let method = WireMethod(rawValue: head.method) else {
                throw WireError(code: .usage, message: "unknown method \(head.method)")
            }
            guard !restoring || Self.isServableWhileRestoring(method) else {
                throw WireError(
                    code: .daemonStarting,
                    hint: "run: directa daemon status",
                    message: "ddirecta is still restoring supervised servers and is not serving requests yet")
            }
            switch method {
            case .daemonInfo:
                return try respond(id: head.id, result: daemonInfo())
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
                /** register is the second way a spec enters the daemon, and until
                    now the only unchecked one: the committed-file path runs the
                    validator, so a spec `config check` would reject could still be
                    registered directly and then spawned. Refuse it at the seam. */
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
                let merged = try await mergedSpecs(project: project)
                let supervisor = try await resolvedSupervisor(target)
                if let spec = merged.specs.first(where: { $0.name == target.name }) {
                    try await lockGate(project: project, spec: spec)
                }
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
                let merged = try await mergedSpecs(project: project)
                let supervisor = try await resolvedSupervisor(target)
                if let spec = merged.specs.first(where: { $0.name == target.name }) {
                    try await lockGate(project: project, spec: spec)
                }
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
                    return try respond(
                        id: head.id,
                        result: CheckResult(
                            errors: view.errors,
                            host: view.host,
                            serverHosts: hosts.isEmpty ? nil : hosts,
                            servers: view.specs.map(\.name),
                            warnings: view.warnings,
                            worktree: CheckoutIdentity.worktreeDisplay(project: project)?.label))
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
                let stopped = await supervisor.stop()
                DirectaLog.daemon.info("stop \(target.name)@\(target.project)")
                return try respond(id: head.id, result: ServerResult(server: stopped))
            case .serverRestart:
                let request = try decoder.decode(WireRequest<RestartParams>.self, from: line)
                var params = request.params
                params.project = canonicalProjectPath(params.project)
                return try respond(
                    id: head.id,
                    result: try await restartServers(params, userInitiated: true))
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
                let supervisor = try await resolvedSupervisor(target)
                var since = request.params.since
                if let markID = request.params.sinceMark {
                    guard let markDate = await supervisor.resolveMark(markID) else {
                        throw WireError(
                            code: .notFound,
                            hint: "run: directa logs \(request.params.name) --stream mark",
                            message: "no mark with id '\(markID)' in \(request.params.name)'s log")
                    }
                    since = markDate
                }
                if let pattern = request.params.grep, let why = LogQuery.grepRejection(pattern) {
                    throw WireError(
                        code: .usage,
                        hint: "fix the pattern, or drop --grep to see every line",
                        message: "--grep is not a valid regular expression: \(why)")
                }
                let options = LogQueryOptions(
                    grep: request.params.grep,
                    since: since,
                    streams: request.params.streams.map(Set.init),
                    tail: request.params.tail)
                let lines = await supervisor.logQuery(options)
                return try respond(id: head.id, result: LogsQueryResult(lines: lines))
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
                var specsByName: [String: ServerSpec] = [:]
                for spec in merged.specs {
                    statuses[spec.name] = await annotatedStatus(
                        project: project, spec: spec)
                    specsByName[spec.name] = spec
                }
                let paths = self.paths
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
                    })
                return try respond(id: head.id, result: result)
            case .serverUnregister:
                let request = try decoder.decode(WireRequest<ServerTargetParams>.self, from: line)
                /** Canonicalized like every other project-scoped method: the
                    supervisor pool is keyed on canonical paths, so a symlinked
                    or trailing-slash spelling from the app or a deep link
                    dropped the registry row and left the supervisor resident. */
                let project = canonicalProjectPath(request.params.project)
                try await registry.unregister(project: project, name: request.params.name)
                supervisors[serverID(project: project, name: request.params.name)] = nil
                await events.post(
                    kind: .unregistered, project: project, server: request.params.name)
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
                group.addTask { _ = await supervisor.stop(deliberate: false) }
            }
        }
    }

    /** Forget registered projects whose checkout path is gone: stop children,
        bounce orphan pids, drop registry/state/locks/supervisors. Immediate at
        boot and on machine-wide status; the timer sweep (`sweepMissingProjects`)
        is the debounced variant. */
    public func pruneMissingProjects() async {
        for project in await registry.allProjects() {
            if FileManager.default.fileExists(atPath: project) { continue }
            await forgetMissingProject(project)
        }
    }

    /** Paths that failed the existence check on the previous sweep. A path must
        be missing on two consecutive sweeps before teardown: a network mount or
        a slow Finder move makes a path vanish for a moment, and a sweep that
        runs unattended every 30 seconds must not tear down a live project on
        one flaky stat. */
    private var missingProjectStrikes: Set<String> = []

    /** The timer-side sweep (ddirecta runs it every 30s after restore), so a
        discarded worktree's servers stop within a minute of the checkout going
        away instead of waiting for a machine-wide status or a reboot. */
    @discardableResult
    public func sweepMissingProjects() async -> Int {
        var pruned = 0
        let projects = await registry.allProjects()
        missingProjectStrikes = missingProjectStrikes.filter { projects.contains($0) }
        for project in projects {
            if FileManager.default.fileExists(atPath: project) {
                missingProjectStrikes.remove(project)
                continue
            }
            if !missingProjectStrikes.contains(project) {
                missingProjectStrikes.insert(project)
                continue
            }
            missingProjectStrikes.remove(project)
            await forgetMissingProject(project)
            pruned += 1
        }
        return pruned
    }

    /** Startup recovery: prune vanished checkouts first, reconcile persisted
        locks, then restore servers with boot intent. A recorded pid that is gone
        becomes crashed(daemon-restart); a live orphan (its spool fd kept it
        healthy while the daemon was away) is group-killed, since exit forensics
        are unknowable for non-children. Never adopted silently. What comes back:
        any server whose start intent survives (resumeOnBoot), which a machine
        shutdown's drain leaves set, plus the classic daemon-crash case of a
        phase left running/starting. A deliberate stop clears the flag, so only
        those stay down. Servers still paused under a live resource lock are left
        alone: starting them would fight the harness.

        Specs resolve through the merged view (devservers.json + ad-hoc registry),
        the same path ensure/status use. Config-defined servers are never written
        into registry.json, so a registry-only lookup would silently skip every
        committed server on boot. A rename/delete with no matching spec drops the
        orphaned state row instead of retrying forever. */
    public func recoverAtStartup() async {
        await pruneMissingProjects()
        await reconcileLocksAtStartup()
        var toStart: [(project: String, spec: ServerSpec)] = []
        for (id, persisted) in await registry.allPersistedState() {
            guard let separator = id.range(of: "::") else { continue }
            let project = String(id[id.startIndex..<separator.lowerBound])
            let name = String(id[separator.upperBound...])
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
                try? await registry.removeState(serverID: id)
                continue
            case .unavailable:
                DirectaLog.daemon.info(
                    "recover defer \(name)@\(project): config unreadable; keeping resume intent")
                continue
            case .found(let spec):
                if let pid = persisted.pid.flatMap(ProcessTree.narrowed),
                    let identity = ProcessTree.identity(of: pid)
                {
                    await bounceOrphan(identity, project: project, name: name)
                } else if leftActive {
                    await events.post(
                        kind: .crashed, project: project, server: name, detail: "daemon-restart")
                }
                try? await registry.updateState(serverID: id) { entry in
                    entry.lastExit = entry.lastExit ?? LastExit(at: Date())
                    entry.phase = .crashed
                    entry.pid = nil
                }
                if leftActive || wantsRestore {
                    toStart.append((project: project, spec: spec))
                }
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
            guard let separator = id.range(of: "::") else { continue }
            let project = String(id[id.startIndex..<separator.lowerBound])
            let name = String(id[separator.upperBound...])
            if case .missing = await resolveSpecForRecover(project: project, name: name) {
                DirectaLog.daemon.info("recover prune \(name)@\(project): orphaned state row")
                try? await registry.removeState(serverID: id)
            }
        }
        /** SIGKILL of the agent (jetsam) skips LaunchdJobLauncher's defer
            bootout, so one-shot child labels accumulate in the gui domain.
            Reap only when this process is that agent: tests and `--foreground`
            never registered those jobs, and must not bootout the user's. */
        if LaunchdJobLauncher.runningAsAgent {
            var keepingPids: Set<pid_t> = []
            for supervisor in supervisors.values {
                if let pid = await supervisor.status().pid.flatMap(ProcessTree.narrowed) {
                    keepingPids.insert(pid)
                }
            }
            let reaped = LaunchdJobs.reapStaleChildJobs(keepingPids: keepingPids)
            if reaped > 0 {
                DirectaLog.daemon.info("reaped \(reaped) leftover child launchd job(s)")
            }
        }
    }

    /** Group-kill a live non-child left over from a prior daemon (or a prune that
        could not stop through the supervisor). Signals only while the snapshotted
        start time still matches: a recycled pid must not be killed. */
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
        /** A server is spawned as a session leader (createSession), so its
            session id is its own pid; sweeping the session as well as the parent
            chain catches an orphan descendant that setpgid'd or setsid'd out of
            the group, the same union stop() and the crash path use. */
        let descendants = ProcessTree.liveDescendants(
            rootPid: pid, sessionID: pid, snapshot: [])
        ProcessTree.signalTree(
            descendants: descendants, revalidate: true, rootIdentity: root, rootPid: pid,
            signal: SIGTERM)
        /** Poll with identity, not kill(pid,0): a recycled number must end the
            wait as "gone" rather than escalate into the new process. A shorter
            grace than an ordinary stop's 7s default: an orphan bounce runs during
            boot restore, where a prior daemon's leftover child should yield
            quickly so the fresh supervisor can claim the port. */
        let orphanBounceGraceSeconds = 2.0
        let graceDeadline = ContinuousClock.now.advanced(by: .seconds(orphanBounceGraceSeconds))
        while ContinuousClock.now < graceDeadline,
            ProcessTree.shouldSignal(
                snapshotted: root, live: ProcessTree.identity(of: pid))
        {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if ProcessTree.shouldSignal(
            snapshotted: root, live: ProcessTree.identity(of: pid))
        {
            ProcessTree.signalTree(
                descendants: descendants, revalidate: true, rootIdentity: root, rootPid: pid,
                signal: SIGKILL)
        }
        await events.post(
            kind: .crashed, project: project, server: name,
            detail: "daemon-restart: orphan pid \(pid) bounced")
    }

    /** Stop and forget one vanished checkout. Config is unreadable once the path
        is gone, so this walks supervisors + registry + state directly instead of
        groupDown / mergedSpecs. `project` must be the registry key as stored
        (already canonical at registration): re-canonicalizing a deleted path can
        change `/private/var` ↔ `/var` spelling and miss every lookup. */
    private func forgetMissingProject(_ project: String) async {
        let prefix = "\(project)::"
        /** Snapshot identities before teardown: a composite tree can outlive a
            no-op stop (phase already crashed/failed after the checkout vanished),
            so we keep the recorded ProcessIdentity and bounce only while that
            start time still matches. */
        var liveRoots: [(identity: ProcessIdentity, name: String)] = []
        var names = Set(await registry.specs(project: project).map(\.name))
        for (id, supervisor) in supervisors where id.hasPrefix(prefix) {
            guard let separator = id.range(of: "::") else { continue }
            let name = String(id[separator.upperBound...])
            names.insert(name)
            let status = await supervisor.status()
            if let pid = status.pid.flatMap(ProcessTree.narrowed),
                let identity = ProcessTree.identity(of: pid)
            {
                liveRoots.append((identity: identity, name: name))
            }
        }
        for (id, persisted) in await registry.allPersistedState() where id.hasPrefix(prefix) {
            guard let separator = id.range(of: "::") else { continue }
            let name = String(id[separator.upperBound...])
            names.insert(name)
            if let pid = persisted.pid.flatMap(ProcessTree.narrowed),
                let identity = ProcessTree.identity(of: pid),
                !liveRoots.contains(where: { $0.identity.pid == pid })
            {
                liveRoots.append((identity: identity, name: name))
            }
        }
        let sortedNames = names.sorted()
        DirectaLog.daemon.info(
            "prune missing project \(project) (\(sortedNames.joined(separator: ",")))")
        for name in sortedNames {
            let id = serverID(project: project, name: name)
            if let supervisor = supervisors[id] {
                _ = await supervisor.stop()
                await events.post(
                    kind: .stopped, project: project, server: name, detail: "project path gone")
            }
            supervisors[id] = nil
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
        for name in sortedNames {
            await events.post(
                kind: .unregistered, project: project, server: name, detail: "project path gone")
        }
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

    private func daemonInfo() -> DaemonInfo {
        DaemonInfo(
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

    private func exitDaemon() {
        exit(0)
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
                        hint: "run: directa register --name \(name) --write --force",
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
        let check = CheckResult(
            errors: view.errors,
            host: view.host,
            serverHosts: hosts.isEmpty ? nil : hosts,
            servers: view.specs.map(\.name),
            warnings: view.warnings,
            worktree: CheckoutIdentity.worktreeDisplay(project: project)?.label)
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
            let current = await supervisor.status()
            switch current.phase {
            case .running, .starting, .stopping, .unhealthy:
                return
            case .crashed, .failed, .stopped:
                break
            }
        }
        let merged = try await mergedSpecs(project: target.project)
        guard var spec = merged.specs.first(where: { $0.name == target.name }) else {
            throw WireError(
                code: .notFound,
                hint: "run: directa status --json",
                message: "no server named '\(target.name)' in \(target.project)")
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
                    hint: "run: directa ensure \(target.name) --project \(target.project)",
                    message:
                        "refusing to start '\(target.name)' from \(target.project)/devservers.json: this project's committed config has not been approved. Start a server there once by hand to approve it.")
            }
        }
        let overlay = LocalOverlay.load(project: target.project)
        let overlayServer = overlay?.servers?[target.name]
        spec = LocalOverlay.apply(spec: spec, overlay: overlayServer, project: target.project)
        /** The declared host stays the spawn host: a linked worktree keeps it
            (its name surfaces as a display label, never a subdomain), so URLs
            already carry the right host and only the port can differ. */
        let declaredPort = spec.port
        let id = serverID(project: target.project, name: target.name)
        let persistedBound = await registry.persistedState(serverID: id)?.boundPort
        var effective =
            portOverride ?? overlayServer?.port ?? persistedBound ?? declaredPort
        var conflict: PortConflict?
        if let port = effective {
            let targetID = id
            let draft = PortClaim.resolve(spec: spec, effectivePort: port)
            guard let draftClaim = draft.claim, draft.error == nil else {
                throw WireError(
                    code: .configInvalid, hint: "run: directa config check",
                    message: draft.error ?? "invalid port claim")
            }
            if let busy = await firstBusyPort(in: draftClaim, excluding: targetID) {
                let holder = await managedHolder(port: busy.port, excluding: targetID)
                if let holder, CheckoutIdentity.shareCommonDir(target.project, holder.project),
                    draftClaim.relative.contains(busy.port)
                {
                    let rebound = await allocateSiblingPort(
                        declared: declaredPort ?? port, excluding: targetID, project: target.project,
                        spec: spec)
                    conflict = PortConflict(
                        declaredPort: declaredPort ?? port,
                        effectivePort: rebound,
                        holder: "\(holder.server)@\(holder.project)",
                        message:
                            "port \(busy.port) held by sibling '\(holder.server)' in \(holder.project); rebound to \(rebound)",
                        state: .rebound)
                    effective = rebound
                    try? await registry.updateState(serverID: id) { $0.boundPort = rebound }
                } else if let holder {
                    DirectaLog.daemon.error(
                        "port-held \(busy.port) by \(holder.server)@\(holder.project) for \(target.name)")
                    throw WireError(
                        code: .portHeld,
                        hint: "run: directa stop \(holder.server) --project \(holder.project)",
                        message:
                            "port \(busy.port) is held by managed server '\(holder.server)' in \(holder.project)"
                    )
                } else if let squatter = PortGuard.listenerInfo(port: busy.port) {
                    throw WireError(
                        code: .portHeld,
                        hint: "run: kill \(squatter.pid)  (verify first: ps -p \(squatter.pid))",
                        message:
                            "port \(busy.port) is held by unmanaged pid \(squatter.pid) (\(squatter.command))"
                    )
                } else {
                    throw WireError(
                        code: .portHeld,
                        message: "port \(busy.port) already has a listener that directa does not manage"
                    )
                }
            }
        }
        let resolved = PortClaim.resolve(spec: spec, effectivePort: effective)
        guard let claim = resolved.claim, resolved.error == nil else {
            throw WireError(
                code: .configInvalid, hint: "run: directa config check",
                message: resolved.error ?? "invalid port claim")
        }
        if let busy = await firstBusyPort(in: claim, excluding: id) {
            throw WireError(
                code: .portHeld,
                message: "port \(busy.port) is still busy after rebind resolution")
        }
        let materialized = PortMaterializer.materialize(spec: spec, effectivePort: effective)
        await supervisor.updateSpec(materialized)
        await supervisor.setPortMeta(
            claim: claim, declaredPort: declaredPort, effectivePort: effective,
            portConflict: conflict)
    }

    /** First claimed port that is held (managed or unmanaged). Absolutes and
        relatives are treated the same for freeness; only sibling rebind cares
        which set a conflict came from. */
    private func firstBusyPort(in claim: PortClaim, excluding targetID: String) async -> (
        port: Int, managed: Bool
    )? {
        for port in claim.allPorts {
            if await managedHolder(port: port, excluding: targetID) != nil {
                return (port: port, managed: true)
            }
            /** A listener the target itself owns is not a conflict for the
                target: it is the run about to be replaced, or a sibling ensure
                that just won the single flight. `managedHolder` excludes the
                target by id, so without this the target's own socket falls
                through to the unmanaged-squatter branch and one server reports
                its own port as held. */
            if await targetOwnsPort(port, id: targetID) { continue }
            if PortGuard.isListening(port: port) {
                return (port: port, managed: false)
            }
        }
        return nil
    }

    private func targetOwnsPort(_ port: Int, id: String) async -> Bool {
        guard let supervisor = supervisors[id] else { return false }
        let status = await supervisor.status()
        switch status.phase {
        case .running, .starting, .unhealthy:
            break
        case .crashed, .failed, .stopped, .stopping:
            return false
        }
        return status.declaredPort == port || status.effectivePort == port
            || status.observedPort == port || (status.ports?.values.contains(port) ?? false)
    }

    /** How many candidates a sibling rebind tries before giving up and handing
        back the last one, which then fails the ordinary port-held way. A bound
        rather than a budget: the search walks consecutive ports, so needing more
        than this many means the range is genuinely full and a wider search would
        only take longer to say so. */
    private static let siblingRebindAttempts = 200

    /** Where a rebind is allowed to land. Stays clear of the low ports a project
        actually declares and stops short of the ephemeral range the kernel hands
        to outbound connections, which a listener cannot hold reliably. */
    private static let siblingPortRange = 10_000...65_000

    private func allocateSiblingPort(
        declared: Int, excluding: String, project: String, spec: ServerSpec
    ) async -> Int {
        var candidate = CheckoutIdentity.siblingPortCandidate(declared: declared, project: project)
        for _ in 0..<Self.siblingRebindAttempts {
            let resolved = PortClaim.resolve(spec: spec, effectivePort: candidate)
            if let claim = resolved.claim, resolved.error == nil,
                await firstBusyPort(in: claim, excluding: excluding) == nil
            {
                return candidate
            }
            candidate += 1
            if candidate > Self.siblingPortRange.upperBound {
                candidate = Self.siblingPortRange.lowerBound
            }
        }
        return candidate
    }

    /** Wait until every claimed port is free, or return the first still-busy port. */
    private func waitForClaimFree(claim: PortClaim, budgetSeconds: Double = 2) async -> Int? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(budgetSeconds))
        while true {
            var busy: Int?
            for port in claim.allPorts where PortGuard.isListening(port: port) {
                busy = port
                break
            }
            if busy == nil { return nil }
            if ContinuousClock.now >= deadline { return busy }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /** Which managed server holds `port`, if any. The resident supervisor pool
        answers for servers this daemon has been asked about; state.json answers
        for the rest, since the pool is built lazily and a server started before
        this daemon's first request for it has no entry there at all. A persisted
        row counts only while its recorded pid is still alive. */
    private func managedHolder(port: Int, excluding targetID: String) async -> (
        project: String, server: String
    )? {
        for (id, other) in supervisors where id != targetID {
            let status = await other.status()
            let active =
                status.phase == .running || status.phase == .starting || status.phase == .unhealthy
            if active,
                status.effectivePort == port || status.declaredPort == port
                    || status.observedPort == port
                    || (status.ports?.values.contains(port) ?? false)
            {
                return (project: status.project, server: status.server)
            }
        }
        for (id, persisted) in await registry.allPersistedState() where id != targetID {
            guard supervisors[id] == nil else { continue }
            let active =
                persisted.phase == .running || persisted.phase == .starting
                || persisted.phase == .unhealthy
            guard active, let pid = persisted.pid, ProcessTree.isAlive(pid) else { continue }
            guard let separator = id.range(of: "::") else { continue }
            let project = String(id[id.startIndex..<separator.lowerBound])
            let name = String(id[separator.upperBound...])
            guard let merged = try? await mergedSpecs(project: project),
                let spec = merged.specs.first(where: { $0.name == name })
            else { continue }
            let bound = persisted.boundPort ?? spec.port
            let resolved = PortClaim.resolve(spec: spec, effectivePort: bound)
            if let claim = resolved.claim, claim.allPorts.contains(port) {
                return (project: project, server: name)
            }
            guard bound == port else { continue }
            return (project: project, server: name)
        }
        return nil
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
            switch status.phase {
            case .running, .starting, .unhealthy, .stopping:
                guard shouldPause else {
                    /** Sound for the whole hold: lockGate refuses to start a
                        declarer while a live holder owns the resource, so this
                        set can only shrink. */
                    live.append(spec.name)
                    continue
                }
                /** Non-retiring stop: boot intent survives so a daemon crash
                    mid-hold can still bring the server back if the holder is gone. */
                _ = await supervisor.stop(deliberate: false)
                paused.append(spec.name)
                DirectaLog.daemon.info(
                    "lock \(params.resource) paused \(spec.name)@\(params.project)")
            case .stopped, .crashed, .failed:
                break
            }
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
            throw WireError(
                code: .notFound,
                hint: "run: directa status --json",
                message: "no server named '\(params.name)' is registered for \(params.project)"
            )
        }
        return await supervisor(project: params.project, spec: spec)
    }

    private func statusList(_ params: ProjectParams) async throws -> ServerListResult {
        /** An empty project means machine-wide (daemon restart, doctor, the app);
            machine-wide reads skip config errors rather than failing the sweep. */
        if params.project.isEmpty {
            await pruneMissingProjects()
            var statuses: [ServerStatus] = []
            for project in await registry.allProjects() {
                var specs = (try? await mergedSpecs(project: project))?.specs
                if specs == nil {
                    specs = await registry.specs(project: project)
                }
                guard let specs else { continue }
                for spec in specs {
                    if let name = params.name, name != spec.name { continue }
                    statuses.append(await annotatedStatus(project: project, spec: spec))
                }
            }
            return ServerListResult(servers: statuses)
        }
        let merged = try await mergedSpecs(project: params.project)
        var statuses: [ServerStatus] = []
        for spec in merged.specs {
            if let name = params.name, name != spec.name { continue }
            statuses.append(await annotatedStatus(project: params.project, spec: spec))
        }
        return ServerListResult(
            servers: statuses, trusted: await registry.isTrusted(project: params.project))
    }

    /** The supported way to read a status for a response: every reader gets the
        latent-port-conflict annotation. A handler that calls `supervisor.status()`
        directly reports a stopped server without naming the holder keeping it
        down, so route status reads through here. */
    private func annotatedStatus(project: String, spec: ServerSpec) async -> ServerStatus {
        let status = await supervisor(project: project, spec: spec).status()
        return await annotateLatentPortConflict(
            status, excluding: serverID(project: project, name: spec.name))
    }

    /** When a server is not up but its declared port is held, surface a latent
        conflict so session context warns before the agent runs ensure. */
    private func annotateLatentPortConflict(_ status: ServerStatus, excluding: String) async -> ServerStatus {
        guard status.portConflict == nil else { return status }
        switch status.phase {
        case .stopped, .crashed, .failed:
            break
        case .running, .starting, .stopping, .unhealthy:
            return status
        }
        guard let port = status.declaredPort ?? status.effectivePort else { return status }
        var annotated = status
        if let holder = await managedHolder(port: port, excluding: excluding) {
            let sibling = CheckoutIdentity.shareCommonDir(status.project, holder.project)
            annotated.portConflict = PortConflict(
                declaredPort: port,
                holder: "\(holder.server)@\(holder.project)",
                message: sibling
                    ? "port \(port) held by sibling '\(holder.server)' in \(holder.project); ensure will auto-rebind"
                    : "port \(port) held by '\(holder.server)' in \(holder.project); run: directa stop \(holder.server) --project \(holder.project)",
                state: .held)
        } else if PortGuard.isListening(port: port) {
            let detail = PortGuard.listenerInfo(port: port).map {
                "unmanaged pid \($0.pid) (\($0.command))"
            } ?? "an unmanaged listener"
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
        _ params: RestartParams, rearm: Bool = true, userInitiated: Bool = false
    ) async throws -> GroupResult {
        let merged = try await mergedSpecs(project: params.project)
        var wanted = merged.specs
        if let names = params.names {
            for name in names where !merged.specs.contains(where: { $0.name == name }) {
                throw WireError(
                    code: .notFound,
                    hint: "run: directa status --json",
                    message: "no server named '\(name)' in \(params.project)")
            }
            wanted = merged.specs.filter { names.contains($0.name) }
        }
        var prepared: [(spec: ServerSpec, supervisor: ServerSupervisor)] = []
        for spec in wanted {
            try await lockGate(project: params.project, spec: spec)
            try await refuseIfPaused(project: params.project, spec: spec)
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
            _ = await entry.supervisor.stop(deliberate: false)
            results.append(await entry.supervisor.ensure(timeoutSeconds: params.timeoutSeconds))
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
            guard let split = Self.splitServerID(id) else { continue }
            /** The daemon never acts on a project's committed config before trust
                is recorded. `restartServers` runs autonomously here (userInitiated
                defaults to false), so `prepareSpawn` enforces the same gate; this
                skips the work early and cleanly for an untrusted project rather
                than letting the restart raise and defer. */
            guard await registry.isTrusted(project: split.project) else { continue }
            let relative = changed.map {
                $0.replacingOccurrences(of: split.project + "/", with: "")
            }
            do {
                _ = try await restartServers(
                    RestartParams(
                        names: [split.name], project: split.project, timeoutSeconds: 60),
                    rearm: false)
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

    static func splitServerID(_ id: String) -> (name: String, project: String)? {
        guard let separator = id.range(of: "::", options: .backwards) else { return nil }
        return (
            name: String(id[separator.upperBound...]),
            project: String(id[id.startIndex..<separator.lowerBound])
        )
    }

    /** A server sitting in a live holder's paused set must not be resurrected
        behind the lock's back. lockGate covers an external holder of a resource
        this server declares; this covers the case where the hold already stopped
        it. */
    private func refuseIfPaused(project: String, spec: ServerSpec) async throws {
        for declaration in spec.locks ?? [] {
            let key = Self.lockKey(project: project, resource: declaration.name)
            await releaseOrphanedLock(key: key)
            guard let holder = resourceLocks[key], holder.paused.contains(spec.name) else {
                continue
            }
            throw WireError(
                code: .resourceLocked,
                hint: "wait for pid \(holder.pid) to finish, or verify it: ps -p \(holder.pid)",
                message:
                    "'\(spec.name)' is paused by the hold on '\(declaration.name)' (pid \(holder.pid)); it comes back when that run releases"
            )
        }
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
                        return EnsureResult(server: await supervisor.stop())
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
            switch await existing.status().phase {
            case .running, .starting, .unhealthy, .stopping:
                break
            case .stopped, .crashed, .failed:
                await existing.updateSpec(spec)
            }
            return existing
        }
        let created = ServerSupervisor(
            events: events, launcher: launcher, paths: paths, projectPath: project,
            registry: registry, spec: spec)
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
    private let router: Router
    private let socketPath: String

    public init(router: Router, socketPath: String) throws {
        self.router = router
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
                            "ddirecta could not start listening on \(socketPath) (listener state: \(stuck))"
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
                break
            default:
                break
            }
        }
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
                    Task {
                        let response = await router.handle(line: line)
                        connection.send(content: response, completion: .contentProcessed { _ in })
                    }
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            receiveLoop(connection: connection, router: router, buffer: advanced)
        }
    }
}
