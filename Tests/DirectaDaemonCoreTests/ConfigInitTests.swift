import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaDaemonCore

/** devservers.json is routinely gitignored per machine, so losing it left no way
    back. These cover writing one from what the daemon already knows, and above
    all that a file recovered from this checkout is portable to another. */
@Suite(.serialized, .temporaryTree) struct ConfigInitTests {
    private struct Env {
        let paths: DirectaPaths
        let project: String
    }

    private func makeEnv() throws -> Env {
        let base = try TemporaryTree.directory(named: "init")
        let project = base.appending(path: "shop")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return Env(
            paths: DirectaPaths(
                dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
            project: project.path)
    }

    private func handle<P: Codable & Sendable, R: Codable & Sendable>(
        _ router: Router, _ method: WireMethod, _ params: P, _ expecting: R.Type
    ) async throws -> R {
        let line = try NDJSON.encodeLine(
            WireRequest(id: "t", method: method.rawValue, params: params))
        let data = await router.handle(line: line)
        let response = try JSONCoding.decoder().decode(WireResponse<R>.self, from: data)
        if response.ok, let result = response.result { return result }
        throw response.error ?? WireError(code: .internalError, message: "no result")
    }

    private func router(_ env: Env) -> Router {
        Router(launcher: SubprocessLauncher(), paths: env.paths, registry: Registry(paths: env.paths))
    }

    @Test func initWritesAFileTheValidatorAccepts() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(
            project: env.project,
            spec: ServerSpec(command: ["bun", "dev"], name: "web", port: 3000))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let result = try await handle(
            router, .projectInitConfig,
            InitConfigParams(mode: .create, project: env.project), InitConfigResult.self)
        #expect(result.written)
        #expect(result.check.errors.isEmpty)
        #expect(result.check.servers == ["web"])
        #expect(FileManager.default.fileExists(atPath: result.path))

        let check = try await handle(
            router, .projectCheck, ProjectOnlyParams(project: env.project), CheckResult.self)
        #expect(check.errors.isEmpty)
        #expect(check.servers == ["web"])
    }

    /** The file is human-edited, so it is written indented rather than as the
        single line the wire encoder produces. */
    @Test func theWrittenFileIsIndentedAndEndsWithANewline() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(
            project: env.project, spec: ServerSpec(command: ["bun", "dev"], name: "web", port: 3000))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let result = try await handle(
            router, .projectInitConfig,
            InitConfigParams(mode: .create, project: env.project), InitConfigResult.self)
        #expect(result.content.contains("\n  "))
        #expect(result.content.hasSuffix("\n"))
    }

    @Test func initRefusesToClobberWithoutForce() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(
            project: env.project, spec: ServerSpec(command: ["bun", "dev"], name: "web", port: 3000))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = try await handle(
            router, .projectInitConfig,
            InitConfigParams(mode: .create, project: env.project), InitConfigResult.self)

        await #expect(throws: WireError.self) {
            _ = try await handle(
                router, .projectInitConfig,
                InitConfigParams(mode: .create, project: env.project), InitConfigResult.self)
        }
        do {
            _ = try await handle(
                router, .projectInitConfig,
                InitConfigParams(mode: .create, project: env.project), InitConfigResult.self)
        } catch let error as WireError {
            #expect(error.code == .alreadyExists)
            #expect(error.hint == "run: directa config init --force")
        }

        let forced = try await handle(
            router, .projectInitConfig,
            InitConfigParams(force: true, mode: .replace, project: env.project),
            InitConfigResult.self)
        #expect(forced.written)
    }

    @Test func dryRunWritesNothing() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(
            project: env.project, spec: ServerSpec(command: ["bun", "dev"], name: "web", port: 3000))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let result = try await handle(
            router, .projectInitConfig,
            InitConfigParams(dryRun: true, mode: .create, project: env.project),
            InitConfigResult.self)
        #expect(result.written == false)
        #expect(result.content.contains("\"web\""))
        #expect(FileManager.default.fileExists(atPath: result.path) == false)
    }

    @Test func mergeAddsOneServerAndKeepsTheRest() async throws {
        let env = try makeEnv()
        let router = router(env)
        let existing = """
            {
              "servers": {
                "api": { "command": ["bun", "api"], "port": 8787 }
              },
              "version": 1
            }
            """
        try Data(existing.utf8).write(
            to: URL(fileURLWithPath: env.project).appending(path: "devservers.json"))

        let merged = try await handle(
            router, .projectInitConfig,
            InitConfigParams(
                fromDaemon: false, mode: .merge, project: env.project,
                servers: [ServerSpec(command: ["bun", "dev"], name: "web", port: 3000)]),
            InitConfigResult.self)
        #expect(merged.written)
        #expect(merged.check.servers == ["api", "web"])
        #expect(merged.content.contains("\"bun\""))

        await #expect(throws: WireError.self) {
            _ = try await handle(
                router, .projectInitConfig,
                InitConfigParams(
                    fromDaemon: false, mode: .merge, project: env.project,
                    servers: [ServerSpec(command: ["other"], name: "web")]),
                InitConfigResult.self)
        }
    }

    /** Naming a key the reader never wrote sends them looking for something that
        was never there, so `lifecycle` is reported only when the replaced file
        actually had one. */
    @Test func notRecoveredNamesLifecycleOnlyWhenTheReplacedFileHadOne() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(
            project: env.project, spec: ServerSpec(command: ["bun", "dev"], name: "web", port: 3000))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let url = URL(fileURLWithPath: env.project).appending(path: "devservers.json")

        try Data(#"{"servers":{"web":{"command":["bun","dev"],"port":3000}},"version":1}"#.utf8)
            .write(to: url)
        let plain = try await handle(
            router, .projectInitConfig,
            InitConfigParams(force: true, mode: .replace, project: env.project),
            InitConfigResult.self)
        #expect(plain.notRecovered == nil)

        try Data(
            #"{"lifecycle":{"switch":[["echo","hi"]]},"servers":{"web":{"command":["bun","dev"],"port":3000}},"version":1}"#
                .utf8
        ).write(to: url)
        let withLifecycle = try await handle(
            router, .projectInitConfig,
            InitConfigParams(force: true, mode: .replace, project: env.project),
            InitConfigResult.self)
        #expect(withLifecycle.notRecovered == ["lifecycle"])
    }

    @Test func initWithNoKnownServersIsNotFound() async throws {
        let env = try makeEnv()
        do {
            _ = try await handle(
                router(env), .projectInitConfig,
                InitConfigParams(mode: .create, project: env.project), InitConfigResult.self)
            Issue.record("expected not-found")
        } catch let error as WireError {
            #expect(error.code == .notFound)
        }
    }

    /** The money test: a file recovered inside a linked worktree must carry
        neither the ephemeral host nor the rebound port, or it is wrong the moment
        someone else uses it. */
    @Test func recoveredFileFromAWorktreeCarriesNeitherEphemeralHostNorReboundPort() async throws {
        let base = try TemporaryTree.directory(named: "initwt")
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
        try run(in: main.path, "/usr/bin/git", "worktree", "add", "-b", "review", worktree.path)
        let fixture = try #require(Self.fixtureServerPath())
        let body = """
            {
              "host": "app.localhost",
              "servers": {
                "web": {
                  "command": ["\(fixture)", "--listen-tcp", "{port}"],
                  "healthcheck": { "type": "tcp", "port": 45311 },
                  "port": 45311
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

        _ = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: main.path, timeoutSeconds: 10), EnsureResult.self)
        let wt = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: worktree.path, timeoutSeconds: 10),
            EnsureResult.self)
        #expect(wt.server.portConflict?.state == .rebound)
        #expect(wt.server.effectivePort != 45311)

        let written = try await handle(
            router, .projectInitConfig,
            InitConfigParams(force: true, mode: .replace, project: worktree.path),
            InitConfigResult.self)
        #expect(written.content.contains("worktree-") == false)
        #expect(written.content.contains("45311"))
        #expect(written.content.contains("\(wt.server.effectivePort ?? -1)") == false)
        /** And the substituted argv must not have replaced the token. */
        #expect(written.content.contains("{port}"))

        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: worktree.path),
            ServerResult.self)
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: main.path),
            ServerResult.self)
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

    private static func fixtureServerPath() -> String? { fixtureServerExecutable() }
}
