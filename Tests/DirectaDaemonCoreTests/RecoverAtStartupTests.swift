import DirectaKit
import Foundation
import Testing
import os

@testable import DirectaDaemonCore

private struct RecoverEnv {
    let paths: DirectaPaths
    let projectPath: String
}

private func makeRecoverEnv() throws -> RecoverEnv {
    let base = FileManager.default.temporaryDirectory.appending(path: "directa-recover-\(UUID().uuidString)")
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

    var labels: [String] { bootedOutLabels.withLock { $0 } }

    func agentJobs(listing jobs: [LaunchdJobs.ChildJob]) -> AgentJobs {
        AgentJobs(
            bootOut: { [bootedOutLabels] job in bootedOutLabels.withLock { $0.append(job.label) } },
            listChildJobs: { jobs })
    }
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


@Suite struct RecoverAtStartupTests {
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
        try await registry.updateState(serverID: id) { entry in
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
        try await registry.updateState(serverID: id) { entry in
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
        try await registry.updateState(serverID: staleID) { entry in
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
        try await registry.updateState(serverID: staleID) { entry in
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
        try await registry.updateState(serverID: id) { entry in
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
        var phase: ServerPhase = .starting
        for _ in 0..<50 {
            let web = try await statusList(router: router, project: env.projectPath)
                .first { $0.server == "web" }
            phase = web?.phase ?? .starting
            if phase == .crashed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(phase == .crashed)
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
        try await registry.updateState(serverID: id) { entry in
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
        await router.recoverAtStartup()
        var web = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "web" }
        /** Pid is unchanged: adoption attaches, it never spawns. */
        #expect(web?.pid == Int(survivor))
        for _ in 0..<50 where web?.phase != .running {
            try await Task.sleep(for: .milliseconds(100))
            web = try await statusList(router: router, project: env.projectPath)
                .first { $0.server == "web" }
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
        for _ in 0..<50 where !texts.contains("post-adopt line") {
            try await Task.sleep(for: .milliseconds(100))
            texts = try await logTexts(router: router, project: env.projectPath, name: "web")
        }
        #expect(texts.contains("post-adopt line"))
        #expect(!texts.contains("preexisting line"))
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
        try await registry.updateState(serverID: id) { entry in
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
        var reaped = false
        for _ in 0..<50 where !reaped {
            if kill(survivor, 0) != 0 { reaped = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(reaped, "unwatchable survivor \(survivor) was left running beside its replacement")
        await stopServer(router: router, project: env.projectPath, name: "web")
    }

    /** A pid match alone is not proof of identity: `persisted.startedAt` set an
        hour in the past, well outside the tolerance, while the live process
        backing the matching child job actually started moments ago (a
        recycled-pid stand-in, since forcing a real pid collision is not
        reproducible in a test). The guard must reject the match and fall
        through to the ordinary bounce+respawn, not cross-wire this server's
        supervision onto a process it never spawned. */
    @Test func doesNotAdoptWhenTheProcessStartTimeContradictsThePersistedRecord() async throws {
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
        try await registry.updateState(serverID: id) { entry in
            entry.phase = .running
            entry.pid = Int(survivor)
            entry.resumeOnBoot = true
            entry.startedAt = Date().addingTimeInterval(-3600)
        }
        let gate = AdoptGate()
        let recorder = RecordingAgentJobs()
        let router = Router(
            agentJobs: recorder.agentJobs(listing: [
                LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.test-recycled", pid: survivor)
            ]),
            launcher: FakeAdoptLauncher(gate: gate), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        let web = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "web" }
        #expect(web?.pid != Int(survivor))
        #expect(web?.phase == .starting || web?.phase == .running)
        #expect(await gate.callCount == 0)
        let events = try await eventsList(router: router, project: env.projectPath)
        #expect(
            events.contains { $0.kind == .crashed && ($0.detail ?? "").hasPrefix("daemon-restart") })
        #expect(
            events.contains { $0.kind == .started && ($0.detail ?? "").contains("adopted pid") } == false)
        var reaped = false
        for _ in 0..<50 where !reaped {
            if kill(survivor, 0) != 0 { reaped = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(reaped, "recycled-pid stand-in \(survivor) survived the bounce")
        await stopServer(router: router, project: env.projectPath, name: "web")
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
        try await registry.updateState(serverID: id) { entry in
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
        var reaped = false
        for _ in 0..<50 where !reaped {
            if kill(orphan, 0) != 0 { reaped = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
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
        try await registry.updateState(serverID: id) { entry in
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
        unconditionally in agent mode at the end of `recoverAtStartup`. */
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
    }
}
