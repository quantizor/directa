import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

/** Sibling git worktrees of one repo share committed ports; ensure on the
    linked tree must auto-rebind to a free port while keeping the declared
    host: every `*.localhost` name resolves to loopback, so the host never
    disambiguated a bind, and a third-level subdomain breaks apps whose auth
    config pins one origin. The worktree name surfaces as a display value. */
@Suite(.serialized) struct WorktreeCoexistenceTests {
    private struct Env {
        let fixture: String
        let main: String
        let paths: DirectaPaths
        let worktree: String
    }

    private func makeEnv() throws -> Env {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "directa-wt-\(UUID().uuidString)")
        let main = base.appending(path: "main")
        let worktree = base.appending(path: "worktrees/review")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try run(in: main.path, "/usr/bin/git", "init", "-b", "main")
        try run(in: main.path, "/usr/bin/git", "config", "user.email", "directa@test")
        try run(in: main.path, "/usr/bin/git", "config", "user.name", "directa")
        try Data("ok\n".utf8).write(to: main.appending(path: "README"))
        try run(in: main.path, "/usr/bin/git", "add", "README")
        try run(in: main.path, "/usr/bin/git", "commit", "-m", "init")
        try FileManager.default.createDirectory(
            at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run(
            in: main.path, "/usr/bin/git", "worktree", "add", "-b", "review", worktree.path)
        let fixture = try #require(Self.fixtureServerPath())
        let body = """
            {
              "host": "app.localhost",
              "servers": {
                "web": {
                  "command": ["\(fixture)", "--listen-tcp", "{port}"],
                  "healthcheck": { "type": "tcp", "port": 45111 },
                  "port": 45111,
                  "url": "http://app.localhost:45111/"
                }
              },
              "version": 1
            }
            """
        for root in [main, worktree] {
            try Data(body.utf8).write(to: root.appending(path: "devservers.json"))
        }
        return Env(
            fixture: fixture,
            main: main.path,
            paths: DirectaPaths(
                dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
            worktree: worktree.path)
    }

    private func handle<P: Codable & Sendable, R: Codable & Sendable>(
        _ router: Router, _ method: WireMethod, _ params: P, _ expecting: R.Type
    ) async throws -> R {
        let line = try NDJSON.encodeLine(WireRequest(id: "t", method: method.rawValue, params: params))
        let data = await router.handle(line: line)
        let response = try JSONCoding.decoder().decode(WireResponse<R>.self, from: data)
        if response.ok, let result = response.result { return result }
        throw response.error ?? WireError(code: .internalError, message: "no result")
    }

    @Test func siblingWorktreeEnsureRebindsAndKeepsTheDeclaredHost() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.main)
        try await registry.setTrusted(project: env.worktree)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let mainResult = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.main, timeoutSeconds: 10), EnsureResult.self)
        #expect(mainResult.server.phase == .running)
        #expect(mainResult.server.effectivePort == 45111)
        #expect(mainResult.server.url == "http://app.localhost:45111/")
        #expect(mainResult.server.portConflict == nil)
        #expect(mainResult.server.worktree == nil)

        let wtResult = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.worktree, timeoutSeconds: 10), EnsureResult.self)
        #expect(wtResult.server.phase == .running)
        #expect(wtResult.server.effectivePort != 45111)
        #expect(wtResult.server.portConflict?.state == .rebound)
        #expect(wtResult.server.worktree == "review")
        #expect(wtResult.server.mainProject == "main")
        let url = try #require(wtResult.server.url)
        /** The declared host is used unchanged; only the port moves. */
        #expect(url == "http://app.localhost:\(wtResult.server.effectivePort ?? -1)/")

        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: env.worktree),
            ServerResult.self)
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: env.main),
            ServerResult.self)
    }

    /** The label is computed at supervisor creation, not at spawn: a worktree
        project whose servers have never started in this daemon's lifetime (a
        stopped checkout after a daemon restart, a status-only query) still
        reports which checkout it is, and the session-context banner is
        therefore never silently missing. */
    @Test func statusNamesTheWorktreeBeforeAnythingStarts() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let listed = try await handle(
            router, .serverStatus, ProjectParams(project: env.worktree), ServerListResult.self)
        let web = try #require(listed.servers.first { $0.server == "web" })
        #expect(web.phase == .stopped)
        #expect(web.worktree == "review")
        #expect(web.mainProject == "main")
        #expect(web.url == "http://app.localhost:45111/")
    }

    /** The worktree checkout is answerable before anything starts, so a reader
        can tell which checkout a config describes. The host question is now
        boring on purpose: the declared host is the spawn host everywhere. */
    @Test func configCheckNamesTheWorktreeAndKeepsTheDeclaredHost() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let mainCheck = try await handle(
            router, .projectCheck, ProjectOnlyParams(project: env.main), CheckResult.self)
        #expect(mainCheck.errors.isEmpty)
        #expect(mainCheck.host == "app.localhost")
        #expect(mainCheck.effectiveHost == nil)
        #expect(mainCheck.effectiveHostReason == nil)
        #expect(mainCheck.worktree == nil)

        let wtCheck = try await handle(
            router, .projectCheck, ProjectOnlyParams(project: env.worktree), CheckResult.self)
        #expect(wtCheck.errors.isEmpty)
        #expect(wtCheck.host == "app.localhost")
        #expect(wtCheck.effectiveHost == nil)
        #expect(wtCheck.effectiveHostReason == nil)
        #expect(wtCheck.worktree == "review")

        /** The reported host must be the one a start actually uses, which is
            the whole point of answering before the start. */
        try await registry.setTrusted(project: env.worktree)
        let started = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.worktree, timeoutSeconds: 10), EnsureResult.self)
        let url = try #require(started.server.url)
        #expect(url.contains(try #require(wtCheck.host)))
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: env.worktree),
            ServerResult.self)
    }

    /** `up` prepares the spawn and then runs its waves. Re-resolving the
        supervisor inside a wave re-applied the committed spec to anything not
        yet running, discarding the rebound port and the substituted argv, so
        the child bound the committed port while status reported the rebind.
        Group and single-server starts must agree. */
    @Test func siblingWorktreeGroupUpKeepsTheMaterializedSpawnSpec() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.main)
        try await registry.setTrusted(project: env.worktree)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let mainResult = try await handle(
            router, .groupUp, GroupParams(project: env.main, timeoutSeconds: 10),
            GroupResult.self)
        #expect(mainResult.results.first?.server.phase == .running)
        #expect(mainResult.results.first?.server.effectivePort == 45111)

        let wtResult = try await handle(
            router, .groupUp, GroupParams(project: env.worktree, timeoutSeconds: 10),
            GroupResult.self)
        let web = try #require(wtResult.results.first?.server)
        #expect(web.phase == .running)
        let effective = try #require(web.effectivePort)
        #expect(effective != 45111)
        #expect(web.portConflict?.state == .rebound)
        #expect(web.worktree == "review")
        /** The url is the tell: it is built from the materialized spec, so the
            committed port here means the spawn spec was clobbered. */
        let url = try #require(web.url)
        #expect(url == "http://app.localhost:\(effective)/")
        /** The child was told `{port}`, so a clobbered spec listens on 45111. */
        #expect(web.observedPort == nil || web.observedPort == effective)

        _ = try await handle(
            router, .groupDown, GroupParams(project: env.worktree, timeoutSeconds: 10),
            GroupResult.self)
        _ = try await handle(
            router, .groupDown, GroupParams(project: env.main, timeoutSeconds: 10),
            GroupResult.self)
    }

    @Test func siblingWorktreePortSpanRebindsAsBlock() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "directa-span-\(UUID().uuidString)")
        let main = base.appending(path: "main")
        let worktree = base.appending(path: "worktrees/review")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try run(in: main.path, "/usr/bin/git", "init", "-b", "main")
        try run(in: main.path, "/usr/bin/git", "config", "user.email", "directa@test")
        try run(in: main.path, "/usr/bin/git", "config", "user.name", "directa")
        try Data("ok\n".utf8).write(to: main.appending(path: "README"))
        try run(in: main.path, "/usr/bin/git", "add", "README")
        try run(in: main.path, "/usr/bin/git", "commit", "-m", "init")
        try FileManager.default.createDirectory(
            at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run(
            in: main.path, "/usr/bin/git", "worktree", "add", "-b", "review", worktree.path)
        let fixture = try #require(Self.fixtureServerPath())
        let body = """
            {
              "host": "app.localhost",
              "servers": {
                "web": {
                  "command": ["\(fixture)", "--listen-tcp", "{port}"],
                  "healthcheck": { "type": "tcp", "port": 45200 },
                  "port": 45200,
                  "portEnv": "PUBLIC_PORT",
                  "portSpan": 3,
                  "url": "http://app.localhost:45200/"
                }
              },
              "version": 1
            }
            """
        for root in [main, worktree] {
            try Data(body.utf8).write(to: root.appending(path: "devservers.json"))
        }
        let paths = DirectaPaths(
            dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs"))
        let registry = Registry(paths: paths)
        try await registry.setTrusted(project: main.path)
        try await registry.setTrusted(project: worktree.path)
        let router = Router(launcher: SubprocessLauncher(), paths: paths, registry: registry)
        let mainResult = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: main.path, timeoutSeconds: 10), EnsureResult.self)
        #expect(mainResult.server.effectivePort == 45200)
        let wtResult = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: worktree.path, timeoutSeconds: 10), EnsureResult.self)
        let rebound = try #require(wtResult.server.effectivePort)
        #expect(rebound != 45200)
        /** Rebound base must clear the whole span away from main's 45200..45202. */
        #expect(Set(rebound..<(rebound + 3)).isDisjoint(with: Set(45200..<45203)))
        #expect(PortGuard.isListening(port: rebound))
        #expect(PortGuard.isListening(port: 45200))
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: worktree.path),
            ServerResult.self)
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: main.path),
            ServerResult.self)
    }

    /** Discarding a worktree path stops its children and forgets registry/state
        without touching the main checkout. */
    /** The timer sweep needs the path missing on two consecutive passes before
        it tears a project down (one flaky stat must never be irreversible), and
        on the second pass the children are stopped and the registration is
        forgotten exactly like the machine-wide prune. */
    @Test func missingProjectSweepPrunesAfterTwoConsecutiveMisses() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.worktree)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let started = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.worktree, timeoutSeconds: 10), EnsureResult.self)
        #expect(started.server.phase == .running)
        let pid = try #require(started.server.pid)
        let projectKey = started.server.project

        try FileManager.default.removeItem(atPath: env.worktree)

        /** First miss: held. Nothing is torn down on one flaky stat. */
        #expect(await router.sweepMissingProjects() == 0)
        #expect(await registry.project(projectKey) != nil)
        #expect(kill(pid_t(pid), 0) == 0)

        /** Second miss: torn down, children stopped, state forgotten. */
        #expect(await router.sweepMissingProjects() == 1)
        #expect(await registry.project(projectKey) == nil)
        #expect(kill(pid_t(pid), 0) != 0)
        #expect(!PortGuard.isListening(port: try #require(started.server.effectivePort)))
    }

    @Test func discardedWorktreeIsPrunedOnMachineWideStatus() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.main)
        try await registry.setTrusted(project: env.worktree)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let mainResult = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.main, timeoutSeconds: 10), EnsureResult.self)
        #expect(mainResult.server.phase == .running)
        let mainPid = try #require(mainResult.server.pid)
        let mainProject = mainResult.server.project

        let wtResult = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.worktree, timeoutSeconds: 10), EnsureResult.self)
        #expect(wtResult.server.phase == .running)
        let wtPid = try #require(wtResult.server.pid)
        let wtPort = try #require(wtResult.server.effectivePort)
        let wtProject = wtResult.server.project

        try FileManager.default.removeItem(atPath: env.worktree)
        #expect(!FileManager.default.fileExists(atPath: env.worktree))

        let after = try await handle(
            router, .serverStatus, ProjectParams(project: ""), ServerListResult.self)
        #expect(!after.servers.contains { $0.project == wtProject })
        #expect(after.servers.contains { $0.project == mainProject && $0.phase == .running })
        #expect(await registry.project(wtProject) == nil)
        #expect(await registry.persistedState(serverID: serverID(project: wtProject, name: "web")) == nil)
        #expect(kill(pid_t(wtPid), 0) != 0)
        #expect(kill(pid_t(mainPid), 0) == 0)
        #expect(!LoopbackProbe.isListening(port: wtPort))

        /** Second prune is a no-op: machine-wide status still lists main only. */
        let again = try await handle(
            router, .serverStatus, ProjectParams(project: ""), ServerListResult.self)
        #expect(again.servers.allSatisfy { $0.project == mainProject })
        #expect(await registry.project(mainProject) != nil)

        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: mainProject),
            ServerResult.self)
    }

    @Test func discardedWorktreeIsPrunedOnRecoverAtStartup() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.main)
        try await registry.setTrusted(project: env.worktree)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let wtResult = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.worktree, timeoutSeconds: 10), EnsureResult.self)
        #expect(wtResult.server.phase == .running)
        let wtPid = try #require(wtResult.server.pid)
        let wtProject = wtResult.server.project
        let mainProject = canonicalProjectPath(env.main)

        try FileManager.default.removeItem(atPath: env.worktree)
        await router.recoverAtStartup()
        #expect(await registry.project(wtProject) == nil)
        #expect(kill(pid_t(wtPid), 0) != 0)
        #expect(await registry.project(mainProject) != nil)
    }

    /** Nested Claude layout (`<main>/.claude/worktrees/<name>`). A prefix filter
        that used the checkout path without a `::` terminator would treat the
        worktree as the same project and `restart` would take both down. */
    @Test func nestedWorktreeRestartLeavesTheSiblingRunning() async throws {
        let env = try makeNestedEnv(port: 45310)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.main)
        try await registry.setTrusted(project: env.worktree)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let mainFirst = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.main, timeoutSeconds: 10), EnsureResult.self)
        #expect(mainFirst.server.phase == .running)
        let wtFirst = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.worktree, timeoutSeconds: 10), EnsureResult.self)
        #expect(wtFirst.server.phase == .running)
        let wtPid = try #require(wtFirst.server.pid)
        let mainPid = try #require(mainFirst.server.pid)
        #expect(wtPid != mainPid)

        let restartedMain = try await handle(
            router, .serverRestart,
            RestartParams(names: ["web"], project: env.main, timeoutSeconds: 10), GroupResult.self)
        #expect(restartedMain.results.count == 1)
        #expect(try #require(restartedMain.results.first?.server.pid) != mainPid)
        let wtAfterMain = try await handle(
            router, .serverStatus, ProjectParams(name: "web", project: env.worktree),
            ServerListResult.self)
        let wtStill = try #require(wtAfterMain.servers.first)
        #expect(wtStill.phase == .running)
        #expect(wtStill.pid == wtPid)

        let mainAfter = try await handle(
            router, .serverStatus, ProjectParams(name: "web", project: env.main),
            ServerListResult.self)
        let mainNowPid = try #require(mainAfter.servers.first?.pid)

        let restartedWt = try await handle(
            router, .serverRestart,
            RestartParams(names: ["web"], project: env.worktree, timeoutSeconds: 10),
            GroupResult.self)
        let wtNowPid = try #require(restartedWt.results.first?.server.pid)
        #expect(wtNowPid != wtPid)
        let mainAfterWt = try await handle(
            router, .serverStatus, ProjectParams(name: "web", project: env.main),
            ServerListResult.self)
        #expect(mainAfterWt.servers.first?.phase == .running)
        #expect(mainAfterWt.servers.first?.pid == mainNowPid)

        let restartedAll = try await handle(
            router, .serverRestart,
            RestartParams(names: nil, project: env.main, timeoutSeconds: 10), GroupResult.self)
        #expect(restartedAll.results.count == 1)
        let wtAfterAll = try await handle(
            router, .serverStatus, ProjectParams(name: "web", project: env.worktree),
            ServerListResult.self)
        #expect(wtAfterAll.servers.first?.phase == .running)
        #expect(wtAfterAll.servers.first?.pid == wtNowPid)

        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: env.worktree),
            ServerResult.self)
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: env.main),
            ServerResult.self)
    }

    private func makeNestedEnv(port: Int) throws -> Env {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "directa-wt-nested-\(UUID().uuidString)")
        let main = base.appending(path: "main")
        let worktree = main.appending(path: ".claude/worktrees/review")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try run(in: main.path, "/usr/bin/git", "init", "-b", "main")
        try run(in: main.path, "/usr/bin/git", "config", "user.email", "directa@test")
        try run(in: main.path, "/usr/bin/git", "config", "user.name", "directa")
        try Data("ok\n".utf8).write(to: main.appending(path: "README"))
        try run(in: main.path, "/usr/bin/git", "add", "README")
        try run(in: main.path, "/usr/bin/git", "commit", "-m", "init")
        try FileManager.default.createDirectory(
            at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run(
            in: main.path, "/usr/bin/git", "worktree", "add", "-b", "review", worktree.path)
        let fixture = try #require(Self.fixtureServerPath())
        let body = """
            {
              "host": "app.localhost",
              "servers": {
                "web": {
                  "command": ["\(fixture)", "--listen-tcp", "{port}"],
                  "healthcheck": { "type": "tcp", "port": \(port) },
                  "port": \(port),
                  "url": "http://app.localhost:\(port)/"
                }
              },
              "version": 1
            }
            """
        for root in [main, worktree] {
            try Data(body.utf8).write(to: root.appending(path: "devservers.json"))
        }
        return Env(
            fixture: fixture,
            main: main.path,
            paths: DirectaPaths(
                dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
            worktree: worktree.path)
    }

    private func run(in cwd: String, _ exe: String, _ args: String...) throws {
        let proc = Process()
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw WireError(
                code: .internalError,
                message: "\(exe) \(args.joined(separator: " ")) failed (\(proc.terminationStatus))")
        }
    }

    private static func fixtureServerPath() -> String? {
        fixtureServerExecutable()
    }
}
