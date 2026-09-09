import Foundation

/** The committed per-project file: devservers.json at the project root. Server
    names are the dictionary keys; `host` defaults to `<slug>.localhost` and
    gives every server a unique browser origin (cookie/storage isolation). */
public struct ProjectFileConfig: Codable, Equatable, Sendable {
    public var host: String?
    /** Project-relative path to an icon image (png/svg/anything NSImage reads);
        servers may override with their own `icon`. Spotlight thumbnails use it. */
    public var icon: String?
    /** Named command playbooks (argv arrays, run sequentially from the project
        root). `switch` runs between a branch change and the servers coming back
        (installs, seeds, codegen); agents configure these to teach directa the
        project's usage patterns. */
    public var lifecycle: [String: [[String]]]?
    public var servers: [String: ProjectFileServer]
    public var version: Int

    public init(
        host: String? = nil,
        icon: String? = nil,
        lifecycle: [String: [[String]]]? = nil,
        servers: [String: ProjectFileServer],
        version: Int = 1
    ) {
        self.host = host
        self.icon = icon
        self.lifecycle = lifecycle
        self.servers = servers
        self.version = version
    }
}

/** A server entry as written in the file (the name lives in the key). */
public struct ProjectFileServer: Codable, Equatable, Sendable {
    public var command: [String]
    public var cwd: String?
    public var dependsOn: [String]?
    public var env: [String: String]?
    public var heads: [String: String]?
    public var healthcheck: HealthCheckSpec?
    public var host: String?
    public var icon: String?
    public var locks: [LockDeclaration]?
    public var port: Int?
    public var portEnv: String?
    public var ports: [String: SecondaryPort]?
    public var portSpan: Int?
    public var shell: Bool?
    public var url: String?
    public var waitFor: WaitTarget?
    /** Project-relative files this server reads at boot but does not reload on
        its own. A change to one restarts the server. A server whose framework
        already reloads its own config declares nothing here. */
    public var watch: [String]?

    public init(
        command: [String],
        cwd: String? = nil,
        dependsOn: [String]? = nil,
        env: [String: String]? = nil,
        heads: [String: String]? = nil,
        healthcheck: HealthCheckSpec? = nil,
        host: String? = nil,
        icon: String? = nil,
        locks: [LockDeclaration]? = nil,
        port: Int? = nil,
        portEnv: String? = nil,
        ports: [String: SecondaryPort]? = nil,
        portSpan: Int? = nil,
        shell: Bool? = nil,
        url: String? = nil,
        waitFor: WaitTarget? = nil,
        watch: [String]? = nil
    ) {
        self.command = command
        self.cwd = cwd
        self.dependsOn = dependsOn
        self.env = env
        self.heads = heads
        self.healthcheck = healthcheck
        self.host = host
        self.icon = icon
        self.locks = locks
        self.port = port
        self.portEnv = portEnv
        self.ports = ports
        self.portSpan = portSpan
        self.shell = shell
        self.url = url
        self.waitFor = waitFor
        self.watch = watch
    }
}

/** A validated project view: resolved specs plus the problems found. Errors
    block use of the config; warnings ride along in check output. */
public struct ProjectConfigView: Equatable, Sendable {
    public var errors: [String]
    public var host: String
    public var specs: [ServerSpec]
    public var warnings: [String]

    public init(errors: [String] = [], host: String, specs: [ServerSpec] = [], warnings: [String] = []) {
        self.errors = errors
        self.host = host
        self.specs = specs
        self.warnings = warnings
    }
}

public enum ProjectConfigLoader {
    public static func configURL(project: String) -> URL {
        URL(fileURLWithPath: project).appending(path: "devservers.json")
    }

    /** Parses and validates; a thrown error is a config-invalid the caller
        surfaces verbatim. Warnings never block. */
    public static func load(project: String) throws -> ProjectConfigView? {
        let url = configURL(project: project)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let config: ProjectFileConfig
        do {
            config = try JSONCoding.decoder().decode(ProjectFileConfig.self, from: data)
        } catch {
            throw configError(from: error, at: url)
        }
        return validate(config: config, project: project)
    }

    public static func validate(config: ProjectFileConfig, project: String) -> ProjectConfigView {
        let recommendedHost = "\(defaultSlug(project: project)).localhost"
        let host = config.host ?? recommendedHost
        var view = ProjectConfigView(host: host)
        var warnings: [String] = []
        if config.version != 1 {
            warnings.append("unknown config version \(config.version); this directa understands version 1")
        }
        /** Bare loopback hosts collapse every project onto one browser origin, so
            cookies/storage/service workers leak across projects. Warn (never fail):
            an explicit bare host may be a deliberate choice for a non-browser
            server. */
        if let explicit = config.host, isBareLoopback(explicit) {
            warnings.append(
                "host '\(explicit)' is a bare loopback address; prefer '\(recommendedHost)' so each project keeps an isolated browser origin")
        }
        var declaredPorts: [Int: String] = [:]
        var specs: [ServerSpec] = []
        for (name, entry) in config.servers.sorted(by: { $0.key < $1.key }) {
            /** `type: http` with no url silently falls back to a TCP probe on
                the declared port, so a mistyped `url` key yields a server that
                reports healthy while its HTTP layer was never checked. A warning
                rather than an error, because configs relying on that fallback
                start today and blocking them here would be a bigger change than
                the mistake it catches. */
            if entry.healthcheck?.type == .http, entry.healthcheck?.url == nil {
                warnings.append(
                    "server '\(name)': healthcheck type is http but no url is set, so it will be probed over TCP instead; add a url or set type to tcp")
            }
            if let explicitHost = entry.host, isBareLoopback(explicitHost) {
                warnings.append(
                    "server '\(name)': host '\(explicitHost)' is a bare loopback address; prefer a '\(recommendedHost)' subdomain")
            }
            if let explicitURL = entry.url, let urlHost = URL(string: explicitURL)?.host,
                isBareLoopback(urlHost) {
                warnings.append(
                    "server '\(name)': url '\(explicitURL)' points at a bare loopback host; prefer '\(recommendedHost)'")
            }
            /** A head or healthcheck url resolves against the server's own base
                only when there is a base to resolve against. Without one the value
                materializes to `//:port/path`, which reads as a URL everywhere it
                lands (the menu bar, Spotlight, `directa open`, agent context) and
                works nowhere. */
            let hasBase = entry.port != nil || entry.url != nil
            for (headName, headValue) in (entry.heads ?? [:]).sorted(by: { $0.key < $1.key }) {
                let checked = checkURLValue(
                    hasBase: hasBase, label: "head '\(headName)'", recommendedHost: recommendedHost,
                    server: name, value: headValue)
                view.errors.append(contentsOf: checked.errors)
                warnings.append(contentsOf: checked.warnings)
            }
            if let healthURL = entry.healthcheck?.url {
                let checked = checkURLValue(
                    hasBase: hasBase, label: "healthcheck url", recommendedHost: recommendedHost,
                    server: name, value: healthURL)
                view.errors.append(contentsOf: checked.errors)
                warnings.append(contentsOf: checked.warnings)
            }
            var iconPath: String?
            if let relative = entry.icon ?? config.icon {
                let absolute = (project as NSString).appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: absolute) {
                    iconPath = absolute
                } else {
                    warnings.append("server '\(name)': icon '\(relative)' not found in the project")
                }
            }
            /** Warn rather than error: a stray watch entry should not block a
                whole project's config, and the survivors still work. */
            var watchEntries: [String]?
            if let declared = entry.watch, !declared.isEmpty {
                let resolved = WatchPaths.resolve(entries: declared, project: project)
                warnings.append(contentsOf: resolved.warnings.map { "server '\(name)': \($0)" })
                let kept = declared.filter { candidate in
                    resolved.paths.contains {
                        $0 == URL(fileURLWithPath: project).appending(path: candidate)
                            .standardizedFileURL.path
                    }
                }
                watchEntries = kept.isEmpty ? nil : kept
            }
            let serverHost = entry.host ?? host
            var url = entry.url
            if url == nil, let port = entry.port {
                url = "http://\(serverHost):\(port)/"
            }
            if let port = entry.port {
                if let holder = declaredPorts[port] {
                    warnings.append("servers '\(holder)' and '\(name)' both declare port \(port)")
                } else {
                    declaredPorts[port] = name
                }
            }
            for dep in entry.dependsOn ?? [] where config.servers[dep] == nil {
                view.errors.append("server '\(name)' depends on unknown server '\(dep)'")
            }
            let draft = ServerSpec(
                command: entry.command,
                cwd: entry.cwd,
                dependsOn: entry.dependsOn,
                env: entry.env,
                heads: entry.heads,
                healthcheck: entry.healthcheck,
                host: serverHost,
                icon: iconPath,
                locks: entry.locks,
                name: name,
                port: entry.port,
                portEnv: entry.portEnv,
                ports: entry.ports,
                portSpan: entry.portSpan,
                shell: entry.shell,
                url: url,
                waitFor: entry.waitFor,
                watch: watchEntries
            )
            view.errors.append(contentsOf: draft.validationErrors())
            specs.append(draft)
        }
        switch DependencyGraph.waves(specs: specs) {
        case .success:
            break
        case .cycle(let names):
            view.errors.append("dependency cycle: \(names.joined(separator: " -> "))")
        }
        /** `lifecycle` is the one config field the daemon never spawns; `directa
            switch` runs its argv locally. It was also the one field this
            validator skipped, so a playbook with an empty command reached
            `/usr/bin/env` with no executable. Checked here so `config check`
            rejects it and `switch` refuses to run it. */
        for (playbook, commands) in (config.lifecycle ?? [:]).sorted(by: { $0.key < $1.key }) {
            for (index, argv) in commands.enumerated() {
                if argv.isEmpty {
                    view.errors.append(
                        "lifecycle '\(playbook)' command \(index + 1) is empty")
                } else if argv[0].isEmpty {
                    view.errors.append(
                        "lifecycle '\(playbook)' command \(index + 1) has an empty executable")
                }
            }
        }
        view.specs = specs
        view.warnings = warnings
        return view
    }

    /** Judge one head or healthcheck url from the config file. Two shapes are
        legal: an absolute URL, or a root-relative path resolved against the
        server's own base at materialization. `{host}` / `{port}` values are legal
        input to substitution and cannot be judged before the effective values are
        known, so they are left alone. */
    static func checkURLValue(
        hasBase: Bool, label: String, recommendedHost: String, server: String, value: String
    ) -> (errors: [String], warnings: [String]) {
        if value.contains("{host}") || value.contains("{port}") { return ([], []) }
        if value.isEmpty { return (["server '\(server)': \(label) is empty"], []) }
        if value.hasPrefix("/") {
            guard hasBase else {
                return (
                    [
                        "server '\(server)': \(label) is the path '\(value)' but the server declares no port or url to resolve it against; give the server a port, or write the \(label.hasPrefix("head") ? "head" : "url") as an absolute URL"
                    ], []
                )
            }
            return ([], [])
        }
        guard let host = URLComponents(string: value)?.host else {
            return (
                [
                    "server '\(server)': \(label) is '\(value)', which is neither an absolute URL nor a path starting with '/'; write 'http://host:port/\(value)' or '/\(value)'"
                ], []
            )
        }
        guard isBareLoopback(host) else { return ([], []) }
        return (
            [],
            [
                "server '\(server)': \(label) points at a bare loopback host; prefer '\(recommendedHost)'"
            ]
        )
    }

    /** A host that resolves to loopback with no per-project subdomain, so it
        shares one origin across every project (the isolation the `*.localhost`
        signature exists to give). `<slug>.localhost` and `api.myproj.localhost`
        are fine; only the bare forms trip this. */
    static func isBareLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1"
    }

    public static func defaultSlug(project: String) -> String {
        projectSlug(project)
    }

    /** Decode failures become a message a non-engineer can act on: the file,
        the failing key path, and what was expected. */
    public static func configError(from error: any Error, at url: URL) -> WireError {
        var detail = String(describing: error)
        if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let key, let context):
                let path = (context.codingPath.map(\.stringValue) + [key.stringValue])
                    .joined(separator: ".")
                detail = "missing key \(path)"
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                detail = path.isEmpty ? context.debugDescription : "\(context.debugDescription) at \(path)"
            @unknown default:
                break
            }
        }
        return WireError(
            code: .configInvalid,
            hint: "run: directa config check",
            message: "cannot parse \(url.path): \(detail)")
    }
}

/** Dependency ordering for group operations: Kahn's algorithm producing waves of
    servers whose dependencies are all satisfied by earlier waves. */
public enum DependencyGraph {
    public enum WaveResult: Equatable, Sendable {
        case cycle([String])
        case success([[String]])
    }

    public static func waves(specs: [ServerSpec]) -> WaveResult {
        let names = Set(specs.map(\.name))
        var dependents: [String: [String]] = [:]
        var inDegree: [String: Int] = [:]
        for spec in specs {
            let deps = (spec.dependsOn ?? []).filter(names.contains)
            inDegree[spec.name] = deps.count
            for dep in deps {
                dependents[dep, default: []].append(spec.name)
            }
        }
        var waves: [[String]] = []
        var settled = 0
        var frontier = inDegree.filter { $0.value == 0 }.keys.sorted()
        while !frontier.isEmpty {
            waves.append(frontier)
            settled += frontier.count
            var next: Set<String> = []
            for name in frontier {
                for dependent in dependents[name] ?? [] {
                    /** Every dependent was seeded into `inDegree`, so the key is
                        present by construction. Written as a defaulted read
                        rather than a force unwrap so a future edit to the
                        seeding loop degrades into a wrong wave rather than a
                        crash in the daemon's start path. */
                    let remaining = (inDegree[dependent] ?? 0) - 1
                    inDegree[dependent] = remaining
                    if remaining == 0 { next.insert(dependent) }
                }
            }
            frontier = next.sorted()
        }
        if settled < specs.count {
            let stuck = inDegree.filter { $0.value > 0 }.keys.sorted()
            return .cycle(stuck)
        }
        return .success(waves)
    }
}
