import DirectaKit
import DirectaTestSupport
import Foundation
import Testing
import os

@testable import DirectaDaemonCore

/** Under the background agent a daemon restart or upgrade hands the servers to
    the next daemon: the old one exits without stopping anything, and the next
    adopts the still-running launchd child jobs the way it adopts a jetsam
    survivor. This suite holds the daemon-side half (`daemon.shutdown` with
    `handoff`), the SIGTERM that follows it, and the CLI-side order of a
    restart. */
@Suite(.serialized, .temporaryTree) struct DaemonHandoffTests {
    /** What a test's stand-in for the process exit saw, plus an optional side
        effect (the real exit is `DaemonTelemetry.exit`, which would end the
        test run). */
    private final class ExitRecorder: Sendable {
        private let onExit: @Sendable (String) -> Void
        private let seen = OSAllocatedUnfairLock(initialState: [String]())

        init(onExit: @escaping @Sendable (String) -> Void = { _ in }) {
            self.onExit = onExit
        }

        var reasons: [String] { seen.withLock { $0 } }

        func record(_ reason: String) {
            seen.withLock { $0.append(reason) }
            onExit(reason)
        }

        func firstReason() async throws -> String? {
            try await firstAnswer(within: .seconds(10)) { reasons.first }
        }
    }

    private func writeConfig(port: Int, project: String) throws {
        let fixture = try #require(fixtureServerExecutable())
        let body = """
            {
              "servers": {
                "web": {
                  "command": ["\(fixture)", "--listen-tcp", "\(port)"],
                  "healthcheck": { "type": "tcp", "port": \(port) },
                  "port": \(port)
                }
              },
              "version": 1
            }
            """
        try Data(body.utf8)
            .write(to: URL(fileURLWithPath: project).appending(path: "devservers.json"))
    }

    private func agentJobs(listing jobs: [LaunchdJobs.ChildJob] = []) -> AgentJobs {
        AgentJobs(bootOut: { _ in }, listChildJobs: { .listed(jobs) })
    }

    /** A router with `web` running, and the pid it runs as. */
    private func startedRouter(
        agentMode: Bool, env: RouterEnv, exits: ExitRecorder, offset: Int
    ) async throws -> (router: Router, pid: pid_t, registry: Registry) {
        try writeConfig(port: TestPorts.port(offset), project: env.project)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(
            agentJobs: agentMode ? agentJobs() : nil,
            exitProcess: { exits.record($0) },
            launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let started = try await router.call(
            .serverEnsure, EnsureParams(name: "web", project: env.project, timeoutSeconds: 10),
            EnsureResult.self)
        #expect(started.server.phase == .running)
        return (router, pid_t(try #require(started.server.pid)), registry)
    }

    /** Ends the server and waits for every router's supervisor to record it,
        so no write lands in the test's tree after the test returns. */
    private func finish(pid: pid_t, routers: [Router], project: String) async throws {
        kill(pid, SIGKILL)
        for router in routers {
            let settled = try await eventually(within: .seconds(10)) {
                let phase = try await router.call(
                    .serverStatus, ProjectParams(project: project), ServerListResult.self
                ).servers.first { $0.server == "web" }?.phase
                return phase == .crashed || phase == .stopped
            }
            #expect(settled)
        }
    }

    private func eventKinds(_ router: Router, _ project: String) async throws -> [EventRecord] {
        try await router.call(
            .eventsQuery, EventsQueryParams(project: project), EventsQueryResult.self
        ).events
    }

    private func stoppedIntentExists(_ env: RouterEnv) -> Bool {
        FileManager.default.fileExists(atPath: env.paths.stoppedIntentFile.path)
    }

    /** The agent-mode handoff: nothing stops, nothing is recorded as a stop, the
        restore intent and the stop marker are untouched, and the row the next
        daemon reads names the live pid. */
    @Test func aHandoffExitLeavesTheServerRunningAndItsRowAdoptable() async throws {
        let env = try makeRouterEnv(named: "handoff")
        let exits = ExitRecorder()
        let (router, pid, registry) = try await startedRouter(
            agentMode: true, env: env, exits: exits, offset: 501)
        defer { kill(pid, SIGKILL) }
        let id = serverID(project: env.project, name: "web")
        let before = try #require(await registry.persistedState(serverID: id))

        _ = try await router.call(.daemonShutdown, ShutdownParams(handoff: true), WireEmpty.self)

        #expect(try await exits.firstReason() == "daemon.shutdown handoff")
        #expect(kill(pid, 0) == 0)
        #expect(try await eventKinds(router, env.project).filter { $0.kind == .stopped }.isEmpty)
        #expect(!stoppedIntentExists(env))
        let after = try #require(await registry.persistedState(serverID: id))
        /** The row keeps the phase the spawn recorded; a promotion to
            `running` is not persisted, and recovery reads either as live. */
        #expect(after.phase == .starting || after.phase == .running)
        #expect(after.pid == Int(pid))
        #expect(after.resumeOnBoot == true)
        #expect(after.startedAt == before.startedAt)
        #expect(after.startedAt != nil)

        try await finish(pid: pid, routers: [router], project: env.project)
    }

    /** The whole handoff: the next daemon reads the rows the first one left,
        finds the job still listed, and attaches to the same pid without
        spawning or recording a crash. */
    @Test func theNextDaemonAdoptsWhatAHandoffLeftRunning() async throws {
        let env = try makeRouterEnv(named: "handoff-adopt")
        let exits = ExitRecorder()
        let (first, pid, _) = try await startedRouter(
            agentMode: true, env: env, exits: exits, offset: 502)
        defer { kill(pid, SIGKILL) }
        _ = try await first.call(.daemonShutdown, ShutdownParams(handoff: true), WireEmpty.self)
        _ = try await exits.firstReason()

        let gate = AdoptGate()
        defer { gate.signal(.exitedStatusUnknown) }
        let next = Router(
            agentJobs: agentJobs(listing: [
                LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.handoff", pid: pid)
            ]),
            launcher: FakeAdoptLauncher(gate: gate), paths: env.paths,
            registry: Registry(paths: env.paths))
        await next.recoverAtStartup()

        let adopted = try await eventually(within: .seconds(10)) {
            try await next.call(
                .serverStatus, ProjectParams(project: env.project), ServerListResult.self
            ).servers.first { $0.server == "web" }.map { $0.pid == Int(pid) && $0.phase == .running }
                ?? false
        }
        #expect(adopted)
        #expect(await gate.callCount == 1)
        let events = try await eventKinds(next, env.project)
        #expect(events.filter { $0.kind == .crashed }.isEmpty)
        #expect(events.contains { $0.kind == .started && ($0.detail ?? "").contains("adopted pid") })
        #expect(events.filter { $0.kind == .stopped }.isEmpty)
        #expect(kill(pid, 0) == 0)

        gate.signal(.signaled(signal: Int(SIGKILL)))
        try await finish(pid: pid, routers: [first, next], project: env.project)
    }

    /** Anything but an agent-mode handoff is a drain: a plain shutdown from
        `daemon stop`, uninstall, and a client that predates the field, a
        handoff that names false, and a handoff asked of a daemon that is not
        the agent (only launchd child jobs can be adopted). */
    @Test(arguments: [
        (agentMode: true, handoff: Bool?.none),
        (agentMode: true, handoff: false),
        (agentMode: false, handoff: true),
    ])
    func everyOtherShutdownDrainsAndWritesTheStopMarker(agentMode: Bool, handoff: Bool?) async throws {
        let env = try makeRouterEnv(named: "handoff-drain")
        let exits = ExitRecorder()
        let (router, pid, registry) = try await startedRouter(
            agentMode: agentMode, env: env, exits: exits, offset: 503)
        defer { kill(pid, SIGKILL) }

        _ = try await router.call(.daemonShutdown, ShutdownParams(handoff: handoff), WireEmpty.self)

        #expect(try await exits.firstReason() == "daemon.shutdown request")
        #expect(try await awaitExit(pid, within: .seconds(10)))
        let stopped = try await eventKinds(router, env.project).filter { $0.kind == .stopped }
        #expect(stopped.map(\.detail) == ["daemon shutting down"])
        #expect(stoppedIntentExists(env))
        let row = try #require(
            await registry.persistedState(serverID: serverID(project: env.project, name: "web")))
        #expect(row.phase == .stopped)
        #expect(row.resumeOnBoot == true)
    }

    /** A client that predates the field sends `{}`, which is a drain. */
    @Test func aShutdownWithEmptyParamsDrains() async throws {
        let env = try makeRouterEnv(named: "handoff-legacy")
        let exits = ExitRecorder()
        let (router, pid, _) = try await startedRouter(
            agentMode: true, env: env, exits: exits, offset: 504)
        defer { kill(pid, SIGKILL) }

        _ = try await router.call(.daemonShutdown, WireEmpty(), WireEmpty.self)

        #expect(try await exits.firstReason() == "daemon.shutdown request")
        #expect(try await awaitExit(pid, within: .seconds(10)))
        #expect(stoppedIntentExists(env))
    }

    /** The bounce that follows a handoff sends the old daemon SIGTERM
        (`kickstart -k`), whose handler drains. Once the handoff began the
        drain must not run, or the servers it handed on die anyway. */
    @Test func aSigtermAfterAHandoffDoesNotDrain() async throws {
        let env = try makeRouterEnv(named: "handoff-sigterm")
        let exits = ExitRecorder()
        let (router, pid, _) = try await startedRouter(
            agentMode: true, env: env, exits: exits, offset: 505)
        defer { kill(pid, SIGKILL) }
        _ = try await router.call(.daemonShutdown, ShutdownParams(handoff: true), WireEmpty.self)
        _ = try await exits.firstReason()

        await router.drainOnTermination()

        #expect(kill(pid, 0) == 0)
        #expect(try await eventKinds(router, env.project).filter { $0.kind == .stopped }.isEmpty)

        try await finish(pid: pid, routers: [router], project: env.project)
    }

    /** Without a handoff SIGTERM keeps draining (logout, machine shutdown). */
    @Test func aSigtermWithoutAHandoffStillDrains() async throws {
        let env = try makeRouterEnv(named: "handoff-sigterm-drain")
        let exits = ExitRecorder()
        let (router, pid, _) = try await startedRouter(
            agentMode: true, env: env, exits: exits, offset: 506)
        defer { kill(pid, SIGKILL) }

        await router.drainOnTermination()

        #expect(try await awaitExit(pid, within: .seconds(10)))
    }

    /** The order of a restart against a real socket: the old daemon is asked to
        hand off and has exited before launchd is asked to restart the job, its
        server is still running when launchd does, the stop marker is gone
        afterward, and the next daemon holds the same pid. */
    @Test func restartHandsOffBeforeItBouncesTheJob() async throws {
        let env = try makeRouterEnv(named: "handoff-restart")
        try FileManager.default.createDirectory(at: env.paths.dataDir, withIntermediateDirectories: true)
        let socketPath = env.paths.socketPath
        let journal = OSAllocatedUnfairLock(initialState: [String]())
        let exits = ExitRecorder(onExit: { reason in
            journal.withLock { $0.append("exit: \(reason)") }
            /** The socket going away is what the CLI reads as the daemon
                having exited. */
            unlink(socketPath)
        })
        let (first, pid, _) = try await startedRouter(
            agentMode: true, env: env, exits: exits, offset: 507)
        let firstServer = try ControlServer(router: first, socketPath: socketPath)
        try await firstServer.startAccepting()
        defer { withExtendedLifetime(firstServer) {} }

        let gate = AdoptGate()
        defer { gate.signal(.exitedStatusUnknown) }
        let nextDaemon = OSAllocatedUnfairLock<(router: Router, server: ControlServer)?>(initialState: nil)
        let launchctl: LaunchdAdmin.Launchctl = { arguments in
            journal.withLock {
                $0.append("launchctl \(arguments.first ?? "")")
                $0.append("server running: \(kill(pid, 0) == 0)")
            }
            let router = Router(
                agentJobs: AgentJobs(
                    bootOut: { _ in },
                    listChildJobs: {
                        .listed([LaunchdJobs.ChildJob(label: "dev.quantizor.directa.job.restart", pid: pid)])
                    }),
                launcher: FakeAdoptLauncher(gate: gate), paths: env.paths,
                registry: Registry(paths: env.paths))
            do {
                let server = try ControlServer(router: router, socketPath: socketPath)
                await router.setRestoring(true)
                try await server.startAccepting()
                await router.recoverAtStartup()
                await router.setRestoring(false)
                nextDaemon.withLock { $0 = (router, server) }
                return (status: 0, output: "")
            } catch {
                return (status: 1, output: "\(error)")
            }
        }

        let bounced = try await LaunchdAdmin.restart(paths: env.paths, launchctl: launchctl)

        #expect(bounced.map(\.name) == ["web"])
        #expect(
            journal.withLock { $0 }
                == ["exit: daemon.shutdown handoff", "launchctl kickstart", "server running: true"])
        #expect(!stoppedIntentExists(env))
        let next = try #require(nextDaemon.withLock { $0 }).router
        let adopted = try await eventually(within: .seconds(10)) {
            try await next.call(
                .serverStatus, ProjectParams(project: env.project), ServerListResult.self
            ).servers.first { $0.server == "web" }.map { $0.pid == Int(pid) && $0.phase == .running }
                ?? false
        }
        #expect(adopted)
        #expect(await gate.callCount == 1)
        #expect(try await eventKinds(next, env.project).filter { $0.kind == .stopped }.isEmpty)

        gate.signal(.signaled(signal: Int(SIGKILL)))
        try await finish(pid: pid, routers: [first, next], project: env.project)
    }
}
