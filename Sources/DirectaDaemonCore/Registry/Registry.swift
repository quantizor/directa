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
    /** Per server id, the writers `retireState` retired. In memory only: a
        restart starts empty, and every supervisor it creates has a new
        writer. */
    private var retiredWriters: [String: Set<UUID>] = [:]
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

    /** Drops one ad hoc server. A project row also carries recorded trust for
        its committed devservers.json, independent of whether any ad hoc server
        is registered there, so the row is only ever dropped once both the ad
        hoc servers and trust are gone: a project trusted through a committed
        server (`setTrusted`) must survive losing its last, or only, ad hoc
        entry. Removing a name this project never registered ad hoc (including
        one that exists solely in committed config) is a no-op; the caller is
        expected to check `spec(project:name:)` first and surface its own
        not-found error, since an ad hoc registry miss is not this type's to
        report. */
    public func unregister(project: String, name: String) throws {
        let project = Self.normalize(project)
        guard registry.projects[project]?.servers[name] != nil else { return }
        registry.projects[project]?.servers[name] = nil
        if let entry = registry.projects[project], entry.servers.isEmpty, !entry.trusted {
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

    /** `writer` is the calling supervisor's `ServerSupervisor.writerID`, nil
        for the router's own writes. A no-op for a writer `retireState`
        retired for this id, including when the row is missing: a dropped
        supervisor's late write must not recreate a row its removal settled.
        Every other writer, a later supervisor for the same id included, goes
        through. */
    public func updateState(
        serverID: String, writer: UUID? = nil, _ mutate: (inout PersistedServerState) -> Void
    ) throws {
        let serverID = Self.normalizeServerID(serverID)
        if let writer, retiredWriters[serverID]?.contains(writer) == true { return }
        var entry = state.servers[serverID] ?? PersistedServerState()
        mutate(&entry)
        state.servers[serverID] = entry
        try persistState()
    }

    /** Settles a removed server's row as `final` and retires `writer` for that
        id, in one turn on this actor. For a server whose stop never finished
        before its supervisor was dropped: that supervisor's `recordOutcome`
        can still land afterward. Both take effect in memory before the save,
        so a save that throws still refuses the late write. `removeState`
        still deletes a retired row. */
    public func retireState(serverID: String, final: PersistedServerState, writer: UUID) throws {
        let serverID = Self.normalizeServerID(serverID)
        retiredWriters[serverID, default: []].insert(writer)
        state.servers[serverID] = final
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
