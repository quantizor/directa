import ArgumentParser
import Darwin
import DirectaKit
import Foundation

/** directa: the CLI. Agents are the primary consumer: every command supports
    --json with schemas documented in docs/cli-contract.md, and failures emit the
    error envelope on stdout so agents never scrape stderr prose. */
@main
struct Directa: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "directa",
        abstract: "Command center for local dev servers.",
        version: DirectaVersion.version,
        subcommands: [
            ConfigCommand.self, Context.self, Doctor.self, Down.self, Ensure.self, Events.self,
            HookCommand.self, Link.self, Logs.self, Mark.self, Open.self, Register.self,
            Restart.self, Start.self,
            Lock.self, Statusline.self, Status.self, Stop.self, Switch.self, Trust.self,
            Uninstall.self, Unregister.self, Up.self,
            Wait.self, Why.self, XURL.self, DaemonCommand.self,
        ]
    )
}

struct GlobalOptions: ParsableArguments {
    @Flag(help: "Emit machine-readable JSON (schemas: docs/cli-contract.md).")
    var json = false

    @Flag(help: "Never auto-install or auto-start the daemon on connection failure.")
    var noBootstrap = false

    @Option(help: "Project root; defaults to the nearest devservers.json ancestor, then git root, then cwd.")
    var project: String?

    /** Resolution order: nearest ancestor with devservers.json → git root → cwd,
        then canonicalized (symlinks and on-disk case). A git worktree is a real
        distinct path and keeps its own project identity; canonicalization does
        not collapse sibling checkouts into one. */
    func resolvedProject() -> String {
        if let project {
            /** An explicit `--project myproj` (a name, not a path) lands on a
                nonexistent relative directory, and the daemon then answers an
                empty scoped view: a stop reports success against a phantom
                project while the real server keeps running. An explicitly
                passed project must be an existing directory; the default
                resolution is exempt because it is anchored to the cwd by
                construction. */
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: project, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue else {
                CLIRunner.fail(
                    WireError(
                        code: .usage,
                        hint: "run: directa status --all --json to list projects; --project takes the checkout directory",
                        message: "--project expects a directory path, but '\(project)' does not exist as a directory"),
                    json: json)
            }
            return canonicalProjectPath(project)
        }
        return Self.resolveProject(from: FileManager.default.currentDirectoryPath)
    }

    static func resolveProject(from cwd: String) -> String {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: cwd)
        while true {
            if fm.fileExists(atPath: probe.appending(path: "devservers.json").path) {
                return canonicalProjectPath(probe.path)
            }
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        var gitProbe = URL(fileURLWithPath: cwd)
        while true {
            if fm.fileExists(atPath: gitProbe.appending(path: ".git").path) {
                return canonicalProjectPath(gitProbe.path)
            }
            let parent = gitProbe.deletingLastPathComponent()
            if parent.path == gitProbe.path { break }
            gitProbe = parent
        }
        return canonicalProjectPath(cwd)
    }
}

/** Shared client construction + error rendering. Exit codes: 0 ok, 1 operation
    failed, 2 usage, 3 daemon unreachable, 4 named server not found. */
enum CLIRunner {
    static func client() -> DaemonClient {
        DaemonClient(socketPath: DirectaPaths().socketPath)
    }

    static func stdinData() -> Data {
        (try? FileHandle.standardInput.readToEnd()) ?? Data()
    }

    static func emit<T: Codable>(_ value: T, json: Bool, human: (T) -> String) {
        if json {
            let payload = (try? JSONCoding.encoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
            print(payload ?? "{}")
        } else {
            print(human(value))
        }
    }

    /** Render the failure without deciding the exit status, so a caller that has
        its own status to honor (a guarded command's) can still report. */
    static func emitFailure(_ error: WireError, json: Bool) {
        if json {
            struct Envelope: Codable {
                var error: WireError
                var ok: Bool
            }
            let payload = (try? JSONCoding.encoder().encode(Envelope(error: error, ok: false)))
                .flatMap { String(data: $0, encoding: .utf8) }
            print(payload ?? #"{"ok":false}"#)
        } else {
            var text = "directa: \(error.message)"
            if let hint = error.hint { text += "\n  \(hint)" }
            FileHandle.standardError.write(Data((text + "\n").utf8))
        }
    }

    static func fail(_ error: WireError, json: Bool) -> Never {
        emitFailure(error, json: json)
        switch error.code {
        case .daemonStarting, .daemonUnreachable, .versionMismatch:
            Foundation.exit(3)
        case .notFound:
            Foundation.exit(4)
        case .usage:
            Foundation.exit(2)
        case .alreadyExists, .configInvalid, .internalError, .notTrusted, .portDrift, .portHeld,
            .resourceLocked, .resourceMutated, .spawnFailed:
            Foundation.exit(1)
        }
    }

    static func run<R: Codable & Sendable>(
        json: Bool,
        bootstrap: Bool = true,
        _ body: (DaemonClient) async throws -> R
    ) async -> R {
        do {
            return try await awaitingRestore(body)
        } catch let error as WireError where error.code == .daemonUnreachable && bootstrap {
            if await attemptBootstrap() {
                do {
                    return try await awaitingRestore(body)
                } catch let retryError as WireError {
                    fail(retryError, json: json)
                } catch {
                    fail(WireError(code: .internalError, message: String(describing: error)), json: json)
                }
            }
            if FileManager.default.fileExists(atPath: DirectaPaths().stoppedIntentFile.path) {
                fail(
                    WireError(
                        code: .daemonUnreachable,
                        hint: "run: directa daemon start",
                        message: "ddirecta was deliberately stopped"),
                    json: json)
            }
            fail(error, json: json)
        } catch let error as WireError {
            fail(error, json: json)
        } catch {
            fail(WireError(code: .internalError, message: String(describing: error)), json: json)
        }
    }

    /** A daemon answering `daemon-starting` is busy, not gone, so the command
        waits for it instead of failing or standing up a second one. Bounded, and
        it names what it is waiting for on the first retry: a gate that blocks in
        silence reads as a hang, and the reflex that invites is killing the
        process that is making progress.

        The wait belongs here rather than in `DaemonClient` so the session hook,
        which talks to the socket directly to stay fast, keeps failing instantly
        and silently. */
    static let restoreWaitBudget = Duration.seconds(30)
    static let restorePollInterval = Duration.milliseconds(250)

    private static func awaitingRestore<R: Codable & Sendable>(
        _ body: (DaemonClient) async throws -> R
    ) async throws -> R {
        let deadline = ContinuousClock.now.advanced(by: restoreWaitBudget)
        var announced = false
        while true {
            do {
                return try await body(client())
            } catch let error as WireError where error.code == .daemonStarting {
                guard ContinuousClock.now < deadline else { throw error }
                if !announced {
                    announced = true
                    FileHandle.standardError.write(
                        Data("directa: ddirecta is restoring supervised servers; waiting…\n".utf8))
                }
                /** A cancelled sleep just re-checks the deadline on the next
                    pass, so the loop still terminates and nothing is lost. */
                try? await Task.sleep(for: restorePollInterval)
            }
        }
    }

    /** Auto-bootstrap: only against the default socket (never a test override),
        never past a deliberate-stop marker, install-if-missing when the ddirecta
        binary ships alongside this CLI. */
    static func attemptBootstrap() async -> Bool {
        await LaunchdAdmin.attemptBootstrap(extraDaemonCandidates: [CLISelf.daemonSibling])
    }

    static func describe(_ status: ServerStatus) -> String {
        var parts = ["\(status.server): \(status.phase.rawValue)"]
        if let pid = status.pid { parts.append("pid \(pid)") }
        if let port = status.declaredPort { parts.append("port \(port)") }
        if let worktree = status.worktree { parts.append("worktree \(worktree)") }
        if let exit = status.lastExit {
            let cause = exit.code.map { "exit \($0)" } ?? exit.signal.map { "signal \($0)" } ?? "unknown"
            parts.append("last exit \(cause) at \(JSONCoding.formatISO8601(exit.at))")
        }
        if status.blockedOn != nil {
            parts.append(
                "blocked on interactive auth (start once in a terminal, then: directa ensure \(status.server))")
        }
        if let spawn = status.spawnError {
            parts.append("spawn failed: \(spawn.message)")
        }
        parts.append("log \(status.logPath)")
        return parts.joined(separator: "  ·  ")
    }
}

struct Ensure: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Idempotently start a server: healthy is a no-op, otherwise start and wait for health.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Server name.")
    var name: String

    @Option(help: "Override the declared port for this run.")
    var port: Int?

    @Option(help: "Seconds to wait for health before giving up.")
    var timeout: Double = 60

    func run() async throws {
        let params = EnsureParams(
            name: name, port: port, project: global.resolvedProject(), timeoutSeconds: timeout)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(
                .serverEnsure, params: params, expecting: EnsureResult.self,
                operationTimeoutSeconds: timeout)
        }
        CLIRunner.emit(result, json: global.json) { r in
            var text = CLIRunner.describe(r.server)
            if let reason = r.reason { text = "ensure fell short (\(reason.rawValue))\n" + text }
            return text
        }
        if result.reason != nil {
            Foundation.exit(1)
        }
    }
}

struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Block until a server is healthy (or stopped); fails fast on crash.")

    @Flag(help: "Wait for the server to be healthy (the default).")
    var healthy = false

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Server name.")
    var name: String

    @Flag(help: "Wait for the server to be fully stopped instead.")
    var stopped = false

    @Option(help: "Seconds to wait before giving up.")
    var timeout: Double = 60

    func run() async throws {
        let condition: WaitCondition = stopped ? .stopped : .healthy
        let params = WaitParams(
            condition: condition, name: name, project: global.resolvedProject(), timeoutSeconds: timeout)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(
                .serverWait, params: params, expecting: EnsureResult.self,
                operationTimeoutSeconds: timeout)
        }
        CLIRunner.emit(result, json: global.json) { r in
            if let reason = r.reason {
                return "wait fell short (\(reason.rawValue))\n" + CLIRunner.describe(r.server)
            }
            return CLIRunner.describe(r.server)
        }
        if result.reason != nil {
            Foundation.exit(1)
        }
    }
}

struct Register: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Register a server ad hoc into the machine registry.")

    /** unconditionalSingleValue lets argv words that start with dashes through
        (`--cmd --spawn-grandchild`), which agent-composed commands need. */
    @Option(
        parsing: .unconditionalSingleValue,
        help: "Command argv, repeated per word; values may start with dashes.")
    var cmd: [String] = []

    @Option(help: "Working directory relative to the project root.")
    var cwd: String?

    @OptionGroup var global: GlobalOptions

    @Option(help: "Server name.")
    var name: String

    @Flag(help: "Replace an existing entry of the same name under --write.")
    var force = false

    @Option(help: "Declared port.")
    var port: Int?

    @Flag(help: "Also append this server to devservers.json.")
    var write = false

    func run() async throws {
        guard !cmd.isEmpty else {
            CLIRunner.fail(
                WireError(code: .usage, message: "--cmd is required (repeat it per argv word)"),
                json: global.json)
        }
        let spec = ServerSpec(command: cmd, cwd: cwd, name: name, port: port)
        let project = global.resolvedProject()
        let params = RegisterParams(project: project, spec: spec)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            let registered = try await client.request(
                .serverRegister, params: params, expecting: ServerResult.self)
            guard write else { return registered }
            /** Merge mode so the rest of the file survives: the registry is not
                the file, and a register must never rewrite entries it never saw. */
            _ = try await client.request(
                .projectInitConfig,
                params: InitConfigParams(
                    force: force, fromDaemon: false, mode: .merge, project: project,
                    servers: [spec]),
                expecting: InitConfigResult.self)
            return registered
        }
        CLIRunner.emit(result, json: global.json) { "registered \(CLIRunner.describe($0.server))" }
    }
}

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start a registered server.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Server name.")
    var name: String

    @Option(help: "Override the declared port for this run.")
    var port: Int?

    func run() async throws {
        let params = ServerTargetParams(name: name, port: port, project: global.resolvedProject())
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.serverStart, params: params, expecting: ServerResult.self)
        }
        if result.server.phase == .failed {
            CLIRunner.fail(
                WireError(
                    code: .spawnFailed,
                    hint: "run: directa status \(name) --json",
                    message: result.server.spawnError?.message ?? "spawn failed"),
                json: global.json)
        }
        CLIRunner.emit(result, json: global.json) { CLIRunner.describe($0.server) }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show server status for the project.")

    @OptionGroup var global: GlobalOptions

    @Flag(help: "List every project the daemon knows (machine-wide).")
    var all = false

    @Argument(help: "Server name (omit for all servers in the project).")
    var name: String?

    func run() async throws {
        let project = all ? "" : global.resolvedProject()
        let params = ProjectParams(name: name, project: project)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.serverStatus, params: params, expecting: ServerListResult.self)
        }
        if let name, result.servers.isEmpty {
            CLIRunner.fail(
                WireError(
                    code: .notFound,
                    hint: "run: directa status --json",
                    message: "no server named '\(name)' is registered for this project"),
                json: global.json)
        }
        CLIRunner.emit(result, json: global.json) { list in
            if list.servers.isEmpty {
                return "no servers registered for this project (hint: directa register --name myproj --cmd …)"
            }
            return list.servers.map(CLIRunner.describe).joined(separator: "\n")
        }
    }
}

/** One daemon-side transition rather than a client-side stop then ensure: that
    pair leaves a window for another session's ensure, and a refusal arrives only
    after the server is already down. */
struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop and re-ensure a server as one transition.")

    @Flag(help: "Restart every server in the project.")
    var all = false

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Server name (omit with --all).")
    var name: String?

    @Option(help: "Override the declared port for this run.")
    var port: Int?

    @Option(help: "Per-server seconds to wait for health.")
    var timeout: Double = 60

    func run() async throws {
        /** A bare `restart` is far likelier to be typed by reflex than `down`
            is, and bouncing a whole project by accident is expensive. */
        if (name == nil) == !all {
            CLIRunner.fail(
                WireError(
                    code: .usage,
                    hint: "run: directa restart --all",
                    message: name == nil
                        ? "directa restart needs a server name, or --all for the whole project"
                        : "pass a server name or --all, not both"),
                json: global.json)
        }
        let params = RestartParams(
            names: name.map { [$0] }, port: port, project: global.resolvedProject(),
            timeoutSeconds: timeout)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(
                .serverRestart, params: params, expecting: GroupResult.self,
                operationTimeoutSeconds: timeout)
        }
        CLIRunner.emit(result, json: global.json) { r in
            r.results.map { CLIRunner.describe($0.server) }.joined(separator: "\n")
        }
        if result.results.contains(where: { $0.reason != nil }) {
            Foundation.exit(1)
        }
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop a running server (whole process group).")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Server name.")
    var name: String

    func run() async throws {
        let params = ServerTargetParams(name: name, project: global.resolvedProject())
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.serverStop, params: params, expecting: ServerResult.self)
        }
        CLIRunner.emit(result, json: global.json) { CLIRunner.describe($0.server) }
        /** Human mode only: stopping a server to get exclusive access to
            something it holds is the heavy way there, and `lock` does it without
            a bounce. `--json` carries `locks` instead, so stdout keeps its schema. */
        if !global.json, let resource = result.server.locks?.sorted().first {
            FileHandle.standardError.write(
                Data(
                    "hint: \(name) holds '\(resource)'; directa lock \(resource) -- <command> gets exclusive access without stopping it\n"
                        .utf8))
        }
    }
}

struct Unregister: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove a server from the machine registry.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Server name.")
    var name: String

    func run() async throws {
        let params = ServerTargetParams(name: name, project: global.resolvedProject())
        _ = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.serverUnregister, params: params, expecting: WireEmpty.self)
        }
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in "unregistered \(name)" }
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Query a server's structured logs (out/err/sys/mark streams).")

    @Flag(help: "Keep polling for new lines (Ctrl-C to stop).")
    var follow = false

    @OptionGroup var global: GlobalOptions

    @Option(help: "Regex filter (Swift Regex dialect) applied to line text.")
    var grep: String?

    @Argument(help: "Server name.")
    var name: String

    @Option(help: "Only lines at or after this time: 5m/2h style or ISO-8601.")
    var since: String?

    @Option(help: "Only lines after the mark with this id (from directa mark).")
    var sinceMark: String?

    @Option(help: "Filter to one stream: out, err, sys, or mark.")
    var stream: [String] = []

    @Option(help: "Only the last N lines.")
    var tail: Int?

    func run() async throws {
        var sinceDate: Date?
        if let since {
            sinceDate = Self.parseSince(since)
            if sinceDate == nil {
                CLIRunner.fail(
                    WireError(code: .usage, message: "--since takes 5m/2h/1d style or ISO-8601, got '\(since)'"),
                    json: global.json)
            }
        }
        let streams: [LogStream]? = stream.isEmpty ? nil : stream.compactMap { LogStream(rawValue: $0) }
        if let streams, streams.count != stream.count {
            CLIRunner.fail(
                WireError(code: .usage, message: "--stream takes out, err, sys, or mark"), json: global.json)
        }
        var params = LogsQueryParams(
            grep: grep, name: name, project: global.resolvedProject(), since: sinceDate,
            sinceMark: sinceMark, streams: streams, tail: follow ? (tail ?? 50) : tail)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.logsQuery, params: params, expecting: LogsQueryResult.self)
        }
        emit(result.lines)
        guard follow else { return }
        /** Follow = incremental polling since the last seen line: restart-safe
            and no push machinery. Duplicate timestamps are deduped by count. */
        var lastAt = result.lines.last?.at
        var seenAtLast = result.lines.filter { $0.at == lastAt }.count
        params.sinceMark = nil
        params.tail = nil
        while true {
            try await Task.sleep(for: .milliseconds(300))
            params.since = lastAt
            let more = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
                try await client.request(.logsQuery, params: params, expecting: LogsQueryResult.self)
            }
            var fresh = more.lines
            if let lastAt {
                var skip = seenAtLast
                fresh = fresh.drop { record in
                    if record.at == lastAt, skip > 0 {
                        skip -= 1
                        return true
                    }
                    return false
                }.filter { $0.at >= lastAt }
            }
            if !fresh.isEmpty {
                emit(fresh)
                lastAt = fresh.last?.at
                seenAtLast = more.lines.filter { $0.at == lastAt }.count
            }
        }
    }

    private func emit(_ lines: [LogRecord]) {
        if global.json {
            for line in lines {
                if let data = try? JSONCoding.encoder().encode(line) {
                    print(String(decoding: data, as: UTF8.self))
                }
            }
        } else {
            for line in lines {
                print("\(JSONCoding.formatISO8601(line.at)) [\(line.stream.rawValue)] \(line.text)")
            }
        }
    }

    /** 5m / 2h / 1d / 30s relative forms, else ISO-8601. */
    static func parseSince(_ text: String) -> Date? {
        if let match = text.wholeMatch(of: /(\d+)([smhd])/) {
            let value = Double(match.1) ?? 0
            let unit: Double =
                switch match.2 {
                case "s": 1
                case "m": 60
                case "h": 3600
                default: 86400
                }
            return Date().addingTimeInterval(-value * unit)
        }
        return JSONCoding.parseISO8601(text)
    }
}

struct Mark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drop a correlation marker into a server's log stream.")

    @Flag(help: "Mark every server in the project.")
    var all = false

    @OptionGroup var global: GlobalOptions

    @Option(help: "Requester label recorded with the mark (defaults to the client pid).")
    var label: String?

    /** With --all the only argument is the text; otherwise name then text. */
    @Argument(help: "Server name (omitted with --all), then marker text.")
    var words: [String]

    func run() async throws {
        var name: String?
        var text: String
        if all {
            guard !words.isEmpty else {
                CLIRunner.fail(WireError(code: .usage, message: "mark --all needs marker text"), json: global.json)
            }
            text = words.joined(separator: " ")
        } else {
            guard words.count >= 2 else {
                CLIRunner.fail(
                    WireError(code: .usage, message: "usage: directa mark <name> <text> (or --all <text>)"),
                    json: global.json)
            }
            name = words[0]
            text = words.dropFirst().joined(separator: " ")
        }
        let params = MarkParams(
            all: all ? true : nil,
            label: label ?? "pid-\(getpid())",
            name: name,
            project: global.resolvedProject(),
            text: text)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.logsMark, params: params, expecting: MarkResult.self)
        }
        CLIRunner.emit(result, json: global.json) { r in
            r.marks.map { "marked \($0.server): \($0.id) at \(JSONCoding.formatISO8601($0.at))" }
                .joined(separator: "\n")
        }
    }
}

struct Events: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The unified event feed: starts, stops, crashes, health changes, marks.")

    @Flag(help: "Events for every project, not just the current one.")
    var all = false

    @OptionGroup var global: GlobalOptions

    @Option(help: "Only events at or after this time: 5m/2h style or ISO-8601.")
    var since: String?

    @Option(help: "Only events after the mark with this id.")
    var sinceMark: String?

    @Option(help: "Only the last N events.")
    var tail: Int?

    func run() async throws {
        var sinceDate: Date?
        if let since {
            sinceDate = Logs.parseSince(since)
            if sinceDate == nil {
                CLIRunner.fail(
                    WireError(code: .usage, message: "--since takes 5m/2h/1d style or ISO-8601, got '\(since)'"),
                    json: global.json)
            }
        }
        let params = EventsQueryParams(
            project: all ? nil : global.resolvedProject(),
            since: sinceDate,
            sinceMark: sinceMark,
            tail: tail)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.eventsQuery, params: params, expecting: EventsQueryResult.self)
        }
        CLIRunner.emit(result, json: global.json) { r in
            if r.events.isEmpty { return "no events" }
            return r.events.map { event in
                var text = "\(JSONCoding.formatISO8601(event.at)) \(event.server): \(event.kind.rawValue)"
                if let detail = event.detail { text += " (\(detail))" }
                return text
            }.joined(separator: "\n")
        }
    }
}

struct Why: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnose a server: root cause across its dependency chain.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Server name.")
    var name: String

    func run() async throws {
        let params = ServerTargetParams(name: name, project: global.resolvedProject())
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.serverWhy, params: params, expecting: WhyResult.self)
        }
        CLIRunner.emit(result, json: global.json) { r in
            var sections: [String] = []
            if let root = r.rootCause {
                sections.append("root cause: \(root)")
            }
            for finding in r.findings {
                var block = "\(finding.server) [\(finding.phase.rawValue)]: \(finding.summary)"
                for line in finding.evidence {
                    block += "\n    \(line)"
                }
                sections.append(block)
            }
            return sections.joined(separator: "\n")
        }
    }
}

struct Context: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fenced plain-text server context for any agent harness. Silent when there is nothing to say.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        if let text = await HookContext.render(project: global.resolvedProject()) {
            print(text)
        }
    }
}

struct HookCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Agent-harness session hooks.",
        subcommands: [
            HookInstall.self, HookUninstall.self, HookAntigravitySessionStart.self,
            HookClaudeSessionStart.self, HookCursorSessionStart.self, HookGrokSessionStart.self,
        ]
    )
}

struct HookInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Wire the session-start context hook into an agent harness (idempotent).")

    /** Absolute path to record in the hook command, overriding this binary's own
        resolved path. The menu bar app passes the CLI owner's path (brew's shim
        under a cask) so the hook points at a stable, on-PATH location instead of
        the internal bundle path this binary resolves to. */
    @Option(help: "Absolute directa path to record in the hook (default: this binary's path).")
    var cliPath: String?

    @OptionGroup var global: GlobalOptions

    @Option(help: "Harness to install for: \(harnessAdapters.map(\.name).joined(separator: ", ")) (default: claude).")
    var harness: String = "claude"

    @Flag(help: "Also print the statusline wiring suggestion.")
    var statusline = false

    func run() async throws {
        guard let adapter = harnessAdapters.first(where: { $0.name == harness }) else {
            CLIRunner.fail(
                WireError(
                    code: .usage,
                    hint: "supported: \(harnessAdapters.map(\.name).joined(separator: ", ")) (adding one: CONTRIBUTING.md)",
                    message: "unknown harness '\(harness)'"),
                json: global.json)
        }
        if let override = cliPath, !override.hasPrefix("/") {
            CLIRunner.fail(
                WireError(
                    code: .usage,
                    hint: "pass an absolute path, e.g. --cli-path /opt/homebrew/bin/directa",
                    message: "--cli-path must be absolute, got '\(override)'"),
                json: global.json)
        }
        let cliPath = cliPath ?? CLISelf.path
        do {
            let summary = try adapter.install(cliPath: cliPath)
            var output = summary
            if statusline {
                output += "\n\nStatusline: pipe your statusline script through `directa statusline` to append server presence, e.g.\n  directa statusline <<< \"$STDIN_JSON\"  ->  myproj:3000 ok · api crashed"
            }
            /** The discovery tip is printed, never appended to CLAUDE.md/AGENTS.md:
                directa does not edit a project's files. Server names come from the
                nearest devservers.json (empty when there is none yet). */
            let serverNames: [String]
            if let view = try? ProjectConfigLoader.load(project: global.resolvedProject()) {
                serverNames = view.specs.map(\.name)
            } else {
                serverNames = []
            }
            output += "\n\nDiscovery tip: paste this bullet into the project's CLAUDE.md/AGENTS.md so agents find directa on their own (directa never edits those files):\n\(DiscoveryStanza.render(serverNames: serverNames))"
            CLIRunner.emit(WireEmpty(), json: global.json) { _ in output }
        } catch {
            CLIRunner.fail(
                WireError(code: .internalError, message: "hook install failed: \(error)"),
                json: global.json)
        }
    }
}

struct HookUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove directa's session hook from an agent harness (idempotent).")

    @OptionGroup var global: GlobalOptions

    /** Omitted means every harness, so a plain `hook uninstall` cleans up
        wherever directa wrote a hook rather than only the default one. */
    @Option(help: "Harness to remove from: \(harnessAdapters.map(\.name).joined(separator: ", ")) (default: all).")
    var harness: String?

    func run() async throws {
        let adapters: [any HarnessAdapter]
        if let harness {
            guard let adapter = harnessAdapters.first(where: { $0.name == harness }) else {
                CLIRunner.fail(
                    WireError(
                        code: .usage,
                        hint: "supported: \(harnessAdapters.map(\.name).joined(separator: ", "))",
                        message: "unknown harness '\(harness)'"),
                    json: global.json)
            }
            adapters = [adapter]
        } else {
            adapters = harnessAdapters
        }
        let result = Self.uninstallAll(adapters)
        if !result.failures.isEmpty {
            /** Every adapter before the first failure has already rewritten its
                file, so the report names what succeeded rather than discarding
                that work. */
            let succeeded = adapters.map(\.name).filter { name in
                !result.failures.contains { $0.name == name }
            }
            var message = "hook uninstall finished with errors"
            if !succeeded.isEmpty {
                message += "; removed from \(succeeded.joined(separator: ", "))"
            }
            message +=
                ". Failed: "
                + result.failures.map { "\($0.name) (\($0.message))" }.joined(separator: "; ")
            message += " Fix each cause and rerun directa hook uninstall."
            CLIRunner.fail(
                WireError(code: .internalError, hint: "directa hook uninstall", message: message),
                json: global.json)
        }
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in result.summaries.joined(separator: "\n") }
    }

    /** One uninstall pass over the adapters, collecting rather than aborting: a
        refusal from one harness must not discard the others' summaries, because
        their files are already rewritten by the time the throw lands. */
    static func uninstallAll(_ adapters: [any HarnessAdapter]) -> (
        summaries: [String], failures: [(name: String, message: String)]
    ) {
        var summaries: [String] = []
        var failures: [(name: String, message: String)] = []
        for adapter in adapters {
            do {
                summaries.append(try adapter.uninstall())
            } catch let error as WireError {
                failures.append((adapter.name, error.message))
            } catch {
                failures.append((adapter.name, String(describing: error)))
            }
        }
        return (summaries, failures)
    }
}

/** Invoked by Antigravity's PreInvocation hook. Reads the hook's stdin JSON for
    the workspace directory, emits {"injectSteps": [{"ephemeralMessage": ...}]},
    and always exits 0 quickly. */
struct HookAntigravitySessionStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "antigravity-session-start", shouldDisplay: false)

    func run() async throws {
        let stdin = CLIRunner.stdinData()
        let cwd = HookSessionCwd.resolve(stdin: stdin)
        FileManager.default.changeCurrentDirectoryPath(cwd)
        let project = GlobalOptions.resolveProject(from: cwd)
        guard let text = await HookContext.render(project: project) else {
            let empty: [String: Any] = ["injectSteps": []]
            if let data = try? JSONSerialization.data(withJSONObject: empty) {
                FileHandle.standardOutput.write(data)
            }
            return
        }
        let output: [String: Any] = [
            "injectSteps": [
                ["ephemeralMessage": text]
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: output) {
            FileHandle.standardOutput.write(data)
        }
    }
}

/** Invoked by Claude Code's SessionStart hook. Reads the hook's stdin JSON for
    the session cwd, emits hookSpecificOutput.additionalContext, and always exits
    0 quickly: a session start must never stall or fail on directa's account. */
struct HookClaudeSessionStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude-session-start", shouldDisplay: false)

    func run() async throws {
        let stdin = CLIRunner.stdinData()
        let cwd = HookSessionCwd.resolve(stdin: stdin)
        /** Project resolution without --project: reuse the CLI's walk from the
            hook cwd by chdir-ing there first. */
        FileManager.default.changeCurrentDirectoryPath(cwd)
        let project = GlobalOptions.resolveProject(from: cwd)
        guard let text = await HookContext.render(project: project) else { return }
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "additionalContext": text,
                "hookEventName": "SessionStart",
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: output) {
            FileHandle.standardOutput.write(data)
        }
    }
}

/** Invoked by Cursor's sessionStart hook. Emits {additional_context} (Cursor's
    snake_case schema). Same silence / exit-0 guarantees as the Claude hook. */
struct HookCursorSessionStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cursor-session-start", shouldDisplay: false)

    func run() async throws {
        let stdin = CLIRunner.stdinData()
        let cwd = HookSessionCwd.resolve(stdin: stdin)
        FileManager.default.changeCurrentDirectoryPath(cwd)
        let project = GlobalOptions.resolveProject(from: cwd)
        guard let text = await HookContext.render(project: project) else { return }
        let output: [String: Any] = ["additional_context": text]
        if let data = try? JSONSerialization.data(withJSONObject: output) {
            FileHandle.standardOutput.write(data)
        }
    }
}

/** Invoked by Grok Build's PreToolUse and UserPromptSubmit hooks. Emits
    hookSpecificOutput.additionalContext on PreToolUse (the path Grok delivers).
    UserPromptSubmit only marks the turn. SessionStart and Stop are silent, so a
    leftover registration cannot stall the session or continue the turn. Same
    silence / exit-0 guarantees as the Claude hook. */
struct HookGrokSessionStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grok-session-start", shouldDisplay: false)

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let event = GrokHookEvent.parse(env["GROK_HOOK_EVENT"])
        guard event != .leftover else { return }

        if event == .unspecified {
            let stdin = CLIRunner.stdinData()
            _ = await emit(stdin: stdin)
            return
        }

        let directory = GrokTurnGate.directory(environment: env)
        let key = GrokTurnGate.sessionKey(env["GROK_SESSION_ID"])
        var state = GrokTurnGate.load(sessionKey: key, directory: directory)
        let action = GrokSessionHook.action(for: event, state: &state)
        switch action {
        case .silent:
            return
        case .silentPersist:
            GrokTurnGate.save(state, sessionKey: key, directory: directory)
            return
        case .emitUnmarked, .emitAndMark:
            break
        }

        let stdin = CLIRunner.stdinData()
        guard await emit(stdin: stdin) else { return }
        if action == .emitAndMark {
            GrokSessionHook.markEmitted(&state)
            GrokTurnGate.save(state, sessionKey: key, directory: directory)
        }
    }

    /** Returns false when there is nothing to say, so the caller can skip the mark. */
    private func emit(stdin: Data) async -> Bool {
        let cwd = HookSessionCwd.resolve(stdin: stdin)
        FileManager.default.changeCurrentDirectoryPath(cwd)
        let project = GlobalOptions.resolveProject(from: cwd)
        guard let text = await HookContext.render(project: project) else { return false }
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "additionalContext": text,
                "hookEventName": "PreToolUse",
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: output) {
            FileHandle.standardOutput.write(data)
        }
        return true
    }
}

/** Statusline helper: reads the harness's statusline stdin JSON, prints one
    compact presence line for the cwd's project (empty when nothing to show). */
struct Statusline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compact server presence for a statusline; reads harness stdin JSON.")

    func run() async throws {
        let stdin = CLIRunner.stdinData()
        var cwd = FileManager.default.currentDirectoryPath
        if let payload = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any] {
            if let workspace = payload["workspace"] as? [String: Any],
                let dir = workspace["current_dir"] as? String {
                cwd = dir
            } else if let dir = payload["cwd"] as? String {
                cwd = dir
            }
        }
        let project = GlobalOptions.resolveProject(from: cwd)
        let client = DaemonClient(socketPath: DirectaPaths().socketPath)
        guard
            let list = try? await client.request(
                .serverStatus, params: ProjectParams(project: project), expecting: ServerListResult.self),
            !list.servers.isEmpty
        else { return }
        let parts = list.servers.map { server in
            let port = server.displayPort.map { ":\($0)" } ?? ""
            let state =
                switch server.phase {
                case .running: "ok"
                default: server.phase.rawValue
                }
            return "\(server.server)\(port) \(state)"
        }
        print(parts.joined(separator: " · "))
    }
}

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the whole project in dependency order, waiting per waitFor.")

    @OptionGroup var global: GlobalOptions

    @Option(help: "Comma-separated server names (their dependencies come along).")
    var only: String?

    @Option(help: "Override the declared port for each server this up starts.")
    var port: Int?

    @Option(help: "Per-server seconds to wait for health.")
    var timeout: Double = 60

    func run() async throws {
        let params = GroupParams(
            only: only.map { $0.split(separator: ",").map(String.init) },
            port: port,
            project: global.resolvedProject(),
            timeoutSeconds: timeout)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(
                .groupUp, params: params, expecting: GroupResult.self,
                operationTimeoutSeconds: timeout)
        }
        CLIRunner.emit(result, json: global.json) { r in
            r.results.map { entry in
                entry.reason.map { "\(CLIRunner.describe(entry.server))  ·  FELL SHORT (\($0.rawValue))" }
                    ?? CLIRunner.describe(entry.server)
            }.joined(separator: "\n")
        }
        if result.results.contains(where: { $0.reason != nil }) {
            Foundation.exit(1)
        }
    }
}

struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop the whole project in reverse dependency order.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let params = GroupParams(project: global.resolvedProject())
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            /** A deep dependency chain drains one wave at a time, each with its own
                stop grace, so the client waits well past a single stop. */
            try await client.request(
                .groupDown, params: params, expecting: GroupResult.self,
                operationTimeoutSeconds: 120)
        }
        CLIRunner.emit(result, json: global.json) { r in
            r.results.isEmpty
                ? "nothing to stop"
                : r.results.map { CLIRunner.describe($0.server) }.joined(separator: "\n")
        }
    }
}

struct Trust: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Approve this project's devservers.json so the session hook advertises it.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let params = ProjectOnlyParams(project: global.resolvedProject())
        _ = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.projectTrust, params: params, expecting: WireEmpty.self)
        }
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in "project trusted" }
    }
}

struct Open: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a server's URL (or one of a multi-headed server's named heads).")

    /** Positional order is load-bearing: the server name comes first, then the
        optional head, so declaration order deliberately breaks the alphabet. */
    @Argument(help: "Server name.")
    var name: String

    @Argument(help: "Head name for multi-headed servers (see directa status --json).")
    var head: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let params = ProjectParams(name: name, project: global.resolvedProject())
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.serverStatus, params: params, expecting: ServerListResult.self)
        }
        guard let server = result.servers.first else {
            CLIRunner.fail(
                WireError(
                    code: .notFound, hint: "run: directa status --json",
                    message: "no server named '\(name)' is registered for this project"),
                json: global.json)
        }
        var target = server.url
        if let head {
            guard let headURL = server.heads?[head] else {
                let known = (server.heads ?? [:]).keys.sorted().joined(separator: ", ")
                CLIRunner.fail(
                    WireError(
                        code: .notFound,
                        hint: known.isEmpty ? "this server declares no heads" : "known heads: \(known)",
                        message: "no head named '\(head)' on \(name)"),
                    json: global.json)
            }
            target = headURL
        }
        guard let url = target else {
            CLIRunner.fail(
                WireError(
                    code: .usage,
                    hint: "add a port, url, or heads to \(name) in devservers.json",
                    message: "\(name) has no URL (no port declared and no url configured)"),
                json: global.json)
        }
        LaunchdAdmin.shell("/usr/bin/open", [url])
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in "opened \(url)" }
    }
}

/** Print a `directa://` URL for the cwd project (Raycast snippets, docs, smoke). */
struct Link: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print a directa:// URL for a verb and server in this project.")

    @Argument(help: "Verb: open, ensure, stop, or why.")
    var verb: String

    @Argument(help: "Server name.")
    var name: String

    @Argument(help: "Head name (open only).")
    var head: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        guard let deepVerb = DeepLinkVerb(rawValue: verb.lowercased()) else {
            CLIRunner.fail(
                WireError(
                    code: .usage,
                    hint: "verbs: \(DeepLinkVerb.allCases.map(\.rawValue).sorted().joined(separator: ", "))",
                    message: "unknown verb '\(verb)'"),
                json: global.json)
        }
        if head != nil, deepVerb != .open {
            CLIRunner.fail(
                WireError(
                    code: .usage, message: "a head is only valid with verb open"),
                json: global.json)
        }
        let project = global.resolvedProject()
        let slug = (project as NSString).lastPathComponent
        let link = DeepLink(verb: deepVerb, projectSlug: slug, server: name, head: head)
        struct LinkResult: Codable {
            var url: String
        }
        let url = link.urlString()
        CLIRunner.emit(LinkResult(url: url), json: global.json) { $0.url }
    }
}

/** Smoke/CI entry: run a `directa://` URL through DeepLinkRunner without Launch
    Services or the menu bar app. Hidden from `--help`. */
struct XURL: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "x-url",
        abstract: "Dispatch a directa:// URL via the daemon (smoke / agents).",
        shouldDisplay: false)

    @Argument(help: "A directa:// URL.")
    var url: String

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let link: DeepLink
        switch DeepLink.parse(url) {
        case .failure(let error):
            CLIRunner.fail(error, json: global.json)
        case .success(let parsed):
            link = parsed
        }
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await DeepLinkRunner(client: client, effects: CLIDeepLinkEffects()).run(link)
        }
        CLIRunner.emit(result, json: global.json) { r in
            var line = "\(r.verb.rawValue) \(r.projectPath)"
            if let detail = r.detail { line += ": \(detail)" }
            return line
        }
    }
}

/** CLI-side effects for x-url: open(1), pbcopy, stderr notify (no AppKit). */
struct CLIDeepLinkEffects: DeepLinkEffects {
    func copyToPasteboard(_ text: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        process.standardInput = pipe
        try? process.run()
        pipe.fileHandleForWriting.write(Data(text.utf8))
        try? pipe.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    func notify(title: String, body: String) async {
        FileHandle.standardError.write(Data("directa: \(title): \(body)\n".utf8))
    }

    func openBrowser(_ url: URL) async {
        _ = LaunchdAdmin.shell("/usr/bin/open", [url.absoluteString])
    }
}

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Project configuration helpers.",
        subcommands: [ConfigCheck.self, ConfigInit.self]
    )
}

/** Writes a devservers.json from what the daemon already knows. The file is
    routinely gitignored per machine, so without this there is no way back from
    losing it, and a `git rm --cached` plus a branch switch deletes it outright. */
struct ConfigInit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Write devservers.json from the servers the daemon already knows.")

    @Option(
        parsing: .unconditionalSingleValue,
        help: "Argv word for an extra server to declare (repeat); requires --name.")
    var cmd: [String] = []

    @Flag(help: "Print what would be written without touching the file.")
    var dryRun = false

    @Flag(help: "Replace an existing devservers.json.")
    var force = false

    @OptionGroup var global: GlobalOptions

    @Option(help: "Project host signature (default: <project-slug>.localhost).")
    var host: String?

    @Option(help: "Name for an extra server to declare alongside the known ones.")
    var name: String?

    @Option(help: "Port for the extra server.")
    var port: Int?

    func run() async throws {
        if name == nil, !cmd.isEmpty {
            CLIRunner.fail(
                WireError(
                    code: .usage, hint: "run: directa config init --name <name> --cmd <word>",
                    message: "--cmd needs a --name to attach the command to"),
                json: global.json)
        }
        var extras: [ServerSpec]?
        if let name {
            guard !cmd.isEmpty else {
                CLIRunner.fail(
                    WireError(
                        code: .usage, hint: "run: directa config init --name \(name) --cmd <word>",
                        message: "--name needs a --cmd to run"),
                    json: global.json)
            }
            extras = [ServerSpec(command: cmd, name: name, port: port)]
        }
        let params = InitConfigParams(
            dryRun: dryRun, force: force, fromDaemon: true, host: host,
            mode: force ? .replace : .create, project: global.resolvedProject(), servers: extras)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(
                .projectInitConfig, params: params, expecting: InitConfigResult.self)
        }
        CLIRunner.emit(result, json: global.json) { r in
            guard r.written else { return r.content }
            var lines = ["wrote \(r.path) (servers: \(r.check.servers.joined(separator: ", ")))"]
            if let host = r.check.host { lines.append("host: \(host)") }
            lines.append(contentsOf: r.check.warnings.map { "warning: \($0)" })
            if let missing = r.notRecovered, !missing.isEmpty {
                lines.append(
                    "note: \(missing.joined(separator: ", ")) cannot be recovered from daemon state; re-add by hand")
            }
            return lines.joined(separator: "\n")
        }
    }
}

struct ConfigCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check", abstract: "Validate devservers.json with the daemon's own validator.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let params = ProjectOnlyParams(project: global.resolvedProject())
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.projectCheck, params: params, expecting: CheckResult.self)
        }
        CLIRunner.emit(result, json: global.json) { r in
            var lines: [String] = []
            if let worktree = r.worktree {
                lines.append(
                    "worktree: \(worktree) (linked git worktree; the declared host is used unchanged, so origin-pinned app config keeps working)")
            }
            if let host = r.host { lines.append("host: \(host)") }
            if let effective = r.effectiveHost, let declared = r.host {
                lines.append(
                    "effective host: \(effective) (\(Self.explain(r.effectiveHostReason)); the file declares \(declared))")
            }
            for server in r.serverHosts ?? [] where server.differs {
                lines.append(
                    "  \(server.server ?? "?"): \(server.effective) (\(Self.explain(server.reason)))")
            }
            if !r.servers.isEmpty { lines.append("servers: \(r.servers.joined(separator: ", "))") }
            lines.append(contentsOf: r.errors.map { "error: \($0)" })
            lines.append(contentsOf: r.warnings.map { "warning: \($0)" })
            if r.errors.isEmpty && r.warnings.isEmpty { lines.append("config ok") }
            return lines.joined(separator: "\n")
        }
        if !result.errors.isEmpty {
            Foundation.exit(1)
        }
    }

    /** Exhaustive so a new reason has to be given a sentence a reader can act
        on, rather than printing a raw enum token. `linkedWorktree` and
        `serverOverride` are no longer produced by the current daemon; the
        sentences cover an older daemon on the socket so the pairing still
        reads sensibly. */
    static func explain(_ reason: EffectiveHostReason?) -> String {
        guard let reason else { return "differs from the declared host" }
        switch reason {
        case .linkedWorktree:
            return "the daemon is older than this CLI and still prepends a worktree label"
        case .localOverlay:
            return "directa.local.json overrides the host for this checkout"
        case .serverOverride:
            return "this server declares its own host"
        }
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Health report: daemon, launchd, PATH staleness, signatures, stale registrations.")

    @Flag(help: "Prune registry entries whose project directories no longer exist.")
    var fix = false

    @OptionGroup var global: GlobalOptions

    struct Finding: Codable {
        var detail: String
        var kind: String
        var severity: String
    }

    func run() async throws {
        var findings: [Finding] = []
        let client = CLIRunner.client()
        let info = try? await client.request(.daemonInfo, params: WireEmpty(), expecting: DaemonInfo.self)
        if let info {
            findings.append(
                Finding(detail: "v\(info.daemonVersion) pid \(info.pid) on \(info.socketPath)", kind: "daemon", severity: "ok"))
            let livePath = LaunchdAdmin.capturedPath()
            let storedPath = LaunchdAdmin.readAgentPath()
            if let daemonPath = info.searchPath, daemonPath != livePath {
                findings.append(
                    Finding(
                        detail: "daemon PATH differs from the current login shell (captured at install; run: directa daemon install)",
                        kind: "path-staleness", severity: "warning"))
            }
            if let storedPath, storedPath != livePath {
                findings.append(
                    Finding(
                        detail: "agent.path differs from the current login shell (run: directa daemon install)",
                        kind: "path-staleness", severity: "warning"))
            }
        } else {
            findings.append(
                Finding(detail: "daemon not responding (run: directa daemon status)", kind: "daemon", severity: "error"))
        }
        let printed = LaunchdAdmin.shell(
            "/bin/launchctl", ["print", "\(LaunchdJobs.guiDomain)/\(LaunchdAdmin.label)"])
        findings.append(
            Finding(
                detail: LaunchdAdmin.launchdState(from: printed), kind: "launchd",
                severity: "info"))
        if printed.status == 0 {
            let agent = LaunchdJobs.parseAgentPrint(printed.output)
            if agent.jetsammed {
                let runs = agent.runs.map { " (\($0) runs)" } ?? ""
                findings.append(
                    Finding(
                        detail:
                            "ddirecta last exited \(agent.lastExitReason ?? "OS_REASON_JETSAM")\(runs); memory pressure killed the daemon, not a crash dump. Check: launchctl print \(LaunchdJobs.guiDomain)/\(LaunchdAdmin.label)",
                        kind: "jetsam", severity: "warning"))
            }
        }
        if let all = try? await client.request(
            .serverStatus, params: ProjectParams(project: ""), expecting: ServerListResult.self) {
            var signatureHolders: [String: String] = [:]
            var staleProjects: Set<String> = []
            /** Host-keyed signatures miss a real collision: two projects on one
                port under different *.localhost names are different signatures
                and the same bind. Reported from declared ports, so it lands
                before anyone tries to start either one. */
            for collision in PortCollision.detect(
                all.servers.filter { FileManager.default.fileExists(atPath: $0.project) })
            {
                findings.append(
                    Finding(detail: collision.detail, kind: "port-collision", severity: "warning"))
            }
            let livePids = Set(
                all.servers.compactMap { server -> pid_t? in
                    guard let raw = server.pid, let pid = pid_t(exactly: raw), pid > 0 else {
                        return nil
                    }
                    return pid
                })
            let leftover = LaunchdJobs.stale(LaunchdJobs.loadChildJobs(), keepingPids: livePids)
                .sorted { $0.label < $1.label }
            if !leftover.isEmpty {
                let example = leftover[0].label
                findings.append(
                    Finding(
                        detail:
                            "\(leftover.count) leftover directa child job\(leftover.count == 1 ? "" : "s") with no live server (a jetsammed daemon never boots them out). Daemon recovery reaps them; to clear one now: launchctl bootout \(LaunchdJobs.guiDomain)/\(example)",
                        kind: "leftover-job", severity: "warning"))
            }
            if let daemonPid = info.flatMap({ pid_t(exactly: $0.pid) }),
                let daemonJetsam = CoalitionIDs.read(of: daemonPid)?.jetsam
            {
                for server in all.servers {
                    guard let rawPid = server.pid, let childPid = pid_t(exactly: rawPid),
                        let childJetsam = CoalitionIDs.read(of: childPid)?.jetsam,
                        childJetsam == daemonJetsam
                    else { continue }
                    findings.append(
                        Finding(
                            detail:
                                "\(server.server) in \(server.project) shares the daemon's jetsam coalition (pid \(childPid)); under memory pressure macOS may kill the daemon instead of this server",
                            kind: "jetsam-coalition", severity: "warning"))
                }
            }
            for server in all.servers {
                if !FileManager.default.fileExists(atPath: server.project) {
                    staleProjects.insert(server.project)
                    continue
                }
                if let port = server.declaredPort {
                    let host = server.url.flatMap { URL(string: $0)?.host } ?? "localhost"
                    let signature = "\(host):\(port)"
                    let holder = "\(server.server) (\(server.project))"
                    if let existing = signatureHolders[signature] {
                        findings.append(
                            Finding(
                                detail: "signature \(signature) claimed by both \(existing) and \(holder)",
                                kind: "signature-conflict", severity: "warning"))
                    } else {
                        signatureHolders[signature] = holder
                        findings.append(
                            Finding(
                                detail: "\(signature) -> \(holder) [\(server.phase.rawValue)]",
                                kind: "signature", severity: "info"))
                    }
                    /** Only a listener no managed server accounts for is a
                        squatter. When another supervised server is up on this
                        port, calling it unmanaged is simply wrong, and the
                        port-collision finding above already names both sides. */
                    let managedOwner = all.servers.first { other in
                        (other.effectivePort ?? other.declaredPort) == port
                            && !(other.project == server.project && other.server == server.server)
                            && (other.phase == .running || other.phase == .starting
                                || other.phase == .unhealthy)
                    }
                    if server.phase == .stopped || server.phase == .crashed,
                        managedOwner == nil,
                        LoopbackProbe.isListening(port: port) {
                        findings.append(
                            Finding(
                                detail: "port \(port) has an unmanaged listener while \(server.server) is down",
                                kind: "port-squatter", severity: "warning"))
                    }
                }
            }
            for project in staleProjects.sorted() {
                if fix {
                    let names = all.servers.filter { $0.project == project }.map(\.server)
                    for name in names {
                        _ = try? await client.request(
                            .serverUnregister,
                            params: ServerTargetParams(name: name, project: project),
                            expecting: WireEmpty.self)
                    }
                    findings.append(
                        Finding(detail: "pruned \(project) (\(names.count) servers)", kind: "stale-project", severity: "fixed"))
                } else {
                    findings.append(
                        Finding(
                            detail:
                                "\(project) no longer exists on disk (daemon auto-prunes missing projects; doctor --fix forces leftovers)",
                            kind: "stale-project", severity: "warning"))
                }
            }
        }
        /** Update check: read the shared cache, refreshing only when stale, so a
            machine where the menu bar app never runs still learns about a release
            without doctor hitting the network every time. Silent on failure. */
        if let update = await UpdateCheck.refreshIfStale(), update.updateAvailable {
            findings.append(
                Finding(
                    detail:
                        "directa \(update.latestVersion) is available (you have \(update.currentVersion)); upgrade with `brew upgrade --cask \(DirectaDistribution.homebrewCaskToken)` or download from \(DirectaDistribution.releasesLatestURL)",
                    kind: "update", severity: "info"))
        }

        /** Harness hooks: report only, never repair. directa does not edit a file
            the user owns, so a drifted hook is surfaced with the exact command to
            fix it and nothing more. */
        for adapter in harnessAdapters {
            switch adapter.hookState() {
            case .harnessAbsent:
                break
            case .installed(let path, let pathExists):
                if pathExists {
                    findings.append(
                        Finding(
                            detail: "\(adapter.name) session hook installed (\(path))",
                            kind: "harness-hook", severity: "ok"))
                } else {
                    findings.append(
                        Finding(
                            detail:
                                "\(adapter.name) session hook points at \(path), which no longer exists (run: directa hook install --harness \(adapter.name), or directa hook uninstall --harness \(adapter.name))",
                            kind: "harness-hook", severity: "warning"))
                }
            case .notInstalled:
                findings.append(
                    Finding(
                        detail:
                            "\(adapter.name) detected without a directa session hook (run: directa hook install --harness \(adapter.name))",
                        kind: "harness-hook", severity: "info"))
            }
        }
        /** Shadowed install: a second directa copy (a `make install` in
            ~/.local/bin, or a foreign /Applications app Homebrew could not
            replace) shadowing the Homebrew one, so a bare `directa` or the daemon
            can keep running an old version after an upgrade. Report-only, with
            the exact cleanup command. */
        for shadow in InstallShadow.scan() {
            findings.append(
                Finding(
                    detail: "\(shadow.detail) (run: \(shadow.remedy))",
                    kind: "install-shadow", severity: "warning"))
        }
        if global.json {
            struct Report: Codable {
                var findings: [Finding]
            }
            CLIRunner.emit(Report(findings: findings), json: true) { _ in "" }
        } else {
            for finding in findings {
                print("[\(finding.severity)] \(finding.kind): \(finding.detail)")
            }
        }
        if findings.contains(where: { $0.severity == "error" }) {
            Foundation.exit(1)
        }
    }
}

/** The one uninstall verb. Stops nothing that is running: the daemon shuts down
    and its children survive it. Removes the background agent and Start at Login,
    then agent hooks, then the CLI/daemon binaries directa itself installed, and
    a non-Homebrew `/Applications/directa.app`. Data is kept unless `--purge`.
    `--agent-only` stops after the agent, which is what the Homebrew cask calls
    on every upgrade, so it must never touch hooks, login, or user data. */
struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            "Remove directa: unregister the agent and Start at Login, remove hooks and the CLI (running servers keep going; data kept unless --purge).")

    @Flag(help: "Only unregister the background agent; leave hooks, CLI, and data in place.")
    var agentOnly = false

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Also delete directa's data and logs.")
    var purge = false

    struct UninstallResult: Codable {
        var actions: [String]
        var agentOnly: Bool
        var purged: Bool
    }

    func run() async throws {
        let paths = DirectaPaths()
        var actions: [String] = []

        /** Agent + launchd job (and any legacy home plist) first. Full uninstall
            also drops Start at Login. Data purge is last so a failed earlier
            step cannot leave launch items behind while erasing state. */
        await LaunchdAdmin.uninstall(loginItem: !agentOnly, paths: paths, purge: false)
        actions.append("unregistered the background agent")
        if !agentOnly { actions.append("unregistered Start at Login") }

        if !agentOnly {
            for adapter in harnessAdapters {
                if let summary = try? adapter.uninstall() { actions.append(summary) }
            }
            /** Only the copies directa installed, at `~/.local/bin`. A Homebrew
                install keeps its CLI in brew's bin under brew's ownership, so
                these paths simply do not exist there and this is a no-op; the
                cask's own uninstall removes brew's symlink. */
            for url in [SetupPlanner.installedCLIURL(), SetupPlanner.installedDaemonSiblingURL()]
            where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                actions.append("removed \(url.path)")
            }
            /** Homebrew owns `/Applications/directa.app`; a DMG/source install
                does not, and leaving the bundle keeps Launch Services and BTM
                pointing at a still-installed app. */
            if let owner = SetupPlanner.applicationsAppOwner(), !owner.isHomebrew {
                let app = LaunchdAdmin.applicationsAppURL
                try? FileManager.default.trashItem(at: app, resultingItemURL: nil)
                if !FileManager.default.fileExists(atPath: app.path) {
                    actions.append("moved \(SetupPlanner.applicationsAppPath) to the Trash")
                }
            }
        }

        if purge && !agentOnly {
            try? FileManager.default.removeItem(at: paths.dataDir)
            try? FileManager.default.removeItem(at: paths.logsDir)
            for url in DirectaPaths.userLibraryResidue() {
                try? FileManager.default.removeItem(at: url)
            }
            actions.append("removed data, logs, preferences, and caches")
        }

        let result = UninstallResult(actions: actions, agentOnly: agentOnly, purged: purge && !agentOnly)
        CLIRunner.emit(result, json: global.json) { r in r.actions.joined(separator: "\n") }
    }
}

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Daemon management.",
        subcommands: [
            DaemonInfoCommand.self, DaemonInstall.self, DaemonRestart.self, DaemonStart.self,
            DaemonStatusCommand.self, DaemonStop.self, DaemonUninstall.self,
        ]
    )
}

struct DaemonInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "Install (or upgrade) the launchd agent and start the daemon.")

    @Option(help: "Path to the ddirecta binary; defaults to the one alongside this directa.")
    var ddirecta: String?

    @Flag(
        help:
            "Force the home LaunchAgent path even when /Applications/directa.app is present (CLI-only / smoke)."
    )
    var legacy = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let binary = ddirecta.map { URL(fileURLWithPath: $0) }
            ?? LaunchdAdmin.resolveDaemonBinary(extraCandidates: [CLISelf.daemonSibling])
        guard let binary else {
            CLIRunner.fail(
                WireError(
                    code: .usage,
                    hint: "run: directa daemon install --ddirecta /path/to/ddirecta",
                    message: "cannot find a ddirecta binary next to directa"),
                json: global.json)
        }
        let restored: [(project: String, name: String)]
        do {
            restored = try await LaunchdAdmin.install(
                daemonBinary: binary, paths: DirectaPaths(), forceLegacy: legacy)
        } catch let error as WireError {
            CLIRunner.fail(error, json: global.json)
        }
        let viaApp = !legacy && LaunchdAdmin.applicationsAppPresent()
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in
            if restored.isEmpty {
                viaApp
                    ? "ddirecta ensured via \(SetupPlanner.applicationsAppPath) (Login Items)"
                    : "ddirecta installed and running (\(LaunchdAdmin.label))"
            } else {
                "ddirecta installed; re-ensured \(restored.map(\.name).joined(separator: ", "))"
            }
        }
    }
}

/** Deprecated alias for `directa uninstall --agent-only` (plus `--purge` for data).
    Kept working because the CLI JSON contract is a public surface; the notice
    goes to stderr so `--json` stdout stays clean for agents parsing it. */
struct DaemonUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall", abstract: "Deprecated: use `directa uninstall`.")

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Also delete all directa data and logs.")
    var purge = false

    func run() async throws {
        FileHandle.standardError.write(
            Data(
                "directa: `directa daemon uninstall` is deprecated; use `directa uninstall` (or `directa uninstall --agent-only` to remove just the agent)\n"
                    .utf8))
        await LaunchdAdmin.uninstall(paths: DirectaPaths(), purge: purge)
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in
            purge ? "ddirecta uninstalled; data and logs removed" : "ddirecta uninstalled"
        }
    }
}

struct DaemonStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start", abstract: "Start a stopped daemon (clears the deliberate-stop marker).")

    @Flag(
        help:
            "Force the home LaunchAgent path even when /Applications/directa.app is present."
    )
    var legacy = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        do {
            try await LaunchdAdmin.startOrInstall(
                paths: DirectaPaths(),
                extraDaemonCandidates: [CLISelf.daemonSibling],
                forceLegacy: legacy)
        } catch let error as WireError {
            CLIRunner.fail(error, json: global.json)
        }
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in "ddirecta running" }
    }
}

struct DaemonStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Drain all servers and stop the daemon until asked to start.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let client = CLIRunner.client()
        _ = try? await client.request(.daemonShutdown, params: WireEmpty(), expecting: WireEmpty.self)
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in
            "ddirecta stopping (servers drained; directa daemon start to bring it back)"
        }
    }
}

struct DaemonRestart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Drain, relaunch the daemon, and re-ensure the servers that were running.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let bounced: [(project: String, name: String)]
        do {
            bounced = try await LaunchdAdmin.restart(paths: DirectaPaths())
        } catch let error as WireError {
            CLIRunner.fail(error, json: global.json)
        }
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in
            bounced.isEmpty
                ? "ddirecta restarted (no servers were running)"
                : "ddirecta restarted; re-ensured \(bounced.map(\.name).joined(separator: ", "))"
        }
    }
}

struct DaemonStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "launchd state plus live daemon identity.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let launchdLine = LaunchdAdmin.launchdState()
        let client = CLIRunner.client()
        let info = try? await client.request(.daemonInfo, params: WireEmpty(), expecting: DaemonInfo.self)
        if global.json {
            struct StatusPayload: Codable {
                var daemon: DaemonInfo?
                var launchd: String
                /** Stated outright because every other command's hint sends the
                    reader here, and the answer has to be readable by a machine.
                    Without it the only signal is an absent `daemon` key next to
                    a reassuring launchd line, which reads as healthy: launchd
                    reporting `running` says a job is loaded, not that anything
                    is accepting on the socket. */
                var reachable: Bool
            }
            CLIRunner.emit(
                StatusPayload(daemon: info, launchd: launchdLine, reachable: info != nil),
                json: true
            ) { _ in "" }
        } else if let info {
            /** Called out rather than folded into the version line, because the
                whole reason to ask is to tell a daemon that is coming back from
                one that is gone, and the two used to be one answer. */
            let phase = info.restoring == true ? " (restoring supervised servers)" : ""
            print(
                "launchd: \(launchdLine)\ndaemon: v\(info.daemonVersion) pid \(info.pid) on \(info.socketPath)\(phase)")
        } else {
            print("launchd: \(launchdLine)\ndaemon: not responding")
        }
    }
}

struct DaemonInfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info", abstract: "Daemon identity and paths.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.daemonInfo, params: WireEmpty(), expecting: DaemonInfo.self)
        }
        CLIRunner.emit(result, json: global.json) { info in
            "ddirecta v\(info.daemonVersion) (proto \(info.proto)) pid \(info.pid)\nsocket \(info.socketPath)\ndata \(info.dataDir)\nlogs \(info.logsDir)"
        }
    }
}

/** Branch switching with the project's own lifecycle playbook: stop the
    servers, move the checkout, run the configured commands (install, seed,
    codegen), bring everything back healthy. The tree must be clean: directa
    never stashes or discards work. */
struct Switch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Switch the project to a branch, run its lifecycle commands, and bring servers back up.")

    @Argument(help: "Branch name (created from the matching remote branch when needed).")
    var branch: String

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Skip the git fetch before switching.")
    var noFetch = false

    @Option(help: "Per-server seconds to wait for health when coming back up.")
    var timeout: Double = 120

    func run() async throws {
        let project = global.resolvedProject()
        let dirty = Self.git(["status", "--porcelain"], in: project)
        guard dirty.status == 0 else {
            CLIRunner.fail(
                WireError(code: .internalError, message: "git status failed: \(dirty.output)"),
                json: global.json)
        }
        guard dirty.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            CLIRunner.fail(
                WireError(
                    code: .usage,
                    hint: "commit your work first (directa never stashes or discards changes)",
                    message: "the working tree has uncommitted changes"),
                json: global.json)
        }
        if !noFetch {
            print("fetching…")
            _ = Self.git(["fetch", "origin", "--prune"], in: project)
        }
        print("stopping servers…")
        _ = try? await CLIRunner.client().request(
            .groupDown, params: GroupParams(project: project), expecting: GroupResult.self,
            operationTimeoutSeconds: 120)
        var switched = Self.git(["switch", branch], in: project)
        if switched.status != 0 {
            /** A remote-only branch needs a tracking checkout. */
            switched = Self.git(["switch", "--track", "origin/\(branch)"], in: project)
        }
        guard switched.status == 0 else {
            CLIRunner.fail(
                WireError(
                    code: .internalError,
                    hint: "run: git -C \(project) switch \(branch)",
                    message: "git switch failed: \(switched.output.trimmingCharacters(in: .whitespacesAndNewlines))"),
                json: global.json)
        }
        print("on \(branch)")
        /** The lifecycle commands about to run come from the NEW branch's
            devservers.json, so validate that file after the checkout, not before.
            A config the daemon would refuse to load must not have its committed
            argv executed: the previous shape discarded the validated view and
            re-decoded the raw file, running lifecycle from a config `config
            check` would reject. */
        let validated: ProjectConfigView?
        do {
            validated = try ProjectConfigLoader.load(project: project)
        } catch let error as WireError {
            CLIRunner.fail(error, json: global.json)
        }
        if let view = validated, !view.errors.isEmpty {
            CLIRunner.fail(
                WireError(
                    code: .configInvalid,
                    hint: "run: directa config check",
                    message: "the branch's devservers.json is invalid, so its lifecycle was not run: \(view.errors.joined(separator: "; "))"),
                json: global.json)
        }
        /** The explicit invocation is the approval, the same bargain an explicit
            ensure makes. Recording it before the lifecycle runs keeps the state
            coherent from the moment the branch's committed argv executes, so a
            crash mid-switch still leaves the project approved for a later
            autonomous boot restore rather than half-trusted. */
        do {
            try await CLIRunner.client().request(
                .projectTrust, params: ProjectOnlyParams(project: project),
                expecting: WireEmpty.self)
        } catch {
            print(
                "warning: trust was not recorded for this project (\(error)); run: directa trust")
        }
        let playbook =
            validated == nil
            ? []
            : (try? JSONCoding.decoder().decode(
                ProjectFileConfig.self,
                from: Data(contentsOf: ProjectConfigLoader.configURL(project: project))))?
                .lifecycle?["switch"] ?? []
        for argv in playbook {
            guard let executable = argv.first else { continue }
            print("lifecycle: \(argv.joined(separator: " "))")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
            process.currentDirectoryURL = URL(fileURLWithPath: project)
            do {
                try process.run()
            } catch {
                CLIRunner.fail(
                    WireError(
                        code: .spawnFailed,
                        message: "cannot run lifecycle command '\(executable)': \(error)"),
                    json: global.json)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                CLIRunner.fail(
                    WireError(
                        code: .internalError,
                        hint: "fix the failure, then: directa up",
                        message: "lifecycle command failed (\(process.terminationStatus)): \(argv.joined(separator: " "))"),
                    json: global.json)
            }
        }
        print("bringing servers up…")
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(
                .groupUp,
                params: GroupParams(project: project, timeoutSeconds: timeout),
                expecting: GroupResult.self,
                operationTimeoutSeconds: timeout)
        }
        CLIRunner.emit(result, json: global.json) { r in
            r.results.isEmpty
                ? "switched to \(branch) (no servers registered)"
                : r.results.map { entry in
                    entry.reason.map { "\(CLIRunner.describe(entry.server))  ·  FELL SHORT (\($0.rawValue))" }
                        ?? CLIRunner.describe(entry.server)
                }.joined(separator: "\n")
        }
        if result.results.contains(where: { $0.reason != nil }) {
            Foundation.exit(1)
        }
    }

    static func git(_ arguments: [String], in project: String) -> (status: Int32, output: String) {
        LaunchdAdmin.shell("/usr/bin/git", ["-C", project] + arguments)
    }
}

/** The acquire wait as a decision rather than a loop condition, so a zero budget
    still makes one attempt. `while Date() < deadline` never entered its body at
    budget 0, which produced a generic failure naming no holder. */
struct LockAcquireSchedule: Equatable, Sendable {
    static let announceIntervalSeconds: Double = 15
    static let retryIntervalSeconds: Double = 1
    var budgetSeconds: Double

    func shouldRetry(afterElapsed elapsed: Double) -> Bool {
        elapsed < budgetSeconds
    }

    func shouldAnnounceStillWaiting(atElapsed elapsed: Double, lastAnnouncedElapsed: Double?)
        -> Bool
    {
        guard let last = lastAnnouncedElapsed else { return false }
        return elapsed - last >= Self.announceIntervalSeconds
    }
}

/** Everything a contended acquire says, pure so the exact wording is asserted.
    Silence here is what made a waiting run look hung, and the reflex that
    invites is killing whichever run holds the lock, which is the one making
    progress. Every line goes to stderr: stdout belongs to the guarded command. */
enum LockNotice {
    static func contended(
        budgetSeconds: Double, holder: LockHolder, now: Date, resource: String
    ) -> String {
        let age = DurationText.brief(seconds: now.timeIntervalSince(holder.since))
        var lines = [
            "directa lock: '\(resource)' is held by pid \(holder.pid), running for \(age)\(pauseClause(holder))."
        ]
        lines.append(
            "directa lock: waiting up to \(DurationText.brief(seconds: budgetSeconds)) for that run to finish. It is the one making progress, so check it with `ps -p \(holder.pid)` before killing anything."
        )
        return lines.joined(separator: "\n")
    }

    static func stillWaiting(
        elapsedSeconds: Double, holder: LockHolder, remainingSeconds: Double, resource: String
    ) -> String {
        "directa lock: still waiting on '\(resource)' (pid \(holder.pid)), \(DurationText.brief(seconds: elapsedSeconds)) elapsed, \(DurationText.brief(seconds: remainingSeconds)) left."
    }

    /** A default hold leaves declarers running, and the fingerprint guard is the
        substitute for the pause that used to stop them. That guard needs a
        declared state `path`; a bare-named lock has none, so a change made while
        a live server holds the state open cannot be detected. Say the guard is
        off rather than leave the exposure silent. Nil when there is nothing to
        protect: no live declarer, or a path to fingerprint (`--pause` empties
        `live`, so the safe path never nags). */
    static func unguarded(resource: String, live: [String], statePath: String?) -> String? {
        guard statePath == nil, !live.isEmpty else { return nil }
        let servers = live.sorted()
        return
            "directa lock: note: '\(resource)' declares no state path, so a change made while \(servers.joined(separator: ", ")) \(servers.count == 1 ? "stays" : "stay") running cannot be detected. Add a `path` to the lock declaration or use --pause."
    }

    private static func pauseClause(_ holder: LockHolder) -> String {
        if holder.pause == false {
            guard let live = holder.live, !live.isEmpty else {
                /** The default hold with nothing running is not "it left servers up". */
                return " (nothing was running to leave up)"
            }
            return " (it left \(live.joined(separator: ", ")) running)"
        }
        guard !holder.paused.isEmpty else { return " (nothing was running to pause)" }
        return " (it paused \(holder.paused.joined(separator: ", ")))"
    }
}

/** What the identity check concluded about the locked state.

    What it cannot catch, stated so nobody over-reads it: it flags the risk
    window, not the damage, because the incident's corruption landed when the
    still-running server flushed its cached pages after the command had already
    finished. It cannot see state outside the declared path (a sibling `-wal`
    file when `path` names only the `.sqlite`), divergence that never reaches
    disk, or a change that reverts to byte-identical state inside the window. A
    directory stops hashing contents past a byte budget, so a change confined to
    a file beyond it is missed; a single file is hashed whole at any size. It
    never names which process wrote. */
enum LockIdentityVerdict: Equatable {
    case fault(WireError)
    case note(String)
    case silent

    /** A declarer left running (the default) holds the old file open, so any
        change to the locked state during the hold is not durable whatever the
        command reported. Under `--pause`, with the declarers stopped, the same
        change is the entire point, so it is a note. */
    static func of(
        after: ResourceIdentity, before: ResourceIdentity, live: [String], resource: String,
        statePath: String
    ) -> LockIdentityVerdict {
        let change = ResourceFingerprint.compare(after: after, before: before)
        guard change != .unchanged else {
            /** "Unchanged" from a partial fingerprint is "nothing I could see
                changed", which is a different answer and the one worth saying.
                An unreadable file digests to the same empty string on both
                captures, and a directory past its byte budget hashes only names
                and sizes, so silence here would report a clean bill of health
                the check never actually established. */
            guard after.exact, before.exact else {
                return .note(
                    "directa lock: note: '\(resource)' state at \(statePath) could not be fingerprinted in full, so a change confined to the unread part would not have been reported."
                )
            }
            return .silent
        }
        let described = describe(change)
        guard !live.isEmpty else {
            return .note(
                "directa lock: note: '\(resource)' state at \(statePath) changed during this hold (\(described)). Nothing was running against it."
            )
        }
        let servers = live.sorted()
        return .fault(
            WireError(
                code: .resourceMutated,
                hint: "directa lock \(resource) --pause -- <command>",
                message:
                    "resource '\(resource)' state at \(statePath) changed (\(described)) while \(servers.joined(separator: ", ")) stayed running. \(servers.count == 1 ? "That server holds" : "Those servers hold") the old state open and can write cached pages back over the change, so what is on disk is not what the command wrote."
            ))
    }

    private static func describe(_ change: ResourceChange) -> String {
        switch change {
        case .appeared:
            return "it was created"
        case .changed(.content):
            return "its contents differ"
        case .changed(.inode):
            return "it was replaced"
        case .changed(.kind):
            return "it changed kind"
        case .changed(.size):
            return "its size changed"
        case .disappeared:
            return "it was removed"
        case .unchanged:
            return "unchanged"
        }
    }
}

/** Compact human durations. Nothing else in the CLI formats one. */
enum DurationText {
    static func brief(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(max(total, 0))s" }
        let minutes = total / 60
        guard minutes >= 60 else { return String(format: "%dm %02ds", minutes, total % 60) }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
}

/** Runs a command while holding a named resource exclusively. By default the
    servers that declare the resource keep running: the mutex serializes access
    against other holders and a fingerprint guard flags a live server corrupting
    the state. `--pause` stops those declarers for the command and re-ensures
    them on release, for state a running server holds open (a local database). */
struct Lock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command holding a project resource exclusively; declaring servers stay up unless --pause.")

    @OptionGroup var global: GlobalOptions

    /** Declaration order is load-bearing for the help synopsis only: the
        repeating positional has to come last, and the options render in
        declaration order, which is what makes `--help` match the contract. It has
        no bearing on parsing, since `.postTerminator` lifts everything after `--`
        before any positional is filled. */
    @Argument(help: "Resource name (matches servers' `locks` in devservers.json).")
    var resource: String

    @Option(help: "Seconds to wait for the resource if another holder has it.")
    var acquireTimeout: Double = 300

    /** Explicit opt-in to stopping declarers; the default leaves them running.
        A bare `@Flag` (default false), not an inversion pair, so there is exactly
        one spelling and no `--no-pause` that does nothing. */
    @Flag(name: .customLong("pause"), help: "Stop servers that declare the resource for the command, then resume them.")
    var pause = false

    @Option(help: "Per-server seconds to wait for health when servers return.")
    var timeout: Double = 120

    /** `.postTerminator`, not `.captureForPassthrough`: the latter ends option
        parsing at the first positional value, so the resource itself stopped it
        and `--timeout 300` joined the guarded command, which then ran as
        `env --timeout 300 -- cmd`. This strategy lifts everything after `--`
        verbatim (a nested `--`, a dash option, an empty string all survive) and
        leaves the options to parse normally. The default makes a missing command
        reach the typed usage error below rather than the parser's own printer. */
    @Argument(parsing: .postTerminator, help: "Command to run while holding the resource; everything after `--`.")
    var command: [String] = []

    /** Pure so the exact message is asserted without spawning the CLI. */
    static func usageError(command: [String], resource: String) -> WireError? {
        guard command.isEmpty else { return nil }
        return WireError(
            code: .usage,
            hint: "directa lock \(resource) -- <command>",
            message: "directa lock needs a command after `--`; its own options go before it (directa lock \(resource) [--pause] [--acquire-timeout <seconds>] [--timeout <seconds>] -- <command…>)")
    }

    func run() async throws {
        let command = command
        let pause = pause
        if let usage = Self.usageError(command: command, resource: resource) {
            CLIRunner.fail(usage, json: global.json)
        }
        let project = global.resolvedProject()
        let holderPid = Int(getpid())
        let client = CLIRunner.client()
        /** Acquire with patience: another harness may hold it. The daemon owns
            pause/resume of declaring servers; this CLI just runs the command. */
        let schedule = LockAcquireSchedule(budgetSeconds: acquireTimeout)
        let started = Date()
        var acquired: LockResult?
        var announcedAt: Double?
        var lastError: WireError?
        repeat {
            do {
                acquired = try await client.request(
                    .lockAcquire,
                    params: LockParams(
                        holderPid: holderPid, pause: pause, project: project, resource: resource,
                        resumeTimeoutSeconds: timeout),
                    expecting: LockResult.self)
                break
            } catch let error as WireError where error.code == .resourceLocked {
                lastError = error
                let elapsed = Date().timeIntervalSince(started)
                /** Only look the holder up when there is something to say. The
                    notice fires once on first contention and then on an interval,
                    so querying every retry would spend hundreds of round trips
                    over a long wait to print nothing. */
                let first = announcedAt == nil
                let due =
                    first
                    || schedule.shouldAnnounceStillWaiting(
                        atElapsed: elapsed, lastAnnouncedElapsed: announcedAt)
                if due {
                    /** An older daemon without lock.status degrades to silence
                        here rather than failing the acquire. */
                    let holder = try? await client.request(
                        .lockStatus,
                        params: LockStatusParams(project: project, resource: resource),
                        expecting: LockStatusResult.self
                    ).holder
                    if let holder {
                        Self.note(
                            first
                                ? LockNotice.contended(
                                    budgetSeconds: acquireTimeout, holder: holder, now: Date(),
                                    resource: resource)
                                : LockNotice.stillWaiting(
                                    elapsedSeconds: elapsed, holder: holder,
                                    remainingSeconds: max(acquireTimeout - elapsed, 0),
                                    resource: resource))
                        announcedAt = elapsed
                    }
                }
                guard schedule.shouldRetry(afterElapsed: elapsed) else { break }
                try? await Task.sleep(for: .seconds(LockAcquireSchedule.retryIntervalSeconds))
            }
        } while schedule.shouldRetry(afterElapsed: Date().timeIntervalSince(started))
        guard let acquired else {
            CLIRunner.fail(
                lastError ?? WireError(code: .resourceLocked, message: "could not acquire '\(resource)'"),
                json: global.json)
        }
        /** Progress chatter is stderr: stdout belongs to the guarded command, and
            --json governs stdout schemas. */
        for name in acquired.paused {
            Self.note("directa lock: paused \(name) (holds \(resource))")
        }
        if let warning = LockNotice.unguarded(
            resource: resource, live: acquired.live ?? [], statePath: acquired.statePath)
        {
            Self.note(warning)
        }
        /** Identity is taken before the command and again before release, so a
            resumed server's first writes are never blamed on the command. */
        let before = acquired.statePath.map(ResourceFingerprint.capture(path:))
        /** Run the guarded command with inherited stdio. */
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = URL(fileURLWithPath: project)
        var commandStatus: Int32 = 1
        do {
            try process.run()
            process.waitUntilExit()
            commandStatus = process.terminationStatus
        } catch {
            FileHandle.standardError.write(Data("directa lock: cannot run command: \(error)\n".utf8))
        }
        var verdict = LockIdentityVerdict.silent
        if let statePath = acquired.statePath, let before {
            verdict = LockIdentityVerdict.of(
                after: ResourceFingerprint.capture(path: statePath), before: before,
                live: acquired.live ?? [], resource: resource, statePath: statePath)
        }
        /** Release resumes whoever was paused, even if the command failed. */
        let released = (try? await client.request(
            .lockRelease,
            params: LockParams(
                holderPid: holderPid, project: project, resource: resource,
                resumeTimeoutSeconds: timeout),
            expecting: LockResult.self)) ?? LockResult()
        for name in released.paused {
            Self.note("directa lock: resuming \(name)…")
        }
        switch verdict {
        case .fault(let error):
            /** A failing command keeps its own status: never swallow that. A
                clean command that silently lost its work exits 1. */
            CLIRunner.emitFailure(error, json: global.json)
            Foundation.exit(commandStatus == 0 ? 1 : commandStatus)
        case .note(let text):
            Self.note(text)
        case .silent:
            break
        }
        Foundation.exit(commandStatus)
    }

    static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
