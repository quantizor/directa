import Foundation

/** Projects merged runtime specs back down to the shape devservers.json holds.
    Everything the machine derived is dropped: an effective or rebound port, a
    worktree-derived host, a materialized url, an absolute icon path, and the
    port and host keys materialization injects into the environment. The file is
    meant to travel to another checkout on another machine, so writing this
    machine's incidental state into it produces a file that is wrong the moment
    it is used anywhere else.

    The input must be the daemon's merged view, never a running supervisor's
    spec: a supervisor spec has been through PortMaterializer, so its argv holds
    substituted literals rather than the `{port}` the author wrote. */
public enum ConfigProjection {
    public static func file(
        host: String?, icon: String? = nil, lifecycle: [String: [[String]]]? = nil,
        project: String, specs: [ServerSpec]
    ) -> ProjectFileConfig {
        let declaredHost = declarableHost(host, project: project)
        let projectHost = host ?? declaredHost ?? defaultHost(project: project)
        var servers: [String: ProjectFileServer] = [:]
        for spec in specs {
            servers[spec.name] = server(project: project, projectHost: projectHost, spec: spec)
        }
        return ProjectFileConfig(
            host: declaredHost, icon: icon, lifecycle: lifecycle, servers: servers, version: 1)
    }

    public static func server(
        project: String, projectHost: String, spec: ServerSpec
    ) -> ProjectFileServer {
        /** validate() fills every spec's host, so a value equal to the project's
            is not an override the author wrote. A worktree label host is this
            machine's, never the file's; one can only appear here from state an
            older build persisted, and it is still dropped. */
        let host: String? = {
            guard let specHost = spec.host, specHost != projectHost,
                !specHost.hasPrefix("worktree-")
            else { return nil }
            return specHost
        }()
        let derivedURL = spec.port.map { "http://\(host ?? projectHost):\($0)/" }
        return ProjectFileServer(
            command: spec.command,
            cwd: spec.cwd,
            dependsOn: spec.dependsOn,
            env: declarableEnv(spec),
            heads: spec.heads,
            healthcheck: declarableHealthcheck(spec, derivedURL: derivedURL),
            host: host,
            icon: relativeIcon(spec.icon, project: project),
            locks: spec.locks,
            port: spec.port,
            portEnv: spec.portEnv,
            ports: spec.ports,
            portSpan: spec.portSpan,
            shell: spec.shell,
            url: spec.url == derivedURL ? nil : spec.url,
            waitFor: spec.waitFor,
            watch: spec.watch
        )
    }

    /** Add or replace one entry without touching the rest of the file. Nil when
        the name is already present and the caller did not ask to replace it. */
    public static func merge(
        entry: ProjectFileServer, force: Bool, into existing: ProjectFileConfig, name: String
    ) -> ProjectFileConfig? {
        if existing.servers[name] != nil, !force { return nil }
        var next = existing
        next.servers[name] = entry
        return next
    }

    /** The host a projected file should declare: never a worktree label (only
        reachable from state an older build persisted), and omitted when it is
        the `<slug>.localhost` the loader already defaults to, so a recovered
        file stays as quiet as a hand-written one. */
    static func declarableHost(_ host: String?, project: String) -> String? {
        guard let host, !host.hasPrefix("worktree-"), host != defaultHost(project: project)
        else { return nil }
        return host
    }

    static func defaultHost(project: String) -> String {
        "\(ProjectConfigLoader.defaultSlug(project: project)).localhost"
    }

    /** Drop what PortMaterializer injects, keep what the author declared. A
        user-written PORT equal to the declared port is dropped too, and harmlessly:
        directa injects it on every spawn. */
    static func declarableEnv(_ spec: ServerSpec) -> [String: String]? {
        guard var env = spec.env else { return nil }
        env.removeValue(forKey: PortMaterializer.hostEnvironmentKey)
        let portKey = spec.portEnv ?? PortMaterializer.portEnvironmentKey
        if let port = spec.port, env[portKey] == String(port) {
            env.removeValue(forKey: portKey)
        }
        return env.isEmpty ? nil : env
    }

    /** validate() never sets healthcheck.port or a derived healthcheck url;
        materialization does. */
    static func declarableHealthcheck(_ spec: ServerSpec, derivedURL: String?) -> HealthCheckSpec? {
        guard var health = spec.healthcheck else { return nil }
        if health.port == spec.port { health.port = nil }
        if let url = health.url, url == derivedURL { health.url = nil }
        return health
    }

    /** validate() turns a project-relative icon into an absolute path. An icon
        outside the project cannot be expressed relatively, so it is dropped
        rather than written as this machine's absolute path. */
    static func relativeIcon(_ icon: String?, project: String) -> String? {
        guard let icon else { return nil }
        let root = project.hasSuffix("/") ? project : project + "/"
        guard icon.hasPrefix(root) else { return nil }
        return String(icon.dropFirst(root.count))
    }
}
