import DirectaKit
import DirectaTestSupport
import Foundation
import Testing
import os

@testable import DirectaDaemonCore

private struct RecoverEnv {
    let paths: DirectaPaths
    let projectPath: String
}

private func makeRecoverEnv() throws -> RecoverEnv {
    let base = try TemporaryTree.directory(named: "recover")
    let project = base.appending(path: "proj")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    return RecoverEnv(
        paths: DirectaPaths(dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
        projectPath: project.path)
}

private func writeDevservers(project: String, serversJSON: String) throws {
    let body = """
    {
      "servers": \(serversJSON),
      "version": 1
    }
    """
    try Data(body.utf8).write(
        to: URL(fileURLWithPath: project).appending(path: "devservers.json"))
}

private func statusList(router: Router, project: String) async throws -> [ServerStatus] {
    let line = try NDJSON.encodeLine(
        WireRequest(
            id: "status", method: WireMethod.serverStatus.rawValue,
            params: ProjectParams(project: project)))
    let data = await router.handle(line: line)
    let response = try JSONCoding.decoder().decode(WireResponse<ServerListResult>.self, from: data)
    guard response.ok, let result = response.result else {
        throw WireError(code: .internalError, message: response.error?.message ?? "status failed")
    }
    return result.servers
}

private func stopServer(router: Router, project: String, name: String) async {
    let line = try? NDJSON.encodeLine(
        WireRequest(
            id: "stop", method: WireMethod.serverStop.rawValue,
            params: ServerTargetParams(name: name, project: project)))
    guard let line else { return }
    _ = await router.handle(line: line)
}

private func eventsList(router: Router, project: String) async throws -> [EventRecord] {
    let line = try NDJSON.encodeLine(
        WireRequest(
            id: "events", method: WireMethod.eventsQuery.rawValue,
            params: EventsQueryParams(project: project)))
    let data = await router.handle(line: line)
    let response = try JSONCoding.decoder().decode(WireResponse<EventsQueryResult>.self, from: data)
    guard response.ok, let result = response.result else {
        throw WireError(code: .internalError, message: response.error?.message ?? "events failed")
    }
    return result.events
}

/** Records `AgentJobs.bootOut` calls instead of shelling out, so a test can
    prove a stale child job was reaped (or a live one was not) through the
    injected fake, never against the real gui launchd domain the daemon and the
    user's own dev servers run in. */
private final class RecordingAgentJobs: Sendable {
    private let bootedOutLabels = OSAllocatedUnfairLock(initialState: [String]())
    private let listings = OSAllocatedUnfairLock(initialState: 0)

    var labels: [String] { bootedOutLabels.withLock { $0 } }

    /** How many times the job list was read (each one a `launchctl` shell-out
        in production). */
    var listingCount: Int { listings.withLock { $0 } }

    func agentJobs(listing jobs: [LaunchdJobs.ChildJob]) -> AgentJobs {
        agentJobs(answering: [.listed(jobs)])
    }

    /** Answers the reads in `answers` in order, repeating the last. */
    func agentJobs(answering answers: [LaunchdJobs.ChildJobListing]) -> AgentJobs {
        AgentJobs(
            bootOut: { [bootedOutLabels] job in bootedOutLabels.withLock { $0.append(job.label) } },
            listChildJobs: { [listings] in
                let read = listings.withLock { count in
                    count += 1
                    return count
                }
                return answers[min(read, answers.count) - 1]
            })
    }
}

/** An adopting launcher that counts real spawns, so a test can prove a refused
    start never reached the launcher. `adopt` is test-controlled through
    `gate`, as `FakeAdoptLauncher`'s is. */
private final class SpawnCountingLauncher: ProcessLauncher {
    let gate: AdoptGate
    private let inner: any ProcessLauncher = SubprocessLauncher()
    private let runs = OSAllocatedUnfairLock(initialState: 0)

    init(gate: AdoptGate) {
        self.gate = gate
    }

    var runCount: Int { runs.withLock { $0 } }

    func run(
        argv: [String], capture: SpawnCapture, cwd: String?, environment: [String: String],
        onExitedBeforeWatch: @escaping @Sendable (pid_t?) async -> Void,
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome {
        runs.withLock { $0 += 1 }
        return await inner.run(
            argv: argv, capture: capture, cwd: cwd, environment: environment,
            onExitedBeforeWatch: onExitedBeforeWatch, onSpawn: onSpawn)
    }

    func prepareAdopt(pid: pid_t) -> Bool { true }

    func adopt(pid: pid_t, label: String) async -> ProcessOutcome {
        await gate.outcome()
    }
}

/** Re-reads fast enough that a test drives the whole retry window without
    waiting on production delays. */
private let quickRetry = DeferredSurvivorRetry(
    firstDelay: .milliseconds(10), longestDelay: .milliseconds(20), window: .seconds(30))

/** A trusted project declaring `serversJSON` whose `web` row records `survivor`
    as a running pid with restore intent, the shape boot restore defers when
    launchd's job list does not answer. */
private func seedWebSurvivor(
    _ env: RecoverEnv, registry: Registry, serversJSON: String, survivor: pid_t
) async throws {
    try writeDevservers(project: env.projectPath, serversJSON: serversJSON)
    try await registry.setTrusted(project: env.projectPath)
    let startedAt = Date()
    try await registry.updateState(
        serverID: serverID(project: env.projectPath, name: "web"), writer: .router
    ) { entry in
        entry.phase = .running
        entry.pid = Int(survivor)
        entry.resumeOnBoot = true
        entry.startedAt = startedAt
    }
}

private let sleepingWebJSON = """
    {
      "web": {
        "command": ["/bin/sh", "-c", "sleep 30"]
      }
    }
    """

private func ensureResponse(
    router: Router, project: String, name: String
) async throws -> WireResponse<EnsureResult> {
    let line = try NDJSON.encodeLine(
        WireRequest(
            id: "ensure", method: WireMethod.serverEnsure.rawValue,
            params: EnsureParams(name: name, project: project, timeoutSeconds: 5)))
    return try JSONCoding.decoder().decode(
        WireResponse<EnsureResult>.self, from: await router.handle(line: line))
}

private func stopResponse(
    router: Router, project: String, name: String
) async throws -> WireResponse<ServerResult> {
    let line = try NDJSON.encodeLine(
        WireRequest(
            id: "stop", method: WireMethod.serverStop.rawValue,
            params: ServerTargetParams(name: name, project: project)))
    return try JSONCoding.decoder().decode(
        WireResponse<ServerResult>.self, from: await router.handle(line: line))
}

private func logTexts(router: Router, project: String, name: String) async throws -> [String] {
    let line = try NDJSON.encodeLine(
        WireRequest(
            id: "logs", method: WireMethod.logsQuery.rawValue,
            params: LogsQueryParams(name: name, project: project, streams: [.out])))
    let data = await router.handle(line: line)
    let response = try JSONCoding.decoder().decode(WireResponse<LogsQueryResult>.self, from: data)
    guard response.ok, let result = response.result else {
        throw WireError(code: .internalError, message: response.error?.message ?? "logs failed")
    }
    return result.lines.map(\.text)
}


@Suite(.temporaryTree) struct RecoverAtStartupTests {
    /** Config-defined servers live only in devservers.json (registry.servers is
        empty for them). Boot restore must still find the spec and bring them up. */
    @Test func restoresConfigDefinedServerWithResumeIntent() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let id = serverID(project: env.projectPath, name: "web")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .stopped
            entry.resumeOnBoot = true
            entry.pid = nil
        }
        #expect(await registry.spec(project: env.projectPath, name: "web") == nil)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        let web = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "web" }
        #expect(web != nil)
        #expect(web?.phase == .starting || web?.phase == .running)
        #expect(web?.pid != nil)
        await stopServer(router: router, project: env.projectPath, name: "web")
    }

    /** The trust gate. A malicious repo's devservers.json must never be
        auto-started: boot restore resolves the committed spec but `prepareSpawn`
        refuses it while the project's config has never been approved (no trust
        flag), so the server stays down. The mirror of
        `restoresConfigDefinedServerWithResumeIntent`, which sets trust and does
        spawn; the only difference here is the missing approval. */
    @Test func untrustedConfigDefinedServerIsNotRestored() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        /** Deliberately not trusted: no start-shaped command ever approved it. */
        let id = serverID(project: env.projectPath, name: "web")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .stopped
            entry.resumeOnBoot = true
            entry.pid = nil
        }
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        let web = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "web" }
        #expect(web?.pid == nil)
        #expect(web?.phase != .running)
        #expect(web?.phase != .starting)
        /** Recover is autonomous, so it must not silently grant trust either. */
        #expect(await registry.isTrusted(project: env.projectPath) == false)
    }

    /** A rename leaves resume intent under the old name. Recover must drop the
        orphan row, not resurrect a ghost. */
    @Test func dropsOrphanStateWhenSpecMissing() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "myproj": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let staleID = serverID(project: env.projectPath, name: "dev")
        try await registry.updateState(serverID: staleID, writer: .router) { entry in
            entry.phase = .stopped
            entry.resumeOnBoot = true
        }
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        #expect(await registry.persistedState(serverID: staleID) == nil)
        let statuses = try await statusList(router: router, project: env.projectPath)
        #expect(statuses.contains { $0.server == "dev" } == false)
        #expect(statuses.allSatisfy { $0.phase == .stopped })
    }

    /** A renamed or removed server whose recorded run is still alive: once the
        row goes, nothing would ever supervise that process, so recover bounces
        it first, but only with the same start-time proof adoption requires. A
        pid whose process started long after the row recorded it is a recycled
        number and is left alone. */
    @Test(arguments: [true, false])
    func bouncesALiveSurvivorWhoseSpecIsGoneOnlyWithStartTimeProof(recordedJustNow: Bool) async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "myproj": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        let staleID = serverID(project: env.projectPath, name: "dev")
        try await registry.updateState(serverID: staleID, writer: .router) { entry in
            entry.phase = .running
            entry.pid = Int(survivor)
            entry.resumeOnBoot = true
            entry.startedAt = recordedJustNow ? Date() : Date().addingTimeInterval(-3_600)
        }
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        #expect(await registry.persistedState(serverID: staleID) == nil)

        /** A row from an earlier boot is left alone, so there is nothing to
            wait out. */
        let gone: Bool
        if recordedJustNow {
            gone = try await awaitExit(survivor, within: .seconds(5))
        } else {
            gone = kill(survivor, 0) != 0
        }
        #expect(gone == recordedJustNow)
        let events = try await eventsList(router: router, project: env.projectPath)
        #expect(
            events.contains {
                $0.kind == .crashed && $0.detail == DaemonRestartDetail.orphanBounced(pid: survivor)
            } == recordedJustNow)
    }

    /** A bounced survivor whose root exits on SIGTERM while a descendant
        ignores it (a disposition inherited through the shell that started it;
        the descendant left the root's group but kept its session): the bounce
        waits out that descendant's grace too and then SIGKILLs it, rather
        than stopping at the root's exit and leaving it running unsupervised. */
    @Test func aBounceKillsADescendantThatIgnoresSigtermAfterTheRootExits() async throws {
        let fixture = try #require(fixtureServerExecutable(), "fixture-server is not built; run swift build")
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "myproj": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        let output = try makeOutputPipe()
        defer { close(output.read) }
        let startedAt = Date()
        let root = try spawnReapedSessionLeader(
            [fixture, "--orphan-grandchild-ignterm"], stdoutFD: output.write)
        close(output.write)
        defer { if kill(root, 0) == 0 { kill(root, SIGKILL) } }
        let grandchild = try #require(await readPrintedPid("grandchild", from: output.read))
        defer { if kill(grandchild, 0) == 0 { kill(grandchild, SIGKILL) } }
        try await registry.updateState(serverID: serverID(project: env.projectPath, name: "dev"), writer: .router) {
            entry in
            entry.phase = .running
            entry.pid = Int(root)
            entry.startedAt = startedAt
        }
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()

        /** The bounce has already sent its SIGKILL by the time recover
            returns; only launchd's reap of the orphan is left to wait for. */
        let gone = try await awaitExit(grandchild, within: .seconds(5))
        #expect(gone, "descendant \(grandchild) ignoring SIGTERM survived the bounce of root \(root)")
        /** The root answers `kill(root, 0)` as a zombie until the spawn
            helper's reaper collects it, which can trail the bounce. */
        #expect(try await awaitExit(root, within: .seconds(5)))
    }

    /** A stopped row under a deleted name (no resume intent) is still pruned. */
    @Test func prunesStoppedOrphanWithoutResumeIntent() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let staleID = serverID(project: env.projectPath, name: "old")
        try await registry.updateState(serverID: staleID, writer: .router) { entry in
            entry.phase = .stopped
            entry.resumeOnBoot = nil
        }
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        #expect(await registry.persistedState(serverID: staleID) == nil)
    }

    /** Pre-feature state.json may lack resumeOnBoot. A phase left running still
        restores (daemon-crash case), using the config spec. */
    @Test func restoresLeftActivePhaseWithoutResumeFlag() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "api": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let id = serverID(project: env.projectPath, name: "api")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .running
            entry.resumeOnBoot = nil
            entry.pid = nil
        }
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        let api = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "api" }
        #expect(api?.phase == .starting || api?.phase == .running)
        #expect(api?.pid != nil)
        await stopServer(router: router, project: env.projectPath, name: "api")
    }

    @Test func whyDiagnosesConfigDefinedServer() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "exit 7"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        #expect(await registry.spec(project: env.projectPath, name: "web") == nil)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let startLine = try NDJSON.encodeLine(
            WireRequest(
                id: "start", method: WireMethod.serverStart.rawValue,
                params: ServerTargetParams(name: "web", project: env.projectPath)))
        _ = await router.handle(line: startLine)
        let crashed = try await eventually(within: .seconds(5), every: .milliseconds(100)) {
            try await statusList(router: router, project: env.projectPath)
                .first { $0.server == "web" }?.phase == .crashed
        }
        #expect(crashed)
        let whyLine = try NDJSON.encodeLine(
            WireRequest(
                id: "why", method: WireMethod.serverWhy.rawValue,
                params: ServerTargetParams(name: "web", project: env.projectPath)))
        let whyData = await router.handle(line: whyLine)
        let whyResponse = try JSONCoding.decoder().decode(
            WireResponse<WhyResult>.self, from: whyData)
        #expect(whyResponse.ok == true)
        #expect(whyResponse.result?.findings.isEmpty == false)
        #expect(whyResponse.result?.findings.first?.server == "web")
        #expect(whyResponse.result?.rootCause?.contains("crashed") == true)
    }

    /** The core adoption path: a persisted running server whose pid still
        matches a registered launchd child job is re-attached, not bounced. Pid
        stays the same, health promotes it to running, no "daemon-restart"
        orphan-bounce event lands (only the distinct adopt one does), and a
        spool line written before the adopt does not get duplicated into the
        structured log once the tailer re-attaches at end-of-file. Trust is
        neither required nor granted: adoption never touches `prepareSpawn`. */
    @Test func adoptsASurvivingChildInsteadOfBouncingIt() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        /** Captured right before the spawn, matching how `recordSpawn` stamps
            `startedAt`: it must sit at or within a few seconds of the real
            process's kernel start time, or the identity guard added alongside
            this test (`ProcessTree.startTimeConsistent`) correctly refuses the
            adopt as a would-be recycled-pid mismatch. */
        let startedAt = Date()
        let survivor = try spawnSurvivor()
        defer { kill(survivor, SIGKILL) }
        let id = serverID(project: env.projectPath, name: "web")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .running
            entry.pid = Int(survivor)
            entry.resumeOnBoot = true
            entry.startedAt = startedAt
        }
        try FileManager.default.createDirectory(
            at: env.paths.spoolOutFile(project: env.projectPath, server: "web")
                .deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("preexisting line\n".utf8).write(
            to: env.paths.spoolOutFile(project: env.projectPath, server: "web"))
        let gate = AdoptGate()
        let recorder = RecordingAgentJobs()
        let router = Router(
            agentJobs: recorder.agentJobs(listing: [
                LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.test-adopt", pid: survivor)
            ]),
            launcher: FakeAdoptLauncher(gate: gate), paths: env.paths, registry: registry)
        defer { gate.signal(.exitedStatusUnknown) }
        await router.recoverAtStartup()
        var web = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "web" }
        /** Pid is unchanged: adoption attaches, it never spawns. */
        #expect(web?.pid == Int(survivor))
        _ = try await eventually(within: .seconds(5), every: .milliseconds(100)) {
            web = try await statusList(router: router, project: env.projectPath)
                .first { $0.server == "web" }
            return web?.phase == .running
        }
        #expect(web?.phase == .running)
        #expect(web?.pid == Int(survivor))
        #expect(await gate.callCount == 1)
        #expect(await registry.isTrusted(project: env.projectPath) == false)
        /** The same job the adoption check matched is still alive under the
            supervisor it adopted; the leftover-job reap that runs at the end
            of `recoverAtStartup` must not boot it out. */
        #expect(recorder.labels.isEmpty)
        let events = try await eventsList(router: router, project: env.projectPath)
        #expect(events.contains { $0.kind == .crashed && ($0.detail ?? "").hasPrefix("daemon-restart") } == false)
        #expect(
            events.contains { $0.kind == .started && ($0.detail ?? "").contains("adopted pid") } == true)
        let handle = try FileHandle(forWritingTo: env.paths.spoolOutFile(project: env.projectPath, server: "web"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("post-adopt line\n".utf8))
        try handle.close()
        var texts: [String] = []
        _ = try await eventually(within: .seconds(5), every: .milliseconds(100)) {
            texts = try await logTexts(router: router, project: env.projectPath, name: "web")
            return texts.contains("post-adopt line")
        }
        #expect(texts.contains("post-adopt line"))
        #expect(!texts.contains("preexisting line"))

        /** The adopted run's exit writes its log, event, and state row; waiting
            for it keeps those writes inside the test's tree. */
        gate.signal(.signaled(signal: Int(SIGKILL)))
        let exited = try await eventually(within: .seconds(5)) {
            try await statusList(router: router, project: env.projectPath).first { $0.server == "web" }?.phase
                == .crashed
        }
        #expect(exited, "the adopted run never recorded its exit")
    }

    /** A `launchctl list` that does not answer (it timed out, twice) says
        nothing about which survivors are directa's child jobs, so recovery
        leaves a live survivor with restore intent alone rather than bouncing
        a server it could have adopted: no signal, no replacement spawn, the
        row intact for the next boot to decide, and no leftover-job reap from
        a listing it never got. */
    @Test func anUnreadableJobListDefersInsteadOfBouncingASurvivor() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let startedAt = Date()
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        let id = serverID(project: env.projectPath, name: "web")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .running
            entry.pid = Int(survivor)
            entry.resumeOnBoot = true
            entry.startedAt = startedAt
        }
        let recorder = RecordingAgentJobs()
        let gate = AdoptGate()
        let router = Router(
            agentJobs: recorder.agentJobs(answering: [.unavailable(reason: "launchctl list timed out")]),
            launcher: FakeAdoptLauncher(gate: gate), paths: env.paths, registry: registry)
        defer { gate.signal(.exitedStatusUnknown) }
        await router.recoverAtStartup()

        #expect(recorder.listingCount == 2)
        #expect(recorder.labels.isEmpty)
        #expect(await gate.callCount == 0)
        let signaled = try await eventually(within: .milliseconds(300)) { kill(survivor, 0) != 0 }
        #expect(!signaled, "survivor \(survivor) was signaled while launchd could not be read")
        let row = await registry.persistedState(serverID: id)
        #expect(row?.pid == Int(survivor))
        #expect(row?.phase == .running)
        #expect(row?.resumeOnBoot == true)
        let events = try await eventsList(router: router, project: env.projectPath)
        #expect(events.filter { $0.kind == .crashed || $0.kind == .started }.isEmpty)
    }

    /** While launchd's job list has not answered, a survivor restore could not
        decide about still reads as the run it is: status shows its recorded
        phase and pid, never `stopped` with no pid, and a read does not hand
        the survivor to any supervisor to watch or signal. */
    @Test func aDeferredSurvivorReportsItsRecordedPhaseAndPid() async throws {
        let env = try makeRecoverEnv()
        let registry = Registry(paths: env.paths)
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        try await seedWebSurvivor(env, registry: registry, serversJSON: sleepingWebJSON, survivor: survivor)
        let gate = AdoptGate()
        let launcher = SpawnCountingLauncher(gate: gate)
        let router = Router(
            agentJobs: RecordingAgentJobs().agentJobs(answering: [.unavailable(reason: "launchctl list timed out")]),
            launcher: launcher, paths: env.paths, registry: registry)
        defer { gate.signal(.exitedStatusUnknown) }
        await router.recoverAtStartup()

        for _ in 0..<3 {
            let web = try await statusList(router: router, project: env.projectPath)
                .first { $0.server == "web" }
            #expect(web?.phase == .running)
            #expect(web?.pid == Int(survivor))
            #expect(web?.uptimeSec != nil)
        }
        #expect(await gate.callCount == 0)
        #expect(launcher.runCount == 0)
        let signaled = try await eventually(within: .milliseconds(300)) { kill(survivor, 0) != 0 }
        #expect(!signaled, "survivor \(survivor) was signaled by a status read")
        let row = await registry.persistedState(serverID: serverID(project: env.projectPath, name: "web"))
        #expect(row?.pid == Int(survivor))
        #expect(row?.phase == .running)
    }

    /** Every request that would start, restart, or stop a deferred server is
        refused with `daemon-starting`, naming the server and its pid: starting
        spawns a second copy beside the survivor (or fails on the port it
        holds), and stopping would signal a process the daemon has not yet
        proven it may. Nothing reaches the launcher and the survivor lives. */
    @Test func aDeferredSurvivorRefusesStartAndStopWithDaemonStarting() async throws {
        let env = try makeRecoverEnv()
        let registry = Registry(paths: env.paths)
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        try await seedWebSurvivor(env, registry: registry, serversJSON: sleepingWebJSON, survivor: survivor)
        let gate = AdoptGate()
        let launcher = SpawnCountingLauncher(gate: gate)
        let router = Router(
            agentJobs: RecordingAgentJobs().agentJobs(answering: [.unavailable(reason: "launchctl list timed out")]),
            launcher: launcher, paths: env.paths, registry: registry)
        defer { gate.signal(.exitedStatusUnknown) }
        await router.recoverAtStartup()
        /** The status read that builds the server's supervisor, as the
            menu bar's poll does; the refusals must hold afterward too. */
        _ = try await statusList(router: router, project: env.projectPath)

        let ensure = try await ensureResponse(router: router, project: env.projectPath, name: "web")
        #expect(!ensure.ok)
        #expect(ensure.error?.code == .daemonStarting)
        #expect(ensure.error?.hint == "run: directa daemon status")
        #expect(ensure.error?.message.contains("'web'") == true)
        #expect(ensure.error?.message.contains("pid \(survivor)") == true)

        let stop = try await stopResponse(router: router, project: env.projectPath, name: "web")
        #expect(!stop.ok)
        #expect(stop.error?.code == .daemonStarting)
        #expect(stop.error?.message.contains("pid \(survivor)") == true)

        #expect(launcher.runCount == 0)
        #expect(await gate.callCount == 0)
        let signaled = try await eventually(within: .milliseconds(300)) { kill(survivor, 0) != 0 }
        #expect(!signaled, "survivor \(survivor) was signaled by a refused request")
        let row = await registry.persistedState(serverID: serverID(project: env.projectPath, name: "web"))
        #expect(row?.pid == Int(survivor))
    }

    /** A deferred survivor still holds its port: another server declaring the
        same port is refused with `port-held` naming the deferred server, even
        after a status read built the survivor's supervisor (which reads
        `stopped` and would otherwise hide the hold). */
    @Test func aDeferredSurvivorStillHoldsItsPortAgainstAnotherServer() async throws {
        let env = try makeRecoverEnv()
        let registry = Registry(paths: env.paths)
        let port = TestPorts.port(495)
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        try await seedWebSurvivor(
            env, registry: registry,
            serversJSON: """
                {
                  "other": {
                    "command": ["/bin/sh", "-c", "sleep 30"],
                    "port": \(port)
                  },
                  "web": {
                    "command": ["/bin/sh", "-c", "sleep 30"],
                    "port": \(port)
                  }
                }
                """,
            survivor: survivor)
        let gate = AdoptGate()
        let launcher = SpawnCountingLauncher(gate: gate)
        let router = Router(
            agentJobs: RecordingAgentJobs().agentJobs(answering: [.unavailable(reason: "launchctl list timed out")]),
            launcher: launcher, paths: env.paths, registry: registry)
        defer { gate.signal(.exitedStatusUnknown) }
        await router.recoverAtStartup()
        _ = try await statusList(router: router, project: env.projectPath)

        let ensure = try await ensureResponse(router: router, project: env.projectPath, name: "other")
        #expect(!ensure.ok)
        #expect(ensure.error?.code == .portHeld)
        #expect(
            ensure.error?.message
                == "port \(port) is held by managed server 'web' in \(canonicalProjectPath(env.projectPath))")
        #expect(launcher.runCount == 0)
    }

    /** Once launchd answers after restore, the survivor is decided the way
        restore would have: a listed child job is adopted with its pid
        unchanged (no spawn, no signal), re-read on a requeued timer through
        answers that do not come, and the refusals lift. */
    @Test func aDeferredSurvivorIsAdoptedWhenALaterJobListNamesIt() async throws {
        let env = try makeRecoverEnv()
        let registry = Registry(paths: env.paths)
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        try await seedWebSurvivor(env, registry: registry, serversJSON: sleepingWebJSON, survivor: survivor)
        let recorder = RecordingAgentJobs()
        let gate = AdoptGate()
        let launcher = SpawnCountingLauncher(gate: gate)
        let unavailable = LaunchdJobs.ChildJobListing.unavailable(reason: "launchctl list timed out")
        let router = Router(
            agentJobs: recorder.agentJobs(answering: [
                unavailable, unavailable, unavailable,
                .listed([LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.test-deferred", pid: survivor)]),
            ]),
            deferredSurvivorRetry: quickRetry,
            launcher: launcher, paths: env.paths, registry: registry)
        defer { gate.signal(.exitedStatusUnknown) }
        await router.recoverAtStartup()
        #expect(recorder.listingCount == 2)
        #expect(await gate.callCount == 0)

        await router.settleDeferredSurvivors()

        #expect(recorder.listingCount == 4)
        #expect(await gate.callCount == 1)
        #expect(launcher.runCount == 0)
        var web = try await statusList(router: router, project: env.projectPath).first { $0.server == "web" }
        #expect(web?.pid == Int(survivor))
        let running = try await eventually(within: .seconds(5), every: .milliseconds(50)) {
            web = try await statusList(router: router, project: env.projectPath).first { $0.server == "web" }
            return web?.phase == .running
        }
        #expect(running, "the adopted survivor never read running")
        #expect(web?.pid == Int(survivor))
        #expect(kill(survivor, 0) == 0)
        let events = try await eventsList(router: router, project: env.projectPath)
        #expect(events.contains { $0.kind == .started && ($0.detail ?? "").contains("adopted pid") })
        #expect(events.contains { $0.kind == .crashed } == false)

        /** Adopted and healthy: a start-shaped request is the ordinary
            no-op for a running server, not a refusal. */
        let ensure = try await ensureResponse(router: router, project: env.projectPath, name: "web")
        #expect(ensure.ok)
        #expect(ensure.result?.server.pid == Int(survivor))
        #expect(launcher.runCount == 0)

        gate.signal(.signaled(signal: Int(SIGKILL)))
        let exited = try await eventually(within: .seconds(5)) {
            try await statusList(router: router, project: env.projectPath).first { $0.server == "web" }?.phase
                == .crashed
        }
        #expect(exited, "the adopted run never recorded its exit")
    }

    /** A later job list that does not name the survivor says it is not a child
        job directa can take back, so it takes the orphan path restore has: the
        process is bounced and the server started fresh. */
    @Test func aDeferredSurvivorAbsentFromALaterJobListIsBouncedAndRestarted() async throws {
        let env = try makeRecoverEnv()
        let registry = Registry(paths: env.paths)
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        try await seedWebSurvivor(env, registry: registry, serversJSON: sleepingWebJSON, survivor: survivor)
        let unavailable = LaunchdJobs.ChildJobListing.unavailable(reason: "launchctl list timed out")
        let gate = AdoptGate()
        let launcher = SpawnCountingLauncher(gate: gate)
        let router = Router(
            agentJobs: RecordingAgentJobs().agentJobs(answering: [unavailable, unavailable, .listed([])]),
            deferredSurvivorRetry: quickRetry,
            launcher: launcher, paths: env.paths, registry: registry)
        defer { gate.signal(.exitedStatusUnknown) }
        await router.recoverAtStartup()
        #expect(launcher.runCount == 0)

        await router.settleDeferredSurvivors()

        #expect(await gate.callCount == 0)
        let gone = try await awaitExit(survivor, within: .seconds(5))
        #expect(gone, "survivor \(survivor) outside launchd's job list was left running")
        let web = try await statusList(router: router, project: env.projectPath).first { $0.server == "web" }
        #expect(web?.pid != nil)
        #expect(web?.pid != Int(survivor))
        #expect(web?.phase == .starting || web?.phase == .running)
        #expect(launcher.runCount == 1)
        let events = try await eventsList(router: router, project: env.projectPath)
        #expect(
            events.filter { $0.kind == .crashed }.map(\.detail)
                == [DaemonRestartDetail.orphanBounced(pid: survivor)])
        await stopServer(router: router, project: env.projectPath, name: "web")
    }

    /** The survivor is proven again when the list finally answers: one that
        died while deferred settles as gone (a `daemon-restart` crash, nothing
        signaled) and the server is started fresh. */
    @Test func aDeferredSurvivorThatDiedMeanwhileSettlesAsGone() async throws {
        let env = try makeRecoverEnv()
        let registry = Registry(paths: env.paths)
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        try await seedWebSurvivor(env, registry: registry, serversJSON: sleepingWebJSON, survivor: survivor)
        let gate = AdoptGate()
        let launcher = SpawnCountingLauncher(gate: gate)
        let router = Router(
            agentJobs: RecordingAgentJobs().agentJobs(answering: [
                .unavailable(reason: "launchctl list timed out"),
                .unavailable(reason: "launchctl list timed out"),
                .listed([LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.test-died", pid: survivor)]),
            ]),
            deferredSurvivorRetry: quickRetry,
            launcher: launcher, paths: env.paths, registry: registry)
        defer { gate.signal(.exitedStatusUnknown) }
        await router.recoverAtStartup()
        kill(survivor, SIGKILL)
        let died = try await awaitExit(survivor, within: .seconds(5))
        try #require(died)

        await router.settleDeferredSurvivors()

        #expect(await gate.callCount == 0)
        let web = try await statusList(router: router, project: env.projectPath).first { $0.server == "web" }
        #expect(web?.pid != nil)
        #expect(web?.pid != Int(survivor))
        let events = try await eventsList(router: router, project: env.projectPath)
        #expect(events.filter { $0.kind == .crashed }.map(\.detail) == [DaemonRestartDetail.crashed])
        await stopServer(router: router, project: env.projectPath, name: "web")
    }

    /** A job list that never answers inside the retry window leaves the
        survivor deferred for the next boot: still reported, still refused,
        row untouched, nothing signaled. */
    @Test func aJobListThatNeverAnswersLeavesTheSurvivorDeferred() async throws {
        let env = try makeRecoverEnv()
        let registry = Registry(paths: env.paths)
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        try await seedWebSurvivor(env, registry: registry, serversJSON: sleepingWebJSON, survivor: survivor)
        let recorder = RecordingAgentJobs()
        let gate = AdoptGate()
        let launcher = SpawnCountingLauncher(gate: gate)
        let router = Router(
            agentJobs: recorder.agentJobs(answering: [.unavailable(reason: "launchctl list timed out")]),
            deferredSurvivorRetry: DeferredSurvivorRetry(
                firstDelay: .milliseconds(10), longestDelay: .milliseconds(20), window: .milliseconds(150)),
            launcher: launcher, paths: env.paths, registry: registry)
        defer { gate.signal(.exitedStatusUnknown) }
        await router.recoverAtStartup()

        await router.settleDeferredSurvivors()

        #expect(recorder.listingCount > 3)
        let web = try await statusList(router: router, project: env.projectPath).first { $0.server == "web" }
        #expect(web?.phase == .running)
        #expect(web?.pid == Int(survivor))
        let ensure = try await ensureResponse(router: router, project: env.projectPath, name: "web")
        #expect(ensure.error?.code == .daemonStarting)
        #expect(launcher.runCount == 0)
        #expect(kill(survivor, 0) == 0)
        let row = await registry.persistedState(serverID: serverID(project: env.projectPath, name: "web"))
        #expect(row?.pid == Int(survivor))
    }

    /** A deferred survivor whose process exits while the job list stays silent
        is settled on the next retry tick without a job list: the run is gone,
        so the server is restarted at once and the refusals lift. */
    @Test func aDeferredSurvivorThatDiesWhileTheJobListIsSilentSettlesOnTheNextRetry() async throws {
        let env = try makeRecoverEnv()
        let registry = Registry(paths: env.paths)
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        try await seedWebSurvivor(env, registry: registry, serversJSON: sleepingWebJSON, survivor: survivor)
        let launcher = SpawnCountingLauncher(gate: AdoptGate())
        let router = Router(
            agentJobs: RecordingAgentJobs().agentJobs(answering: [.unavailable(reason: "launchctl list timed out")]),
            deferredSurvivorRetry: DeferredSurvivorRetry(
                firstDelay: .milliseconds(10), longestDelay: .milliseconds(20), window: .seconds(2)),
            launcher: launcher, paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        kill(survivor, SIGKILL)
        let died = try await awaitExit(survivor, within: .seconds(5))
        try #require(died)

        await router.settleDeferredSurvivors()

        let ensure = try await ensureResponse(router: router, project: env.projectPath, name: "web")
        #expect(ensure.ok, "a dead survivor stayed refused: \(String(describing: ensure.error))")
        #expect(ensure.result?.server.pid != Int(survivor))
        #expect(launcher.runCount == 1)
        let events = try await eventsList(router: router, project: env.projectPath)
        #expect(events.filter { $0.kind == .crashed }.map(\.detail) == [DaemonRestartDetail.crashed])
        await stopServer(router: router, project: env.projectPath, name: "web")
    }

    /** A request that hits the refusal for a survivor that has since died
        settles it on the spot and goes through, with no retry tick involved. */
    @Test func aRequestForADeferredSurvivorThatDiedMeanwhileSettlesItAndSucceeds() async throws {
        let env = try makeRecoverEnv()
        let registry = Registry(paths: env.paths)
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        try await seedWebSurvivor(env, registry: registry, serversJSON: sleepingWebJSON, survivor: survivor)
        let launcher = SpawnCountingLauncher(gate: AdoptGate())
        let router = Router(
            agentJobs: RecordingAgentJobs().agentJobs(answering: [.unavailable(reason: "launchctl list timed out")]),
            launcher: launcher, paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        kill(survivor, SIGKILL)
        let died = try await awaitExit(survivor, within: .seconds(5))
        try #require(died)

        let ensure = try await ensureResponse(router: router, project: env.projectPath, name: "web")

        #expect(ensure.ok, "a dead survivor stayed refused: \(String(describing: ensure.error))")
        #expect(launcher.runCount == 1)
        await stopServer(router: router, project: env.projectPath, name: "web")
    }

    /** Once the retry window gives up with the job list still silent, the
        refusal says so and names the way out: a daemon restart reads the list
        afresh. Until then it keeps pointing at `daemon status`. */
    @Test func aRefusalAfterTheRetryWindowNamesADaemonRestart() async throws {
        let env = try makeRecoverEnv()
        let registry = Registry(paths: env.paths)
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        try await seedWebSurvivor(env, registry: registry, serversJSON: sleepingWebJSON, survivor: survivor)
        let router = Router(
            agentJobs: RecordingAgentJobs().agentJobs(answering: [.unavailable(reason: "launchctl list timed out")]),
            deferredSurvivorRetry: DeferredSurvivorRetry(
                firstDelay: .milliseconds(10), longestDelay: .milliseconds(20), window: .milliseconds(150)),
            launcher: SpawnCountingLauncher(gate: AdoptGate()), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        let before = try await ensureResponse(router: router, project: env.projectPath, name: "web")
        #expect(before.error?.hint == "run: directa daemon status")

        await router.settleDeferredSurvivors()

        let after = try await ensureResponse(router: router, project: env.projectPath, name: "web")
        #expect(after.error?.code == .daemonStarting)
        #expect(after.error?.hint == "run: directa daemon restart")
        #expect(after.error?.message.contains("'web'") == true)
        #expect(after.error?.message.contains("pid \(survivor)") == true)
        #expect(after.error?.message.contains("job list never answered") == true)
    }

    /** `wait` on a deferred survivor is refused like the other requests: the
        server's supervisor is idle, so answering from it would report a
        stopped server beside a live process. */
    @Test func waitOnADeferredSurvivorIsRefused() async throws {
        let env = try makeRecoverEnv()
        let registry = Registry(paths: env.paths)
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        try await seedWebSurvivor(env, registry: registry, serversJSON: sleepingWebJSON, survivor: survivor)
        let router = Router(
            agentJobs: RecordingAgentJobs().agentJobs(answering: [.unavailable(reason: "launchctl list timed out")]),
            launcher: SpawnCountingLauncher(gate: AdoptGate()), paths: env.paths, registry: registry)
        await router.recoverAtStartup()

        let wait = try await router.response(
            .serverWait,
            WaitParams(condition: .stopped, name: "web", project: env.projectPath, timeoutSeconds: 5),
            EnsureResult.self)

        #expect(!wait.ok)
        #expect(wait.error?.code == .daemonStarting)
        #expect(wait.error?.message.contains("pid \(survivor)") == true)
    }

    /** A drain stops a deferred survivor too, through the identity-revalidated
        teardown: the process goes, the row reads `stopped` with its restore
        intent kept (a drain is not a deliberate stop), and nothing records a
        crash or an orphan bounce. */
    @Test func aDrainStopsADeferredSurvivorAndKeepsItsRestoreIntent() async throws {
        let env = try makeRecoverEnv()
        let registry = Registry(paths: env.paths)
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        try await seedWebSurvivor(env, registry: registry, serversJSON: sleepingWebJSON, survivor: survivor)
        let router = Router(
            agentJobs: RecordingAgentJobs().agentJobs(answering: [.unavailable(reason: "launchctl list timed out")]),
            launcher: SpawnCountingLauncher(gate: AdoptGate()), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        try #require(kill(survivor, 0) == 0)

        await router.drainAll()

        let gone = try await awaitExit(survivor, within: .seconds(5))
        #expect(gone, "the drain left deferred survivor \(survivor) running")
        let row = await registry.persistedState(serverID: serverID(project: env.projectPath, name: "web"))
        #expect(row?.phase == .stopped)
        #expect(row?.pid == nil)
        #expect(row?.resumeOnBoot == true)
        let events = try await eventsList(router: router, project: env.projectPath)
        #expect(events.filter { $0.kind == .crashed }.isEmpty)
    }

    /** A project forgotten while a settle is deciding its deferred survivor
        takes the entry with it: the settle's decision, finished afterward, is
        not acted on. The survivor ignores SIGTERM, so the settle's bounce is
        still waiting out its grace when the checkout vanishes and is
        forgotten; no supervisor may be left resident for the forgotten
        project afterward (the daemon would keep claiming it). */
    @Test func aSettleRacingAProjectForgetLeavesNoSupervisorForTheForgottenProject() async throws {
        let env = try makeRecoverEnv()
        let registry = Registry(paths: env.paths)
        let survivor = try spawnReapedSessionLeader(["/bin/sh", "-c", "trap '' TERM; sleep 30"])
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        try await seedWebSurvivor(env, registry: registry, serversJSON: sleepingWebJSON, survivor: survivor)
        let project = canonicalProjectPath(env.projectPath)
        let recorder = RecordingAgentJobs()
        let launcher = SpawnCountingLauncher(gate: AdoptGate())
        let router = Router(
            agentJobs: recorder.agentJobs(answering: [
                .unavailable(reason: "launchctl list timed out"),
                .unavailable(reason: "launchctl list timed out"),
                .listed([]),
            ]),
            deferredSurvivorRetry: quickRetry,
            launcher: launcher, paths: env.paths, registry: registry)
        await router.recoverAtStartup()

        async let settled: Void = router.settleDeferredSurvivors()
        let answered = try await eventually(within: .seconds(5)) { recorder.listingCount >= 3 }
        try #require(answered)
        try FileManager.default.removeItem(atPath: env.projectPath)
        let forget = try await router.response(
            .projectForget, ProjectOnlyParams(project: project), ProjectForgetResult.self)
        await settled

        #expect(forget.ok, "\(String(describing: forget.error))")
        let info = try await router.call(.daemonInfo, WireEmpty(), DaemonInfo.self)
        #expect(
            info.claimedProjects?.contains(project) != true,
            "the settle left a supervisor resident for a forgotten project")
        #expect(launcher.runCount == 0)
    }

    /** One unanswered `launchctl list` is retried, and a retry that answers
        is used exactly as a first answer would be: the survivor it lists is
        adopted, pid unchanged. */
    @Test func aJobListThatAnswersOnRetryStillAdopts() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let startedAt = Date()
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        let id = serverID(project: env.projectPath, name: "web")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .running
            entry.pid = Int(survivor)
            entry.resumeOnBoot = true
            entry.startedAt = startedAt
        }
        let recorder = RecordingAgentJobs()
        let gate = AdoptGate()
        let router = Router(
            agentJobs: recorder.agentJobs(answering: [
                .unavailable(reason: "launchctl list timed out"),
                .listed([LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.test-retry", pid: survivor)]),
            ]),
            launcher: FakeAdoptLauncher(gate: gate), paths: env.paths, registry: registry)
        defer { gate.signal(.exitedStatusUnknown) }
        await router.recoverAtStartup()

        #expect(recorder.listingCount == 2)
        #expect(await gate.callCount == 1)
        #expect(recorder.labels.isEmpty)
        let web = try await statusList(router: router, project: env.projectPath).first { $0.server == "web" }
        #expect(web?.pid == Int(survivor))

        gate.signal(.signaled(signal: Int(SIGKILL)))
        let exited = try await eventually(within: .seconds(5)) {
            try await statusList(router: router, project: env.projectPath).first { $0.server == "web" }?.phase
                == .crashed
        }
        #expect(exited, "the adopted run never recorded its exit")
    }

    /** A survivor whose ports no longer resolve (here the checkout's
        `directa.local.json` now declares a named port inside the span) is
        refused adoption the way `prepareSpawn` refuses the spawn: it is
        bounced, and the start that follows reports the config error instead
        of running, rather than being adopted with no port claim at all. */
    @Test func refusesToAdoptASurvivorWhosePortClaimNoLongerResolves() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "sleep 30"],
                "port": \(TestPorts.port(480)),
                "portSpan": 4
              }
            }
            """)
        try Data(#"{"servers":{"web":{"ports":{"cms":{"offset":1}}}}}"#.utf8)
            .write(to: LocalOverlay.overlayURL(project: env.projectPath))
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let startedAt = Date()
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        let id = serverID(project: env.projectPath, name: "web")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .running
            entry.pid = Int(survivor)
            entry.resumeOnBoot = true
            entry.startedAt = startedAt
        }
        let gate = AdoptGate()
        let router = Router(
            agentJobs: RecordingAgentJobs().agentJobs(listing: [
                LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.test-bad-claim", pid: survivor)
            ]),
            launcher: FakeAdoptLauncher(gate: gate), paths: env.paths, registry: registry)
        defer { gate.signal(.exitedStatusUnknown) }
        await router.recoverAtStartup()

        #expect(await gate.callCount == 0)
        let web = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "web" }
        #expect(web?.pid == nil)
        let events = try await eventsList(router: router, project: env.projectPath)
        #expect(
            events.filter { $0.kind == .crashed }.map(\.detail)
                == [DaemonRestartDetail.orphanBounced(pid: survivor)])
        let gone = try await awaitExit(survivor, within: .seconds(5))
        #expect(gone, "survivor \(survivor) with an unresolvable claim was left running")
    }

    /** A matching child job whose exit watch cannot be armed (the arm is
        refused, or the pid died after the job listing) is bounced and started
        fresh, exactly like a pid with no matching job: never left `.failed`
        with the survivor alive and unsupervised, which a later boot would
        then start a second copy beside. */
    @Test func bouncesAndRestartsAChildJobWhoseExitWatchCannotBeArmed() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let startedAt = Date()
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        let id = serverID(project: env.projectPath, name: "web")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .running
            entry.pid = Int(survivor)
            entry.resumeOnBoot = true
            entry.startedAt = startedAt
        }
        let launcher = UnwatchableAdoptLauncher()
        let router = Router(
            agentJobs: RecordingAgentJobs().agentJobs(listing: [
                LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.test-unwatchable", pid: survivor)
            ]),
            launcher: launcher, paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        #expect(launcher.prepareCallCount == 1)
        let web = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "web" }
        #expect(web?.pid != nil)
        #expect(web?.pid != Int(survivor))
        #expect(web?.phase == .starting || web?.phase == .running)
        let events = try await eventsList(router: router, project: env.projectPath)
        #expect(
            events.contains {
                $0.kind == .crashed
                    && $0.detail == DaemonRestartDetail.orphanBounced(pid: survivor)
            })
        #expect(
            events.contains { $0.kind == .started && ($0.detail ?? "").contains("adopted pid") } == false)
        let reaped = try await awaitExit(survivor, within: .seconds(5))
        #expect(reaped, "unwatchable survivor \(survivor) was left running beside its replacement")
        await stopServer(router: router, project: env.projectPath, name: "web")
    }

    /** A pid match alone is not proof of identity: `persisted.startedAt` set an
        hour in the past, well outside the tolerance, while the live process
        (with or without a matching child job) actually started moments ago (a
        recycled-pid stand-in, since forcing a real pid collision is not
        reproducible in a test). That process is someone else's: it is neither
        adopted nor signaled, and the server is restarted fresh as though its
        recorded run were simply gone. */
    @Test(arguments: [true, false])
    func neitherAdoptsNorSignalsAProcessWhoseStartTimeContradictsThePersistedRecord(
        listedAsChildJob: Bool
    ) async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let survivor = try spawnSurvivor()
        defer { kill(survivor, SIGKILL) }
        let id = serverID(project: env.projectPath, name: "web")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .running
            entry.pid = Int(survivor)
            entry.resumeOnBoot = true
            entry.startedAt = Date().addingTimeInterval(-3600)
        }
        let gate = AdoptGate()
        let recorder = RecordingAgentJobs()
        let listed =
            listedAsChildJob
            ? [LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.test-recycled", pid: survivor)]
            : []
        let router = Router(
            agentJobs: recorder.agentJobs(listing: listed),
            launcher: FakeAdoptLauncher(gate: gate), paths: env.paths, registry: registry)
        defer { gate.signal(.exitedStatusUnknown) }
        await router.recoverAtStartup()
        let web = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "web" }
        #expect(web?.pid != nil)
        #expect(web?.pid != Int(survivor))
        #expect(web?.phase == .starting || web?.phase == .running)
        #expect(await gate.callCount == 0)
        let events = try await eventsList(router: router, project: env.projectPath)
        #expect(
            events.filter { $0.kind == .crashed }.map(\.detail) == [DaemonRestartDetail.crashed])
        #expect(
            events.contains { $0.kind == .started && ($0.detail ?? "").contains("adopted pid") } == false)
        /** `bounceOrphan` runs to its SIGKILL inside `recoverAtStartup`, so a
            bounce would already have landed; the wait watches a full window
            for the reap a bounce would cause. */
        let signaled = try await awaitExit(survivor, within: .seconds(1))
        #expect(!signaled, "recycled-pid stand-in \(survivor) was signaled")
        await stopServer(router: router, project: env.projectPath, name: "web")
    }

    /** A row with no restore intent (a removal whose stop gave up retired it
        as stopped, keeping the run's pid and start time) is never restored or
        adopted, even when its pid is a matching child job. A live recorded
        run is bounced only with start-time proof, and the row keeps its
        stopped phase with the pid cleared. */
    @Test(arguments: [true, false])
    func aRetiredRowIsNeverRestoredOrAdoptedAndItsLiveRunIsBouncedOnlyWithProof(
        recordedJustNow: Bool
    ) async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let startedAt = recordedJustNow ? Date() : Date().addingTimeInterval(-3_600)
        let survivor = try spawnSurvivor()
        defer { if kill(survivor, 0) == 0 { kill(survivor, SIGKILL) } }
        let id = serverID(project: env.projectPath, name: "web")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .stopped
            entry.pid = Int(survivor)
            entry.resumeOnBoot = nil
            entry.startedAt = startedAt
        }
        let gate = AdoptGate()
        let router = Router(
            agentJobs: RecordingAgentJobs().agentJobs(listing: [
                LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.test-retired", pid: survivor)
            ]),
            launcher: FakeAdoptLauncher(gate: gate), paths: env.paths, registry: registry)
        defer { gate.signal(.exitedStatusUnknown) }
        await router.recoverAtStartup()

        #expect(await gate.callCount == 0)
        let web = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "web" }
        #expect(web?.pid == nil)
        #expect(web?.phase == .stopped)
        let row = try #require(await registry.persistedState(serverID: id))
        #expect(row.phase == .stopped)
        #expect(row.pid == nil)
        #expect(row.resumeOnBoot == nil)

        /** `bounceOrphan` runs to its SIGKILL inside `recoverAtStartup`, so
            only the reaping of a signaled process is left to wait for. */
        let gone = try await awaitExit(survivor, within: recordedJustNow ? .seconds(5) : .seconds(1))
        #expect(gone == recordedJustNow)
        let events = try await eventsList(router: router, project: env.projectPath)
        #expect(
            events.filter { $0.kind == .crashed }.map(\.detail)
                == (recordedJustNow ? [DaemonRestartDetail.orphanBounced(pid: survivor)] : []))
    }

    /** No launchd child job matches the persisted pid (the common case outside
        a jetsam restart, or when the surviving job was already reaped): the
        pre-existing bounce+respawn path still runs, with a fresh pid and the
        usual "daemon-restart" orphan event. */
    @Test func fallsBackToBounceAndRespawnWithNoMatchingChildJob() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let orphan = try spawnSurvivor()
        defer { if kill(orphan, 0) == 0 { kill(orphan, SIGKILL) } }
        let id = serverID(project: env.projectPath, name: "web")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .running
            entry.pid = Int(orphan)
            entry.resumeOnBoot = true
        }
        let recorder = RecordingAgentJobs()
        let router = Router(
            agentJobs: recorder.agentJobs(listing: []), launcher: SubprocessLauncher(),
            paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        let web = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "web" }
        #expect(web?.pid != Int(orphan))
        #expect(web?.phase == .starting || web?.phase == .running)
        let events = try await eventsList(router: router, project: env.projectPath)
        #expect(
            events.contains { $0.kind == .crashed && ($0.detail ?? "").hasPrefix("daemon-restart") })
        let reaped = try await awaitExit(orphan, within: .seconds(5))
        #expect(reaped, "orphan pid \(orphan) survived the bounce")
        await stopServer(router: router, project: env.projectPath, name: "web")
    }

    /** Outside agent mode (the daemon's own `ddirecta --foreground` and every
        unit suite) there is no `AgentJobs` value at all, so adoption has
        nothing to match against and never runs: bounce+respawn is the only
        path a non-agent daemon has. */
    @Test func neverAdoptsOutsideAgentMode() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let orphan = try spawnSurvivor()
        defer { if kill(orphan, 0) == 0 { kill(orphan, SIGKILL) } }
        let id = serverID(project: env.projectPath, name: "web")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .running
            entry.pid = Int(orphan)
            entry.resumeOnBoot = true
        }
        let router = Router(
            agentJobs: nil, launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        let web = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "web" }
        /** `agentJobs: nil` alone decided this: there was no way to also hand
            recovery a job matching `orphan`'s pid, because that seam and the
            agent-mode gate are the same value, `agentJobs` itself. */
        #expect(web?.pid != Int(orphan))
        #expect(web?.phase == .starting || web?.phase == .running)
        await stopServer(router: router, project: env.projectPath, name: "web")
    }

    /** The leftover-job reap must boot a stale child job (no supervised server
        holds its pid) out through the injected `AgentJobs` value, never by
        shelling directly to the real gui launchd domain. No project or
        supervised server is needed to observe this: the reap runs
        unconditionally in agent mode at the end of `recoverAtStartup`, over
        the one job listing the adoption checks read. */
    @Test func reapsAStaleChildJobThroughTheInjectedAgentJobsValue() async throws {
        let env = try makeRecoverEnv()
        let registry = Registry(paths: env.paths)
        let recorder = RecordingAgentJobs()
        let router = Router(
            agentJobs: recorder.agentJobs(listing: [
                LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.leftover", pid: 999_999)
            ]),
            launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        #expect(recorder.labels == ["dev.quantizor.directa.job.leftover"])
        #expect(recorder.listingCount == 1)
    }

    /** The shutdown-drain case: the daemon stopped `db` on its way down and a
        `directa lock` holder (which leaves declarers running by default) still
        owns `data` at the next boot. The server joins the holder's paused set
        rather than being refused, reads `stopped` (never `crashed`), keeps its
        boot intent, and starts when the holder releases. */
    @Test func aDrainedServerUnderALiveLockWaitsForTheReleaseThenStarts() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(project: env.projectPath, serversJSON: Self.lockedDatabase(locks: ["data"]))
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let id = serverID(project: env.projectPath, name: "db")
        try await seedRow(registry, id: id, phase: .stopped)
        try seedLiveHolds(env, resources: ["data"])
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()

        let waiting = try #require(
            try await statusList(router: router, project: env.projectPath).first { $0.server == "db" })
        #expect(waiting.phase == .stopped)
        #expect(waiting.pid == nil)
        let row = await registry.persistedState(serverID: id)
        #expect(row?.phase == .stopped)
        #expect(row?.resumeOnBoot == true)
        #expect(try await pausedNames(router, env, resource: "data") == ["db"])

        try await release(router, env, resource: "data")
        let started = try await eventually(within: .seconds(5)) {
            let phase = try await statusList(router: router, project: env.projectPath)
                .first { $0.server == "db" }?.phase
            return phase == .starting || phase == .running
        }
        #expect(started, "db never started after the holder released")
        await stopServer(router: router, project: env.projectPath, name: "db")
    }

    /** A row left `running` (the process died with the daemon) that has to
        wait on a live holder also reads `stopped` until the release: the
        waiting state is what the reader should see, not a crash the lock
        caused. */
    @Test func aLeftActiveServerUnderALiveLockReadsStoppedAndJoinsThePausedSet() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(project: env.projectPath, serversJSON: Self.lockedDatabase(locks: ["data"]))
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let id = serverID(project: env.projectPath, name: "db")
        try await seedRow(registry, id: id, phase: .running)
        try seedLiveHolds(env, resources: ["data"])
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()

        let waiting = try #require(
            try await statusList(router: router, project: env.projectPath).first { $0.server == "db" })
        #expect(waiting.phase == .stopped)
        #expect(await registry.persistedState(serverID: id)?.phase == .stopped)
        #expect(try await pausedNames(router, env, resource: "data") == ["db"])
        try await release(router, env, resource: "data")
        await stopServer(router: router, project: env.projectPath, name: "db")
    }

    /** A server declaring two held resources waits on each in turn: released
        from the first, it joins the second holder's paused set instead of
        failing with resource-locked, and starts only after the second release. */
    @Test func aServerDeclaringTwoHeldResourcesWaitsOnEachInTurn() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath, serversJSON: Self.lockedDatabase(locks: ["data", "cache"]))
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        try await seedRow(registry, id: serverID(project: env.projectPath, name: "db"), phase: .stopped)
        try seedLiveHolds(env, resources: ["data", "cache"])
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()

        #expect(try await pausedNames(router, env, resource: "data") == ["db"])
        #expect(try await pausedNames(router, env, resource: "cache") == [])

        try await release(router, env, resource: "data")
        #expect(try await pausedNames(router, env, resource: "cache") == ["db"])
        let between = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "db" }
        #expect(between?.phase == .stopped)
        #expect(between?.pid == nil)

        try await release(router, env, resource: "cache")
        let started = try await eventually(within: .seconds(5)) {
            let phase = try await statusList(router: router, project: env.projectPath)
                .first { $0.server == "db" }?.phase
            return phase == .starting || phase == .running
        }
        #expect(started, "db never started after both holders released")
        await stopServer(router: router, project: env.projectPath, name: "db")
    }

    /** A restore refused for a reason other than a lock (here: the project was
        never approved) leaves a drained server `stopped`, the state the daemon
        put it in on its way down, and marks a server whose run was left active
        `crashed`, since that process died with the daemon. */
    @Test(arguments: [(ServerPhase.stopped, ServerPhase.stopped), (.starting, .crashed), (.running, .crashed)])
    func aRefusedRestoreReadsStoppedForADrainedRowAndCrashedForALeftActiveOne(
        left: ServerPhase, reads: ServerPhase
    ) async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(project: env.projectPath, serversJSON: Self.lockedDatabase(locks: []))
        let registry = Registry(paths: env.paths)
        let id = serverID(project: env.projectPath, name: "db")
        try await seedRow(registry, id: id, phase: left)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()

        let server = try #require(
            try await statusList(router: router, project: env.projectPath).first { $0.server == "db" })
        #expect(server.phase == reads)
        #expect(server.pid == nil)
        #expect(await registry.persistedState(serverID: id)?.phase == reads)
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)
    }

    /** Boot restore is autonomous, so a server from a never-approved project's
        committed config is refused at the trust gate; it must not also be
        registered as waiting on the holder, which would list it as paused and
        promise a start that never comes. */
    @Test func anUnapprovedProjectsServerDoesNotJoinALiveHoldersPausedSet() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(project: env.projectPath, serversJSON: Self.lockedDatabase(locks: ["data"]))
        let registry = Registry(paths: env.paths)
        let id = serverID(project: env.projectPath, name: "db")
        try await seedRow(registry, id: id, phase: .stopped)
        try seedLiveHolds(env, resources: ["data"])
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()

        let server = try #require(
            try await statusList(router: router, project: env.projectPath).first { $0.server == "db" })
        #expect(server.phase == .stopped)
        #expect(await registry.persistedState(serverID: id)?.phase == .stopped)
        #expect(try await pausedNames(router, env, resource: "data") == [])
        #expect(await registry.isTrusted(project: env.projectPath) == false)
        try await release(router, env, resource: "data")
    }

    private static func lockedDatabase(locks: [String]) -> String {
        let declared = locks.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {
          "db": {
            "command": ["/bin/sh", "-c", "sleep 30"],
            "locks": [\(declared)]
          }
        }
        """
    }
}

/** A row as shutdown left it: boot intent kept, no process recorded. */
private func seedRow(_ registry: Registry, id: String, phase: ServerPhase) async throws {
    try await registry.updateState(serverID: id, writer: .router) { entry in
        entry.phase = phase
        entry.pid = nil
        entry.resumeOnBoot = true
    }
}

/** locks.json with this test process as the live holder of each resource, the
    way a `directa lock` run that outlived a daemon restart looks at boot. */
private func seedLiveHolds(_ env: RecoverEnv, resources: [String]) throws {
    var locks: [String: LockHolder] = [:]
    for resource in resources {
        locks["\(canonicalProjectPath(env.projectPath))::\(resource)"] = LockHolder(
            live: ["db"], pause: false, paused: [], pid: Int(getpid()), resumeTimeoutSeconds: 15,
            since: Date())
    }
    try AtomicFile.write(JSONCoding.encoder().encode(LocksFile(locks: locks)), to: env.paths.locksFile)
}

private func pausedNames(_ router: Router, _ env: RecoverEnv, resource: String) async throws -> [String] {
    let status = try await router.call(
        .lockStatus, LockStatusParams(project: env.projectPath, resource: resource), LockStatusResult.self)
    return try #require(status.holder).paused
}

private func release(_ router: Router, _ env: RecoverEnv, resource: String) async throws {
    _ = try await router.call(
        .lockRelease,
        LockParams(
            holderPid: Int(getpid()), project: env.projectPath, resource: resource, resumeTimeoutSeconds: 15),
        LockResult.self)
}
