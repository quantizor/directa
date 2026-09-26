import Foundation

/** Side effects a resolved deep link needs but that live outside the daemon
    protocol: opening a browser, writing the pasteboard, posting a notification.
    The app supplies AppKit/UserNotifications implementations; tests supply a
    recorder. */
public protocol DeepLinkEffects: Sendable {
    func copyToPasteboard(_ text: String) async
    func notify(title: String, body: String) async
    func openBrowser(_ url: URL) async
}

/** The outcome of running a deep link: the verb that ran, the project path the
    slug resolved to, and a short human detail (the resulting phase, the opened
    URL, or the diagnosed root cause). */
public struct DeepLinkRunResult: Sendable, Equatable, Codable {
    public var detail: String?
    public var projectPath: String
    public var verb: DeepLinkVerb

    public init(verb: DeepLinkVerb, projectPath: String, detail: String? = nil) {
        self.detail = detail
        self.projectPath = projectPath
        self.verb = verb
    }
}

/** The daemon calls the runner needs, one per verb. `DaemonClient` conforms via
    its generic `request`; a test conforms a mock. Kept internal: the public
    `DeepLinkRunner.init` still takes a concrete `DaemonClient`, and the seam only
    exists so the runner's branching is testable without a live socket. */
protocol DeepLinkDaemon: Sendable {
    func ensure(_ params: EnsureParams) async throws -> EnsureResult
    func statusList(project: String, name: String?) async throws -> ServerListResult
    func stop(_ target: ServerTargetParams) async throws -> ServerResult
    func why(_ target: ServerTargetParams) async throws -> WhyResult
}

extension DaemonClient: DeepLinkDaemon {
    func ensure(_ params: EnsureParams) async throws -> EnsureResult {
        try request(.serverEnsure, params: params, expecting: EnsureResult.self)
    }

    func statusList(project: String, name: String?) async throws -> ServerListResult {
        try request(
            .serverStatus, params: ProjectParams(name: name, project: project),
            expecting: ServerListResult.self)
    }

    func stop(_ target: ServerTargetParams) async throws -> ServerResult {
        try request(.serverStop, params: target, expecting: ServerResult.self)
    }

    func why(_ target: ServerTargetParams) async throws -> WhyResult {
        try request(.serverWhy, params: target, expecting: WhyResult.self)
    }
}

/** Resolves a `DeepLink`'s slug to a project via the daemon, dispatches the verb,
    and runs any side effect (open/copy/notify). Pure branching over the daemon
    protocol and the effects; the only shared state is the log. */
public struct DeepLinkRunner: Sendable {
    private let daemon: any DeepLinkDaemon
    private let effects: any DeepLinkEffects

    public init(client: DaemonClient, effects: any DeepLinkEffects) {
        self.daemon = client
        self.effects = effects
    }

    init(daemon: any DeepLinkDaemon, effects: any DeepLinkEffects) {
        self.daemon = daemon
        self.effects = effects
    }

    public func run(_ link: DeepLink) async throws -> DeepLinkRunResult {
        DirectaLog.deeplink.info("dispatch \(link.verb.rawValue) \(link.server)@\(link.projectSlug)")
        let project = try await resolveProjectPath(link.projectSlug)
        switch link.verb {
        case .ensure:
            let result = try await daemon.ensure(
                EnsureParams(name: link.server, project: project, timeoutSeconds: 60))
            let detail = result.reason.map { "fell short: \($0.rawValue)" } ?? result.server.phase.rawValue
            return DeepLinkRunResult(verb: .ensure, projectPath: project, detail: detail)
        case .stop:
            let result = try await daemon.stop(
                ServerTargetParams(name: link.server, project: project))
            return DeepLinkRunResult(
                verb: .stop, projectPath: project, detail: result.server.phase.rawValue)
        case .why:
            let result = try await daemon.why(
                ServerTargetParams(name: link.server, project: project))
            await effects.copyToPasteboard(Self.whySummary(result, server: link.server))
            await effects.notify(
                title: "Why \(link.server)?",
                body: result.rootCause ?? "Diagnosis copied to the clipboard.")
            return DeepLinkRunResult(verb: .why, projectPath: project, detail: result.rootCause)
        case .open:
            let list = try await daemon.statusList(project: project, name: link.server)
            guard let server = list.servers.first else {
                throw ProjectConfigLoader.serverNotFound(
                    name: link.server, project: project, hint: "run: directa status --project \(project) --json")
            }
            let target = try resolveOpenURL(server: server, head: link.head)
            await effects.openBrowser(target)
            return DeepLinkRunResult(
                verb: .open, projectPath: project, detail: target.absoluteString)
        }
    }

    private func resolveProjectPath(_ slug: String) async throws -> String {
        let list = try await daemon.statusList(project: "", name: nil)
        var paths: [String] = []
        var seen: Set<String> = []
        for status in list.servers where seen.insert(status.project).inserted {
            paths.append(status.project)
        }
        switch DeepLink.resolveProject(slug: slug, against: paths) {
        case .success(let path):
            return path
        case .failure(let error):
            DirectaLog.deeplink.error("reject \(slug): \(error.message)")
            throw error
        }
    }

    private func resolveOpenURL(server: ServerStatus, head: String?) throws -> URL {
        let raw: String
        if let head {
            guard let headURL = server.heads?[head] else {
                let known = (server.heads ?? [:]).keys.sorted().joined(separator: ", ")
                let detail = known.isEmpty
                    ? "this server declares no heads"
                    : "known heads: \(known)"
                throw WireError(
                    code: .notFound,
                    hint: "run: directa status \(server.server) --json",
                    message: "no head named '\(head)' on \(server.server); \(detail)")
            }
            raw = headURL
        } else {
            guard let url = server.url else {
                throw WireError(
                    code: .notFound,
                    hint: "add a port, url, or heads to \(server.server) in devservers.json",
                    message: "\(server.server) has no URL to open")
            }
            raw = url
        }
        guard let url = URL(string: raw) else {
            throw WireError(
                code: .internalError, message: "server '\(server.server)' has an unparseable URL '\(raw)'")
        }
        return url
    }

    /** A copy-to-clipboard rendering of the why chain: root cause first, then each
        finding with its evidence indented. */
    static func whySummary(_ result: WhyResult, server: String) -> String {
        var lines: [String] = ["directa why \(server)"]
        if let root = result.rootCause {
            lines.append("root cause: \(root)")
        }
        for finding in result.findings {
            lines.append("\(finding.server) [\(finding.phase.rawValue)]: \(finding.summary)")
            for evidence in finding.evidence {
                lines.append("  \(evidence)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
