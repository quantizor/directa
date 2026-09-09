import DirectaKit
import Foundation

/** Persisted registry: which projects and servers exist, and whether the project's
    committed config has been trusted. */
public struct RegistryFile: Codable, Sendable {
    public var projects: [String: RegisteredProject]

    public init(projects: [String: RegisteredProject] = [:]) {
        self.projects = projects
    }
}

public struct RegisteredProject: Codable, Sendable {
    public var servers: [String: ServerSpec]
    public var trusted: Bool

    public init(servers: [String: ServerSpec] = [:], trusted: Bool = false) {
        self.servers = servers
        self.trusted = trusted
    }
}

/** Persisted last-known runtime state per server; survives daemon restarts and
    powers crash forensics + recovery. */
public struct StateFile: Codable, Sendable {
    public var servers: [String: PersistedServerState]

    public init(servers: [String: PersistedServerState] = [:]) {
        self.servers = servers
    }
}

public struct PersistedServerState: Codable, Sendable {
    /** Sibling-rebind assignment; optional so older state files keep parsing. */
    public var boundPort: Int?
    /** Error-stream tally from the last run, so a daemon restart does not erase
        the forensics an agent needs to understand why a server is down.
        Optional so state files written before this field existed keep parsing. */
    public var errorSummary: ErrorSummary?
    public var lastExit: LastExit?
    public var phase: ServerPhase
    public var pid: Int?
    /** Intent to have this server up across a machine reboot. Set on every
        start/ensure; cleared only by a deliberate user stop (directa stop/down).
        A launchd SIGTERM drain (machine shutdown) preserves it, so the next
        boot's recoverAtStartup brings the server back. Optional so state files
        written before this field existed keep parsing. */
    public var resumeOnBoot: Bool?
    public var spawnError: SpawnError?
    public var startedAt: Date?
    /** Consecutive self-exits shaped like an interactive-auth stall (nonzero,
        bounded lifetime, never health-verified a bind). Two or more is what
        status surfaces as `blockedOn`. Optional so state files written before
        this field existed keep parsing. */
    public var stallStreak: Int?
    /** Last terminal spool lines for `why` after ensure truncate / rehydrate. */
    public var terminalEvidence: [String]?

    public init(
        boundPort: Int? = nil,
        errorSummary: ErrorSummary? = nil,
        lastExit: LastExit? = nil,
        phase: ServerPhase = .stopped,
        pid: Int? = nil,
        resumeOnBoot: Bool? = nil,
        spawnError: SpawnError? = nil,
        startedAt: Date? = nil,
        stallStreak: Int? = nil,
        terminalEvidence: [String]? = nil
    ) {
        self.boundPort = boundPort
        self.errorSummary = errorSummary
        self.lastExit = lastExit
        self.phase = phase
        self.pid = pid
        self.resumeOnBoot = resumeOnBoot
        self.spawnError = spawnError
        self.startedAt = startedAt
        self.stallStreak = stallStreak
        self.terminalEvidence = terminalEvidence
    }
}

/** Owner of registry.json and state.json. Loads defensively (quarantine on parse
    failure), writes atomically (temp + fsync + rename). */
public actor Registry {
    private let paths: DirectaPaths
    private var registry: RegistryFile
    private var state: StateFile

    public init(paths: DirectaPaths) {
        self.paths = paths
        self.registry = AtomicFile.loadDefensively(RegistryFile.self, from: paths.registryFile) ?? RegistryFile()
        self.state = AtomicFile.loadDefensively(StateFile.self, from: paths.stateFile) ?? StateFile()
    }

    public func allProjects() -> [String] {
        registry.projects.keys.sorted()
    }

    public func project(_ path: String) -> RegisteredProject? {
        registry.projects[Self.normalize(path)]
    }

    public func register(project: String, spec: ServerSpec) throws {
        let project = Self.normalize(project)
        var entry = registry.projects[project] ?? RegisteredProject()
        entry.servers[spec.name] = spec
        registry.projects[project] = entry
        try persistRegistry()
    }

    public func spec(project: String, name: String) -> ServerSpec? {
        registry.projects[Self.normalize(project)]?.servers[name]
    }

    public func specs(project: String) -> [ServerSpec] {
        (registry.projects[Self.normalize(project)]?.servers ?? [:]).values.sorted {
            $0.name < $1.name
        }
    }

    public func isTrusted(project: String) -> Bool {
        registry.projects[Self.normalize(project)]?.trusted ?? false
    }

    public func setTrusted(project: String) throws {
        let project = Self.normalize(project)
        var entry = registry.projects[project] ?? RegisteredProject()
        entry.trusted = true
        registry.projects[project] = entry
        try persistRegistry()
    }

    public func unregister(project: String, name: String) throws {
        let project = Self.normalize(project)
        registry.projects[project]?.servers[name] = nil
        if let entry = registry.projects[project], entry.servers.isEmpty {
            registry.projects[project] = nil
        }
        try persistRegistry()
    }

    /** Drop a project entirely (trust + ad-hoc servers). Used when the checkout
        path is gone so registry/Spotlight stop claiming it. */
    public func removeProject(_ path: String) throws {
        let project = Self.normalize(path)
        guard registry.projects[project] != nil else { return }
        registry.projects[project] = nil
        try persistRegistry()
    }

    public func persistedState(serverID: String) -> PersistedServerState? {
        state.servers[Self.normalizeServerID(serverID)]
    }

    public func allPersistedState() -> [String: PersistedServerState] {
        state.servers
    }

    public func updateState(serverID: String, _ mutate: (inout PersistedServerState) -> Void) throws {
        let serverID = Self.normalizeServerID(serverID)
        var entry = state.servers[serverID] ?? PersistedServerState()
        mutate(&entry)
        state.servers[serverID] = entry
        try persistState()
    }

    /** Drop a state row whose server no longer exists in config or the registry
        (rename / delete). Keeps recoverAtStartup from re-visiting ghosts. */
    public func removeState(serverID: String) throws {
        let serverID = Self.normalizeServerID(serverID)
        guard state.servers[serverID] != nil else { return }
        state.servers[serverID] = nil
        try persistState()
    }

    /** Drop every state row whose project prefix matches (discarded checkout). */
    public func removeState(forProject path: String) throws {
        let prefix = "\(Self.normalize(path))::"
        let keys = state.servers.keys.filter { $0.hasPrefix(prefix) }
        guard !keys.isEmpty else { return }
        for key in keys {
            state.servers[key] = nil
        }
        try persistState()
    }

    private static func normalize(_ project: String) -> String {
        canonicalProjectPath(project)
    }

    private static func normalizeServerID(_ id: String) -> String {
        guard let parsed = parseServerID(id) else { return id }
        return serverID(project: canonicalProjectPath(parsed.project), name: parsed.name)
    }

    private func persistRegistry() throws {
        try AtomicFile.write(JSONCoding.encoder().encode(registry), to: paths.registryFile)
    }

    private func persistState() throws {
        try AtomicFile.write(JSONCoding.encoder().encode(state), to: paths.stateFile)
    }
}
