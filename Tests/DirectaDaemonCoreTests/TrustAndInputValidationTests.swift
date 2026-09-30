import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaDaemonCore

/** The daemon's input-validation and trust boundary at the wire: a spec entering
    through `register` is validated the same as one from the file, `writeConfig`
    cannot drop a devservers.json at a path directa does not track, and an explicit
    start records the trust that boot restore later requires. */
@Suite(.serialized, .temporaryTree) struct TrustAndInputValidationTests {
    private func makeEnv() throws -> RouterEnv {
        try makeRouterEnv(named: "trust")
    }

    /** A non-finite or astronomically large timeout arriving over the wire is
        clamped before it reaches `Duration.seconds`, which traps on such a value.
        The clamp keeps a crafted `ensure`/`wait`/lock request from taking the
        daemon down (and respawning it under KeepAlive). */
    @Test func wireTimeoutIsClampedBeforeDurationConversion() {
        #expect(ServerSupervisor.boundedTimeoutSeconds(.infinity) == 86_400)
        #expect(ServerSupervisor.boundedTimeoutSeconds(-.infinity) == 86_400)
        #expect(ServerSupervisor.boundedTimeoutSeconds(.nan) == 86_400)
        #expect(ServerSupervisor.boundedTimeoutSeconds(1e30) == 86_400)
        #expect(ServerSupervisor.boundedTimeoutSeconds(-5) == 0)
        #expect(ServerSupervisor.boundedTimeoutSeconds(0) == 0)
        #expect(ServerSupervisor.boundedTimeoutSeconds(60) == 60)
    }

    @Test func registerRefusesAnInvalidSpec() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let outcome = try await router.attempt(
            .serverRegister,
            RegisterParams(
                project: env.project,
                spec: ServerSpec(command: [], name: "web", port: 70000)),
            ServerResult.self)
        guard case .failure(let error) = outcome else {
            Issue.record("register accepted an invalid spec")
            return
        }
        #expect(error.code == .configInvalid)
        #expect(await registry.spec(project: env.project, name: "web") == nil)
    }

    @Test func registerAcceptsAValidSpec() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let outcome = try await router.attempt(
            .serverRegister,
            RegisterParams(
                project: env.project,
                spec: ServerSpec(command: ["bun", "dev"], name: "web", port: 3000)),
            ServerResult.self)
        #expect((try? outcome.get()) != nil)
        #expect(await registry.spec(project: env.project, name: "web") != nil)
    }

    /** A conflicting or negative logs query is refused `usage` at the wire,
        before any server is resolved or any file read. */
    @Test func logsQueryRefusesConflictingParamsBeforeResolvingTheServer() async throws {
        let env = try makeEnv()
        let router = Router(
            launcher: SubprocessLauncher(), paths: env.paths, registry: Registry(paths: env.paths))
        for params in [
            LogsQueryParams(after: .origin, name: "ghost", project: env.project, since: Date()),
            LogsQueryParams(head: 1, name: "ghost", project: env.project, tail: 1),
            LogsQueryParams(name: "ghost", project: env.project, tail: -1),
        ] {
            let outcome = try await router.attempt(.logsQuery, params, LogsQueryResult.self)
            guard case .failure(let error) = outcome else {
                Issue.record("logs.query accepted \(params)")
                continue
            }
            #expect(error.code == .usage)
        }
    }

    /** A negative events tail is refused `usage` at the wire, the way a logs
        query's is, scoped or machine-wide, rather than reaching the store,
        where trimming by a negative count traps and takes the daemon down. A
        tail of zero is a real request for no events. */
    @Test func eventsQueryRefusesANegativeTail() async throws {
        let env = try makeEnv()
        let router = Router(
            launcher: SubprocessLauncher(), paths: env.paths, registry: Registry(paths: env.paths))
        for project in [env.project, nil] {
            let outcome = try await router.attempt(
                .eventsQuery, EventsQueryParams(project: project, tail: -1), EventsQueryResult.self)
            guard case .failure(let error) = outcome else {
                Issue.record("events.query accepted tail -1 for project \(project ?? "(all)")")
                continue
            }
            #expect(error.code == .usage)
            #expect(error.hint == "send tail as 0 or more")
        }
        let zero = try await router.attempt(
            .eventsQuery, EventsQueryParams(project: env.project, tail: 0), EventsQueryResult.self)
        #expect((try? zero.get())?.events == [])
    }

    /** The router hands every new field to the engine and every new answer
        back: the cursor, per-stream totals, and truncated text. */
    @Test func logsQueryPassesTheCursorTrimAndTruncationThrough() async throws {
        let env = try makeEnv()
        let router = Router(
            launcher: SubprocessLauncher(), paths: env.paths, registry: Registry(paths: env.paths))
        _ = try await router.attempt(
            .serverRegister,
            RegisterParams(project: env.project, spec: ServerSpec(command: ["bun", "dev"], name: "web")),
            ServerResult.self
        ).get()
        let log = env.paths.structuredLogFile(project: canonicalProjectPath(env.project), server: "web")
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let at = Date(timeIntervalSince1970: 1_752_868_000)
        let records = [
            LogRecord(at: at, stream: .sys, text: "started pid=7"),
            LogRecord(at: at, stream: .out, text: "listening on 3000"),
            LogRecord(at: at, stream: .out, text: "GET /"),
        ]
        try Data(records.map { $0.formatted() + "\n" }.joined().utf8).write(to: log)
        let result = try await router.attempt(
            .logsQuery,
            LogsQueryParams(
                after: LogCursor(at: at, count: 1), maxLineCharacters: 5, name: "web", project: env.project,
                tailByStream: LogStreamCounts(out: 1)),
            LogsQueryResult.self
        ).get()
        #expect(
            result
                == LogsQueryResult(
                    cursor: LogCursor(at: at, count: 3), lines: [LogRecord(at: at, stream: .out, text: "GET /")],
                    totals: LogStreamTotals(err: 0, mark: 0, out: 2, sys: 0)))
        let truncated = try await router.attempt(
            .logsQuery,
            LogsQueryParams(head: 1, maxLineCharacters: 5, name: "web", project: env.project, streams: [.out]),
            LogsQueryResult.self
        ).get()
        #expect(truncated.lines.map(\.text) == ["list…"])
    }

    @Test func writeConfigRefusesAnUntrackedProjectPath() async throws {
        let env = try makeEnv()
        let stranger = try TemporaryTree.directory(named: "stranger")
        let registry = Registry(paths: env.paths)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let body = """
            {"servers":{"web":{"command":["bun","dev"]}},"version":1}
            """
        let outcome = try await router.attempt(
            .projectWriteConfig,
            WriteConfigParams(baselineHash: "", content: body, project: stranger.path),
            CheckResult.self)
        guard case .failure(let error) = outcome else {
            Issue.record("writeConfig created a config for an untracked path")
            return
        }
        #expect(error.code == .notFound)
        #expect(
            !FileManager.default.fileExists(
                atPath: stranger.appending(path: "devservers.json").path))
    }

    @Test func writeConfigCreatesForAKnownProject() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        /** A registered server makes the project known, so the editor's
            create-on-first-save flow is allowed. */
        try await registry.register(
            project: env.project, spec: ServerSpec(command: ["bun", "dev"], name: "web"))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let body = """
            {"servers":{"web":{"command":["bun","dev"]}},"version":1}
            """
        let outcome = try await router.attempt(
            .projectWriteConfig,
            WriteConfigParams(baselineHash: "", content: body, project: env.project),
            CheckResult.self)
        #expect((try? outcome.get()) != nil)
        #expect(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: env.project).appending(path: "devservers.json").path))
    }

    /** No command resolves a stale-baseline save, so the refusal carries no hint
        and the remedy reads in the message. */
    @Test func writeConfigRefusesAStaleBaselineWithTheRemedyInTheMessage() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(
            project: env.project, spec: ServerSpec(command: ["bun", "dev"], name: "web"))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let body = """
            {"servers":{"web":{"command":["bun","dev"]}},"version":1}
            """
        try Data(body.utf8).write(
            to: URL(fileURLWithPath: env.project).appending(path: "devservers.json"))
        let outcome = try await router.attempt(
            .projectWriteConfig,
            WriteConfigParams(baselineHash: "not-the-current-hash", content: body, project: env.project),
            CheckResult.self)
        guard case .failure(let error) = outcome else {
            Issue.record("writeConfig overwrote a file that changed since it was loaded")
            return
        }
        #expect(error.code == .configInvalid)
        #expect(error.hint == nil)
        #expect(
            error.message
                == "devservers.json changed on disk since it was loaded (an editor or another session saved it); reload it and re-apply your edit"
        )
    }

    @Test func anExplicitStartRecordsTrust() async throws {
        let env = try makeEnv()
        let body = """
            {"servers":{"web":{"command":["/bin/sh","-c","sleep 30"]}},"version":1}
            """
        try Data(body.utf8).write(
            to: URL(fileURLWithPath: env.project).appending(path: "devservers.json"))
        let registry = Registry(paths: env.paths)
        #expect(await registry.isTrusted(project: env.project) == false)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let outcome = try await router.attempt(
            .serverStart,
            ServerTargetParams(name: "web", project: env.project),
            ServerResult.self)
        #expect((try? outcome.get()) != nil)
        /** The explicit start IS the approval: trust is now recorded, which is
            what lets boot restore bring this server back next time. */
        #expect(await registry.isTrusted(project: env.project) == true)
        _ = try await router.call(
            .serverStop, ServerTargetParams(name: "web", project: env.project), ServerResult.self)
    }
}
