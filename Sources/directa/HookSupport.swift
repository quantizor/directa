import DirectaKit
import Foundation

/** Absolute path of this running `directa` binary. Prefer over
    CommandLine.arguments[0], which is often a bare PATH name and would resolve
    relative to cwd (breaking `hook install` when invoked as `directa` from a
    project directory). */
enum CLISelf {
    static var path: String {
        if let raw = mainExecutablePath() {
            return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        }
        return fallbackPath()
    }

    /** The ddirecta that shipped alongside this directa; the preferred install
        source because it is version-matched to this binary. */
    static var daemonSibling: URL {
        URL(fileURLWithPath: path).deletingLastPathComponent().appending(path: "ddirecta")
    }

    /** The running binary's image path from `Bundle.main.executableURL` (the
        kernel image, not argv[0]); the `path` accessor resolves any symlink. Nil
        only when the bundle has no executable URL, when `fallbackPath` takes over. */
    private static func mainExecutablePath() -> String? {
        Bundle.main.executableURL?.path
    }

    /** Last resort when dyld refuses: absolute arg0, else first PATH hit. */
    private static func fallbackPath() -> String {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") {
            return URL(fileURLWithPath: arg0).resolvingSymlinksInPath().path
        }
        let name = URL(fileURLWithPath: arg0).lastPathComponent
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: String(dir)).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.resolvingSymlinksInPath().path
            }
        }
        return URL(fileURLWithPath: arg0).resolvingSymlinksInPath().path
    }
}

/** Fetches the trusted project's server list over the socket and hands it to the
    pure renderer in DirectaKit (AgentContext.render). Kept thin and side-effect
    free: a session start must stay fast, must never bootstrap the daemon, and
    stays silent when the daemon is unreachable. */
enum HookContext {
    static func status(project: String) async -> ServerListResult? {
        let client = CLIRunner.client()
        return try? await client.request(
            .serverStatus, params: ProjectParams(project: project), expecting: ServerListResult.self)
    }

    static func render(project: String, harness: AgentContext.Harness) async -> String? {
        guard let list = await status(project: project) else { return nil }
        return AgentContext.render(list: list, harness: harness)
    }

    /** Nil when the log read itself failed. An empty array is a real tail. */
    static func errorLines(project: String, server: String) async -> [String]? {
        let client = CLIRunner.client()
        let params = LogsQueryParams(
            name: server, project: project, streams: [.err], tail: HookErrorText.lineLimit)
        guard
            let result = try? await client.request(
                .logsQuery, params: params, expecting: LogsQueryResult.self)
        else { return nil }
        return result.lines.map(\.text)
    }
}

/** Asks the daemon, compares the picture, and stores it. `boundary` is read
    from the record already on disk. `amend` may update harness fields on that
    record before it is saved, including when the picture did not change.
    A failed status read stores nothing and writes an empty answer. */
enum HookSpeak {
    struct Answer: Equatable {
        var newErrorLines: Bool
        var text: String?
    }

    static func deliver(
        project: String,
        harness: AgentContext.Harness,
        fileKey: String,
        environment: [String: String],
        boundary: (HookConversationRecord?) -> Bool,
        amend: ((inout HookConversationRecord, Answer, Bool) -> Void)? = nil,
        write: (Answer) -> Void
    ) async {
        let directory = HookSnapshotStore.directory(environment: environment)
        let stored = HookSnapshotStore.load(fileKey: fileKey, directory: directory)
        let isBoundary = boundary(stored)
        guard let list = await HookContext.status(project: project) else {
            write(Answer(newErrorLines: false, text: nil))
            return
        }
        let lines = await errorLines(project: project, list: list, stored: stored, boundary: isBoundary)
        let picture = HookChange.picture(of: list.servers, errorLines: lines)
        let outcome = HookChange.outcome(
            stored: stored, picture: picture,
            summary: AgentContext.render(list: list, harness: harness), boundary: isBoundary)
        var record = outcome.record
        let answer = Answer(newErrorLines: outcome.newErrorLines, text: outcome.text)
        amend?(&record, answer, isBoundary)
        if record != stored {
            HookSnapshotStore.save(record, fileKey: fileKey, directory: directory)
        }
        write(answer)
    }

    private static func errorLines(
        project: String, list: ServerListResult, stored: HookConversationRecord?, boundary: Bool
    ) async -> [String: [String]] {
        var lines: [String: [String]] = [:]
        if boundary || list.trusted != true {
            for server in list.servers {
                if let previous = stored?.picture.row(server.server)?.errorLines {
                    lines[server.server] = previous
                }
            }
            return lines
        }
        let needed = Set(
            HookChange.serversNeedingErrorLines(stored: stored?.picture, servers: list.servers))
        for server in list.servers {
            if needed.contains(server.server) {
                if let fetched = await HookContext.errorLines(project: project, server: server.server) {
                    lines[server.server] = fetched
                } else if let previous = stored?.picture.row(server.server)?.errorLines {
                    lines[server.server] = previous
                }
            } else if let previous = stored?.picture.row(server.server)?.errorLines {
                lines[server.server] = previous
            }
        }
        return lines
    }
}

/** What one `hook install` or `hook uninstall` pass over several harnesses
    did. The pass collects rather than aborts: a refusal from one harness must
    not discard the others' work, since their files are already rewritten by
    the time it lands, so every adapter runs and the report names both what
    succeeded and what failed. */
struct HarnessBatchResult {
    struct Failure: Equatable {
        var message: String
        var name: String
    }

    var failures: [Failure] = []
    /** Names of the adapters whose action returned, in order. */
    var succeeded: [String] = []
    var summaries: [String] = []

    /** The failure the command exits with when any adapter failed, or nil. */
    func failure(verb: HarnessBatch.Verb) -> WireError? {
        guard !failures.isEmpty else { return nil }
        var message = "hook \(verb.rawValue) finished with errors"
        if !succeeded.isEmpty {
            message += "; \(verb.pastTense) \(succeeded.joined(separator: ", "))"
        }
        message +=
            ". Failed: " + failures.map { "\($0.name) (\($0.message))" }.joined(separator: "; ")
        message += " Fix each cause and rerun directa hook \(verb.rawValue)."
        return WireError(code: .internalError, hint: "run: directa hook \(verb.rawValue)", message: message)
    }
}

/** The pieces `hook install` and `hook uninstall` share. */
enum HarnessBatch {
    enum Verb: String {
        case install
        case uninstall

        /** How the failure report names what succeeded ("installed claude"). */
        var pastTense: String {
            switch self {
            case .install: "installed"
            case .uninstall: "removed from"
            }
        }
    }

    /** The adapter an explicit `--harness` names, or the usage error listing
        the supported names. */
    static func adapter(
        named name: String, in adapters: [any HarnessAdapter], verb: Verb
    ) -> Result<any HarnessAdapter, WireError> {
        if let adapter = adapters.first(where: { $0.name == name }) { return .success(adapter) }
        let supported = adapters.map(\.name).joined(separator: ", ")
        let guide = verb == .install ? "; adding one: CONTRIBUTING.md" : ""
        return .failure(
            WireError(
                code: .usage,
                hint: "run: directa hook \(verb.rawValue) --harness <name>",
                message: "unknown harness '\(name)' (supported: \(supported)\(guide))"))
    }

    /** Runs `action` on every adapter, collecting each summary or failure. */
    static func run(
        _ adapters: [any HarnessAdapter], _ action: (any HarnessAdapter) throws -> String
    ) -> HarnessBatchResult {
        var result = HarnessBatchResult()
        for adapter in adapters {
            do {
                result.summaries.append(try action(adapter))
                result.succeeded.append(adapter.name)
            } catch let error as WireError {
                result.failures.append(HarnessBatchResult.Failure(message: error.message, name: adapter.name))
            } catch {
                result.failures.append(
                    HarnessBatchResult.Failure(message: String(describing: error), name: adapter.name))
            }
        }
        return result
    }
}
