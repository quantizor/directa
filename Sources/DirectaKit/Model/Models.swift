import Foundation

/** Protocol and daemon version constants shared by all three products. */
public enum DirectaVersion {
    /** Wire protocol major version; clients abort on mismatch with `version-mismatch`. */
    public static let proto = 1
    public static let version = "2.0.0"
}

/** Lifecycle phase of a supervised server. `failed` means the spawn itself never
    succeeded (ENOENT, EACCES) and is distinct from `crashed` (ran, then died). */
public enum ServerPhase: String, Codable, Sendable {
    case crashed
    case failed
    case running
    case starting
    case stopped
    case stopping
    case unhealthy
}

/** Healthcheck configuration. Absent spec + declared port implies a TCP probe;
    absent entirely means healthy = alive past a stabilization window. */
public struct HealthCheckSpec: Codable, Equatable, Sendable {
    /** Bounds for the numbers a probe loop runs on. Ten minutes is far past any
        real healthcheck and still inside Int32, which `poll` needs; 255 rounds
        of probing is likewise past any real patience. */
    public static let countRange = 1...255
    public static let durationRange = 1...600_000

    public var healthyAfter: Int?
    public var intervalMs: Int?
    public var port: Int?
    public var timeoutMs: Int?
    public var type: HealthCheckType
    public var unhealthyAfter: Int?
    public var url: String?

    /** Config-check messages for values a probe loop cannot use. Every field
        here reaches a syscall or paces a loop: `port` is narrowed for a
        `sockaddr`, `timeoutMs` becomes a `poll` deadline where a negative reads
        as wait-forever, `intervalMs` sets how often directa probes somebody
        else's server, and the counters decide when a phase flips. None of them
        was checked, so a repo could set directa's own probe cadence. */
    public func validationErrors() -> [String] {
        var errors: [String] = []
        if let healthyAfter, !Self.countRange.contains(healthyAfter) {
            errors.append("healthcheck.healthyAfter must be \(Self.countRange)")
        }
        if let intervalMs, !Self.durationRange.contains(intervalMs) {
            errors.append("healthcheck.intervalMs must be \(Self.durationRange)")
        }
        if let port, !PortClaim.portRange.contains(port) {
            errors.append("healthcheck.port must be 1...65535")
        }
        if let timeoutMs, !Self.durationRange.contains(timeoutMs) {
            errors.append("healthcheck.timeoutMs must be \(Self.durationRange)")
        }
        if let unhealthyAfter, !Self.countRange.contains(unhealthyAfter) {
            errors.append("healthcheck.unhealthyAfter must be \(Self.countRange)")
        }
        return errors
    }

    public init(
        healthyAfter: Int? = nil,
        intervalMs: Int? = nil,
        port: Int? = nil,
        timeoutMs: Int? = nil,
        type: HealthCheckType,
        unhealthyAfter: Int? = nil,
        url: String? = nil
    ) {
        self.healthyAfter = healthyAfter
        self.intervalMs = intervalMs
        self.port = port
        self.timeoutMs = timeoutMs
        self.type = type
        self.unhealthyAfter = unhealthyAfter
        self.url = url
    }
}

public enum HealthCheckType: String, Codable, Sendable {
    case http
    case none
    case tcp
}

/** How a dependent waits on its dependency during group startup. */
public enum WaitTarget: String, Codable, Sendable {
    case healthy
    case started
}

/** A resource a server holds while running. Written either as a bare name
    (`"d1"`) or as an object naming where the resource's state lives on disk
    (`{"name": "d1", "path": ".wrangler/state/v3/d1"}`). Both forms decode and the
    bare form re-encodes bare, so existing registry entries and committed configs
    never churn. The path is what lets `directa lock` notice that a command
    changed the state while a declaring server still held the old file open. */
public struct LockDeclaration: Codable, Equatable, Hashable, Sendable {
    public var name: String
    /** Project-relative path to the resource's state, a file or a directory.
        Absent means directa cannot check identity for this resource, and will not
        pretend to. */
    public var path: String?

    public init(name: String, path: String? = nil) {
        self.name = name
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case path
    }

    public init(from decoder: any Decoder) throws {
        /** Probing the string form is the discriminator between the two shapes,
            not a swallowed error: the object branch reports its own decode
            failure with the real key path. */
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.name = name
            self.path = nil
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try keyed.decode(String.self, forKey: .name)
        self.path = try keyed.decodeIfPresent(String.self, forKey: .path)
    }

    public func encode(to encoder: any Encoder) throws {
        guard let path else {
            var single = encoder.singleValueContainer()
            try single.encode(name)
            return
        }
        var keyed = encoder.container(keyedBy: CodingKeys.self)
        try keyed.encode(name, forKey: .name)
        try keyed.encode(path, forKey: .path)
    }
}

/** What `directa wait` blocks on. */
public enum WaitCondition: String, Codable, Sendable {
    case healthy
    case stopped
}

/** Why an ensure/wait returned without reaching its target. Absent = reached. */
public enum EnsureReason: String, Codable, Sendable {
    case crashed
    case failed
    case stopped
    case timeout
}

/** Result of ensure/wait: the status plus the reason it fell short, if it did. */
public struct EnsureResult: Codable, Equatable, Sendable {
    public var reason: EnsureReason?
    public var server: ServerStatus

    public init(reason: EnsureReason? = nil, server: ServerStatus) {
        self.reason = reason
        self.server = server
    }
}

/** A server declaration: the unit of devservers.json and ad-hoc registration. */
public struct ServerSpec: Codable, Equatable, Sendable {
    public var command: [String]
    /** Relative to the project root. */
    public var cwd: String?
    public var dependsOn: [String]?
    public var env: [String: String]?
    /** Named entry points for a multi-headed server (a host-routing proxy
        serving several surfaces on one port): display name -> URL. */
    public var heads: [String: String]?
    public var healthcheck: HealthCheckSpec?
    /** Resolved server host (committed or overlay). Kept on
        the spec so port materialization can rebuild urls without re-reading
        the project file. Optional so older ad-hoc registry entries keep parsing. */
    public var host: String?
    /** Absolute path to an icon image (resolved from the config's
        project-relative path); used for Spotlight thumbnails. */
    public var icon: String?
    /** Named mutable resources this server holds while running (a local
        database, a fixture directory). `directa lock <resource> -- cmd` takes
        exclusive access without stopping holders; `--pause` stops them for the
        command's duration. Starts are refused while a live external holder owns
        the resource. */
    public var locks: [LockDeclaration]?
    public var name: String
    public var port: Int?
    /** Child env var that receives the effective port (default `PORT`). */
    public var portEnv: String?
    /** Named secondary listeners (relative offsets or absolute singletons). */
    public var ports: [String: SecondaryPort]?
    /** Claim `effectivePort ..< effectivePort+portSpan` without naming each
        secondary. Sugar for apps that derive children from the primary env. */
    public var portSpan: Int?
    /** Runs the command through `/bin/zsh -lc` for shells that need login env (nvm/mise). */
    public var shell: Bool?
    public var url: String?
    public var waitFor: WaitTarget?
    /** Project-relative files this server reads at boot and does not reload on
        its own; a change restarts it. Empty or absent means today's behavior
        exactly, which is what a self-reloading framework wants. */
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
        name: String,
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
        self.name = name
        self.port = port
        self.portEnv = portEnv
        self.ports = ports
        self.portSpan = portSpan
        self.shell = shell
        self.url = url
        self.waitFor = waitFor
        self.watch = watch
    }

    /** Per-spec config-check messages for a spec entering the daemon directly
        through `server.register`, where the project-file validator never runs.
        Mirrors the per-server checks `ProjectConfigLoader.validate` applies to a
        committed entry, so one of the two ways a spec reaches the daemon can no
        longer accept a spec the other would refuse. Cross-spec checks (unknown
        dependency, cycles) are the file validator's job and are not decidable
        from a single spec. */
    public func validationErrors() -> [String] {
        var errors: [String] = []
        if name.isEmpty {
            errors.append("server name is empty")
        }
        /** `::` is the separator directa uses to build a persisted server key
            from a project path and a server name, so a name carrying it splits
            back into the wrong project and server. */
        if name.contains("::") {
            errors.append("server '\(name)': name must not contain '::'")
        }
        if command.isEmpty {
            errors.append("server '\(name)': command is empty")
        }
        for error in healthcheck?.validationErrors() ?? [] {
            errors.append("server '\(name)': \(error)")
        }
        errors.append(contentsOf: PortClaim.configErrors(spec: self))
        return errors
    }
}

/** Exit forensics for a server that ran and then died. */
public struct LastExit: Codable, Equatable, Sendable {
    public var at: Date
    public var code: Int?
    public var signal: Int?

    public init(at: Date, code: Int? = nil, signal: Int? = nil) {
        self.at = at
        self.code = code
        self.signal = signal
    }
}

/** Forensics for a spawn that never produced a process. */
public struct SpawnError: Codable, Equatable, Sendable {
    public var errno: Int?
    public var message: String

    public init(errno: Int? = nil, message: String) {
        self.errno = errno
        self.message = message
    }
}

/** Counted, never quoted: what directa observed on a server's error stream during
    the current process's life. Every field is directa's own arithmetic over the
    log, which is what makes it safe to put in an agent's session context where a
    child's own bytes must never go. */
public struct ErrorSummary: Codable, Equatable, Sendable {
    public var count: Int
    public var firstAt: Date
    public var lastAt: Date

    public init(count: Int, firstAt: Date, lastAt: Date) {
        self.count = count
        self.firstAt = firstAt
        self.lastAt = lastAt
    }
}

/** The core status schema agents consume; documented in docs/cli-contract.md. */
public struct ServerStatus: Codable, Equatable, Sendable {
    /** Present when the last runs died the way an interactive credential prompt
        blocks: self-exit, nonzero, after tens of seconds, repeatedly, without
        ever passing a healthcheck. A heuristic classification in directa's own
        words, not a quote of anything the child printed. */
    public var blockedOn: String?
    public var declaredPort: Int?
    public var effectivePort: Int?
    public var errorSummary: ErrorSummary?
    public var heads: [String: String]?
    public var healthcheck: HealthCheckType
    public var icon: String?
    public var lastExit: LastExit?
    public var lastHealthAt: Date?
    /** Resources this server holds while running, from its `locks` declaration.
        The machine-readable half of the hint `stop` prints: getting exclusive
        access to one of these is what `directa lock` is for, and stopping the
        server is the heavier way to the same place. */
    public var locks: [String]?
    public var logPath: String
    /** Slug of the main checkout when this server runs from a linked git
        worktree; nil for a main checkout. Display only: the app composes it
        with `worktree` ("myproj · review") so family relation survives
        Spotlight and the menu bar. */
    public var mainProject: String?
    public var observedPort: Int?
    public var phase: ServerPhase
    public var pid: Int?
    public var portConflict: PortConflict?
    /** Resolved named secondary ports when the spec declares `ports`. */
    public var ports: [String: Int]?
    public var project: String
    public var recentLogTail: [String]?
    public var server: String
    public var spawnError: SpawnError?
    public var specStale: Bool?
    /** Short spool evidence persisted across ensure/rehydrate for `why`. */
    public var terminalEvidence: [String]?
    public var uptimeSec: Int?
    public var url: String?
    /** Sanitized checkout-directory name when the server runs from a linked
        git worktree; nil for a main checkout. Display only: the host stays
        the project's declared one, so auth configs pinned to one origin keep
        working in a worktree. */
    public var worktree: String?

    public init(
        blockedOn: String? = nil,
        declaredPort: Int? = nil,
        effectivePort: Int? = nil,
        errorSummary: ErrorSummary? = nil,
        heads: [String: String]? = nil,
        healthcheck: HealthCheckType = .none,
        icon: String? = nil,
        lastExit: LastExit? = nil,
        lastHealthAt: Date? = nil,
        locks: [String]? = nil,
        logPath: String,
        mainProject: String? = nil,
        observedPort: Int? = nil,
        phase: ServerPhase,
        pid: Int? = nil,
        portConflict: PortConflict? = nil,
        ports: [String: Int]? = nil,
        project: String,
        recentLogTail: [String]? = nil,
        server: String,
        spawnError: SpawnError? = nil,
        specStale: Bool? = nil,
        terminalEvidence: [String]? = nil,
        uptimeSec: Int? = nil,
        url: String? = nil,
        worktree: String? = nil
    ) {
        self.blockedOn = blockedOn
        self.declaredPort = declaredPort
        self.effectivePort = effectivePort
        self.errorSummary = errorSummary
        self.heads = heads
        self.healthcheck = healthcheck
        self.icon = icon
        self.lastExit = lastExit
        self.lastHealthAt = lastHealthAt
        self.locks = locks
        self.logPath = logPath
        self.mainProject = mainProject
        self.observedPort = observedPort
        self.phase = phase
        self.pid = pid
        self.portConflict = portConflict
        self.ports = ports
        self.project = project
        self.recentLogTail = recentLogTail
        self.server = server
        self.spawnError = spawnError
        self.specStale = specStale
        self.terminalEvidence = terminalEvidence
        self.uptimeSec = uptimeSec
        self.url = url
        self.worktree = worktree
    }
}

extension ServerStatus {
    /** The one port to show a human, from the three the status carries.

        Observed first because it is the only one measured rather than intended:
        it is scraped from what the child actually bound. The supervisor sets it
        to the expected port whenever the child binds where it was told, so this
        differs from the effective port only under drift, which `portConflict`
        reports separately.

        Effective before declared is the part that was getting lost. A server
        that auto-rebound off a sibling collision has an effective port that its
        declared port disagrees with, and showing the declared one sends the
        reader to a port where nothing is listening. Three call sites spelled
        this precedence three different ways and two of them dropped the
        effective port, so the menu bar and the statusline disagreed with the
        agent context about where the same server was. */
    public var displayPort: Int? { observedPort ?? effectivePort ?? declaredPort }
}

/** The unified event feed: lifecycle transitions, health changes, and marks as
    one queryable stream. */
public enum EventKind: String, Codable, Sendable {
    case crashed
    case failed
    case healthy
    case marked
    case registered
    case started
    case stopped
    case unhealthy
    case unregistered
}

public struct EventRecord: Codable, Equatable, Sendable {
    public var at: Date
    public var detail: String?
    public var kind: EventKind
    public var project: String
    public var server: String

    public init(at: Date, detail: String? = nil, kind: EventKind, project: String, server: String) {
        self.at = at
        self.detail = detail
        self.kind = kind
        self.project = project
        self.server = server
    }
}

/** Whether the menu bar should banner an event. Expected daemon bounce markers
    (`daemon-restart`) are forensics for the feed, not user alerts. */
public enum CrashNotificationPolicy {
    public static func shouldNotify(kind: EventKind, detail: String?) -> Bool {
        guard kind == .crashed || kind == .failed else { return false }
        if let detail, detail.hasPrefix("daemon-restart") { return false }
        return true
    }
}

/** One step in a `directa why` diagnosis chain. */
public struct WhyFinding: Codable, Equatable, Sendable {
    public var evidence: [String]
    public var phase: ServerPhase
    public var server: String
    public var summary: String

    public init(evidence: [String] = [], phase: ServerPhase, server: String, summary: String) {
        self.evidence = evidence
        self.phase = phase
        self.server = server
        self.summary = summary
    }
}

public struct WhyResult: Codable, Equatable, Sendable {
    public var findings: [WhyFinding]
    /** The dependency-walk's best root-cause statement, when one stands out. */
    public var rootCause: String?

    public init(findings: [WhyFinding], rootCause: String? = nil) {
        self.findings = findings
        self.rootCause = rootCause
    }
}

/** Basic daemon identity returned by `daemon.info`. */
public struct DaemonInfo: Codable, Equatable, Sendable {
    public var dataDir: String
    public var daemonVersion: String
    public var logsDir: String
    public var pid: Int
    public var proto: Int
    /** Present and true only while boot restore is running, so a serving daemon
        encodes exactly the payload it always did. A reader that does not know
        the key sees a normal daemon, which is the right default: the flag marks
        a window measured in seconds. */
    public var restoring: Bool?
    public var searchPath: String?
    public var socketPath: String

    public init(
        dataDir: String,
        daemonVersion: String,
        logsDir: String,
        pid: Int,
        proto: Int,
        restoring: Bool? = nil,
        searchPath: String? = nil,
        socketPath: String
    ) {
        self.dataDir = dataDir
        self.daemonVersion = daemonVersion
        self.logsDir = logsDir
        self.pid = pid
        self.proto = proto
        self.restoring = restoring
        self.searchPath = searchPath
        self.socketPath = socketPath
    }
}
