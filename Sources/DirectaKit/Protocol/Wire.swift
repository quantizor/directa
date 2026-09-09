import Foundation

/** Central JSON coding: deterministic key order (golden tests depend on it) and
    ISO-8601 timestamps with milliseconds everywhere on the wire and in files. */
public enum JSONCoding {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = parseISO8601(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "unparseable ISO-8601 date: \(raw)")
            }
            return date
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, e in
            var container = e.singleValueContainer()
            try container.encode(formatISO8601(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /** For on-disk config only, never a wire frame. The no-interior-newlines
        rule protects NDJSON line framing, and devservers.json is a file a person
        reads, edits, and diffs, so it gets the same deterministic sorted keys
        with indentation. */
    public static func fileEncoder() -> JSONEncoder {
        let encoder = encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func formatISO8601(_ date: Date) -> String {
        /** The fractional digits come from the ms integer directly:
            ISO8601FormatStyle TRUNCATES fractional seconds, so formatting
            Double(ms)/1000 (which can sit a hair below the true ms) would emit
            ms-1 and break round-trip equality. */
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        /** Floored, not truncated. Swift's `/` and `%` round toward zero, so a
            pre-1970 date took the second that is too late and a remainder that
            is negative, emitting `.-500Z`, which nothing can parse back. Every
            date directa formats today is `Date()` or a parse of its own output,
            so this is not reachable; a formatter that can emit text its own
            parser rejects is worth closing anyway. Identical output for every
            non-negative value, which is what the round-trip goldens pin. */
        let seconds = Int64((Double(ms) / 1000).rounded(.down))
        let millis = Int(ms - seconds * 1000)
        let base = iso8601Plain.format(Date(timeIntervalSince1970: Double(seconds)))
        return base.replacing("Z", with: String(format: ".%03dZ", millis))
    }

    /** The wire and file format carry millisecond precision, and Date equality
        across a store/parse round trip only holds if every path derives its
        Double from the same millisecond integer. canonicalMs is that fixpoint:
        format canonicalizes before emitting, parse canonicalizes after reading,
        so Date -> string -> Date is bit-identical. */
    public static func canonicalMs(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    public static func parseISO8601(_ string: String) -> Date? {
        let parsed = (try? iso8601Fractional.parse(string)) ?? (try? iso8601Plain.parse(string))
        return parsed.map(canonicalMs)
    }

    /** FormatStyle values are Sendable structs, unlike ISO8601DateFormatter.
        The fractional style exists for parsing only; see formatISO8601. */
    private static let iso8601Fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso8601Plain = Date.ISO8601FormatStyle()
}

/** Stable machine-readable failure codes agents branch on. Append-only. */
public enum WireErrorCode: String, Codable, Sendable {
    case alreadyExists = "already-exists"
    case configInvalid = "config-invalid"
    /** The daemon is up and accepting but has not finished bringing supervised
        servers back, so it declines work rather than acting on half-restored
        state. Distinct from `daemon-unreachable`, which means nothing answered:
        a client must retry this one and must not start a second daemon. */
    case daemonStarting = "daemon-starting"
    case daemonUnreachable = "daemon-unreachable"
    case internalError = "internal-error"
    case notFound = "not-found"
    case notTrusted = "not-trusted"
    case portDrift = "port-drift"
    case portHeld = "port-held"
    case resourceLocked = "resource-locked"
    case resourceMutated = "resource-mutated"
    case spawnFailed = "spawn-failed"
    case usage
    case versionMismatch = "version-mismatch"
}

/** Wire and CLI error shape; `hint` is the literal remediation command when one exists. */
public struct WireError: Codable, Equatable, Error, Sendable {
    public var code: WireErrorCode
    public var hint: String?
    public var message: String

    public init(code: WireErrorCode, hint: String? = nil, message: String) {
        self.code = code
        self.hint = hint
        self.message = message
    }
}

/** Without this, `localizedDescription` renders a WireError as "The operation
    couldn't be completed. (DirectaKit.WireError error 1.)", which is what the
    menu bar logged, and showed in the popover, for a failed agent register. It
    names nothing wrong, nowhere it happened, and nothing to do about it, while
    the message and the remediation hint sat unread on the value itself. Every
    caller that reaches for `localizedDescription` now gets those instead. */
extension WireError: LocalizedError {
    public var errorDescription: String? {
        guard let hint else { return message }
        return "\(message) (\(hint))"
    }
}

/** A typed request frame. `params` is method-specific; the daemon sniffs
    `{id, method}` first, then re-decodes the full typed frame. */
public struct WireRequest<Params: Codable & Sendable>: Codable, Sendable {
    public var id: String
    public var method: String
    public var params: Params

    public init(id: String, method: String, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/** Minimal envelope used to sniff a frame before typed decoding. */
public struct WireRequestHead: Codable, Sendable {
    public var id: String
    public var method: String
}

public struct WireResponse<Result: Codable & Sendable>: Codable, Sendable {
    public var error: WireError?
    public var id: String
    public var ok: Bool
    public var result: Result?

    public init(error: WireError? = nil, id: String, ok: Bool, result: Result? = nil) {
        self.error = error
        self.id = id
        self.ok = ok
        self.result = result
    }
}

public struct WireResponseHead: Codable, Sendable {
    public var error: WireError?
    public var id: String
    public var ok: Bool
}

/** Server-push frame (hello, and later log/status/event streams). */
public struct WireEvent<Params: Codable & Sendable>: Codable, Sendable {
    public var event: String
    public var params: Params

    public init(event: String, params: Params) {
        self.event = event
        self.params = params
    }
}

public struct WireEventHead: Codable, Sendable {
    public var event: String
}

public struct HelloParams: Codable, Equatable, Sendable {
    public var daemonVersion: String
    public var proto: Int

    public init(daemonVersion: String, proto: Int) {
        self.daemonVersion = daemonVersion
        self.proto = proto
    }
}

/** Placeholder params/result for methods that need none. */
public struct WireEmpty: Codable, Equatable, Sendable {
    public init() {}
}

/** Method names; string-typed on the wire, enum-checked in code. */
public enum WireMethod: String, CaseIterable, Sendable {
    case daemonInfo = "daemon.info"
    case daemonShutdown = "daemon.shutdown"
    case eventsQuery = "events.query"
    case groupDown = "group.down"
    case groupUp = "group.up"
    case lockAcquire = "lock.acquire"
    case lockRelease = "lock.release"
    case lockStatus = "lock.status"
    case logsMark = "logs.mark"
    case logsQuery = "logs.query"
    case projectCheck = "project.check"
    case projectInitConfig = "project.initConfig"
    case projectTrust = "project.trust"
    case projectWriteConfig = "project.writeConfig"
    case serverEnsure = "server.ensure"
    case serverRegister = "server.register"
    case serverRestart = "server.restart"
    case serverStart = "server.start"
    case serverStatus = "server.status"
    case serverStop = "server.stop"
    case serverUnregister = "server.unregister"
    case serverWait = "server.wait"
    case serverWhy = "server.why"
}

// MARK: - Method payloads

public struct ServerTargetParams: Codable, Equatable, Sendable {
    public var name: String
    public var port: Int?
    public var project: String

    public init(name: String, port: Int? = nil, project: String) {
        self.name = name
        self.port = port
        self.project = project
    }
}

public struct ProjectParams: Codable, Equatable, Sendable {
    public var name: String?
    public var project: String

    public init(name: String? = nil, project: String) {
        self.name = name
        self.project = project
    }
}

public struct RegisterParams: Codable, Equatable, Sendable {
    public var project: String
    public var spec: ServerSpec

    public init(project: String, spec: ServerSpec) {
        self.project = project
        self.spec = spec
    }
}

public struct EnsureParams: Codable, Equatable, Sendable {
    public var name: String
    /** One-shot port override for this ensure/start; flows through effectivePort. */
    public var port: Int?
    public var project: String
    public var timeoutSeconds: Double

    public init(name: String, port: Int? = nil, project: String, timeoutSeconds: Double) {
        self.name = name
        self.port = port
        self.project = project
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct WaitParams: Codable, Equatable, Sendable {
    public var condition: WaitCondition
    public var name: String
    public var project: String
    public var timeoutSeconds: Double

    public init(condition: WaitCondition, name: String, project: String, timeoutSeconds: Double) {
        self.condition = condition
        self.name = name
        self.project = project
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct ServerResult: Codable, Equatable, Sendable {
    public var server: ServerStatus

    public init(server: ServerStatus) {
        self.server = server
    }
}

public struct ServerListResult: Codable, Equatable, Sendable {
    public var servers: [ServerStatus]
    /** Whether the scoped project's committed config is trusted; absent for
        machine-wide queries. The hook only advertises trusted projects. */
    public var trusted: Bool?

    public init(servers: [ServerStatus], trusted: Bool? = nil) {
        self.servers = servers
        self.trusted = trusted
    }
}

/** A stop and a re-ensure as one daemon-side transition. Doing it from a client
    leaves a window where another session's ensure lands between the two, and a
    refusal (a held resource, a broken config) arrives after the server is
    already down. `names` nil restarts every server in the project. */
public struct RestartParams: Codable, Equatable, Sendable {
    public var names: [String]?
    /** One-shot port override, same pipeline as ensure and start. */
    public var port: Int?
    public var project: String
    public var timeoutSeconds: Double

    public init(
        names: [String]? = nil, port: Int? = nil, project: String, timeoutSeconds: Double = 60
    ) {
        self.names = names
        self.port = port
        self.project = project
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct GroupParams: Codable, Equatable, Sendable {
    public var only: [String]?
    /** One-shot port override applied to each server this up starts. */
    public var port: Int?
    public var project: String
    public var timeoutSeconds: Double

    public init(
        only: [String]? = nil, port: Int? = nil, project: String, timeoutSeconds: Double = 60
    ) {
        self.only = only
        self.port = port
        self.project = project
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct GroupResult: Codable, Equatable, Sendable {
    public var results: [EnsureResult]

    public init(results: [EnsureResult]) {
        self.results = results
    }
}

public struct LockParams: Codable, Equatable, Sendable {
    /** The lock auto-releases when this pid dies (a crashed harness never
        wedges the resource). */
    public var holderPid: Int
    /** When false (the default), acquire the mutex without stopping servers that
        declare the resource; when true, stop them for the hold and resume on
        release. Optional so older clients keep decoding. */
    public var pause: Bool?
    public var project: String
    public var resource: String
    /** Per-server health wait used when this hold ends (release or orphan
        cleanup). Optional so older clients keep decoding. */
    public var resumeTimeoutSeconds: Double?

    public init(
        holderPid: Int,
        pause: Bool? = nil,
        project: String,
        resource: String,
        resumeTimeoutSeconds: Double? = nil
    ) {
        self.holderPid = holderPid
        self.pause = pause
        self.project = project
        self.resource = resource
        self.resumeTimeoutSeconds = resumeTimeoutSeconds
    }
}

/** In-memory and on-disk lock record. `paused` is who the daemon stopped for
    this hold so a crash mid-lock can resume them when the holder is gone. */
public struct LockHolder: Codable, Equatable, Sendable {
    /** Declaring servers this hold left running (the default). Absent when
        `--pause` stopped them, and on files written before this field existed. */
    public var live: [String]?
    /** Whether this hold paused declarers. An empty `paused` is ambiguous on its
        own: nothing was running, or nothing was asked to stop. */
    public var pause: Bool?
    public var paused: [String]
    public var pid: Int
    public var resumeTimeoutSeconds: Double?
    public var since: Date

    public init(
        live: [String]? = nil, pause: Bool? = nil, paused: [String] = [], pid: Int,
        resumeTimeoutSeconds: Double? = nil, since: Date
    ) {
        self.live = live
        self.pause = pause
        self.paused = paused
        self.pid = pid
        self.resumeTimeoutSeconds = resumeTimeoutSeconds
        self.since = since
    }
}

public struct LockStatusParams: Codable, Equatable, Sendable {
    public var project: String
    public var resource: String

    public init(project: String, resource: String) {
        self.project = project
        self.resource = resource
    }
}

/** Who, if anyone, holds a resource right now. Read-only: a contended acquire
    asks once so the waiting run can name the holder instead of looking hung,
    which is what stops someone killing the run that is making progress. */
public struct LockStatusResult: Codable, Equatable, Sendable {
    public var holder: LockHolder?

    public init(holder: LockHolder? = nil) {
        self.holder = holder
    }
}

/** Result of lock.acquire / lock.release: which servers were paused or resumed. */
public struct LockResult: Codable, Equatable, Sendable {
    /** Declaring servers this hold left running (the default). */
    public var live: [String]?
    public var paused: [String]
    /** Absolute path to the resource's declared state, when a declarer names
        one. The daemon resolves it because it already holds the merged view;
        a second resolution in the CLI could disagree with the pause loop's. */
    public var statePath: String?

    public init(live: [String]? = nil, paused: [String] = [], statePath: String? = nil) {
        self.live = live
        self.paused = paused
        self.statePath = statePath
    }
}

/** Persisted resource locks (`locks.json`). Optional on load so a missing or
    pre-feature file is just empty. */
public struct LocksFile: Codable, Sendable {
    public var locks: [String: LockHolder]

    public init(locks: [String: LockHolder] = [:]) {
        self.locks = locks
    }
}

public struct ProjectOnlyParams: Codable, Equatable, Sendable {
    public var project: String

    public init(project: String) {
        self.project = project
    }
}

public struct WriteConfigParams: Codable, Equatable, Sendable {
    /** hash8 of the bytes the editor loaded; the daemon rejects on mismatch so
        an IDE's concurrent save is never silently clobbered. Empty = file must
        not exist yet. */
    public var baselineHash: String
    public var content: String
    public var project: String

    public init(baselineHash: String, content: String, project: String) {
        self.baselineHash = baselineHash
        self.content = content
        self.project = project
    }
}

public struct CheckResult: Codable, Equatable, Sendable {
    /** The host a start from this directory would actually use, when it differs
        from `host`. Produced for a `directa.local.json` overlay; a linked
        worktree is deliberately absent, because the declared host is used
        unchanged there so any origin the app itself pins (an auth callback, a
        CORS allow list, an API key referrer) keeps working. Omitted when it
        matches. */
    public var effectiveHost: String?
    public var effectiveHostReason: EffectiveHostReason?
    public var errors: [String]
    /** The host the file declares. */
    public var host: String?
    /** One entry per server whose effective host differs from the project's. */
    public var serverHosts: [EffectiveHost]?
    public var servers: [String]
    public var warnings: [String]
    /** Sanitized checkout-directory name when this directory is a linked git
        worktree; nil for a main checkout. Display only: the declared host is
        used unchanged, and the worktree name surfaces here and in
        status.worktree instead. */
    public var worktree: String?

    public init(
        effectiveHost: String? = nil, effectiveHostReason: EffectiveHostReason? = nil,
        errors: [String] = [], host: String? = nil, serverHosts: [EffectiveHost]? = nil,
        servers: [String] = [], warnings: [String] = [], worktree: String? = nil
    ) {
        self.effectiveHost = effectiveHost
        self.effectiveHostReason = effectiveHostReason
        self.errors = errors
        self.host = host
        self.serverHosts = serverHosts
        self.servers = servers
        self.warnings = warnings
        self.worktree = worktree
    }
}

/** How an init writes against whatever is already on disk. */
public enum ConfigInitMode: String, Codable, Sendable {
    /** Refuse when devservers.json already exists. */
    case create
    /** Add or replace only the named servers; every other entry survives. */
    case merge
    /** Rewrite the whole file from the projection. */
    case replace
}

public struct InitConfigParams: Codable, Equatable, Sendable {
    /** Compute the content and return it without touching disk. */
    public var dryRun: Bool?
    /** Overwrite an existing file (replace) or an existing entry (merge). */
    public var force: Bool?
    /** Include the servers the daemon already knows for this project. Default
        true: recovering a lost file is why this method exists. */
    public var fromDaemon: Bool?
    public var host: String?
    public var mode: ConfigInitMode
    public var project: String
    /** Extra declarations from the caller, projected alongside the daemon's and
        winning on a name collision. */
    public var servers: [ServerSpec]?

    public init(
        dryRun: Bool? = nil, force: Bool? = nil, fromDaemon: Bool? = nil, host: String? = nil,
        mode: ConfigInitMode, project: String, servers: [ServerSpec]? = nil
    ) {
        self.dryRun = dryRun
        self.force = force
        self.fromDaemon = fromDaemon
        self.host = host
        self.mode = mode
        self.project = project
        self.servers = servers
    }
}

public struct InitConfigResult: Codable, Equatable, Sendable {
    public var check: CheckResult
    /** The exact bytes written, so a dry run and the goldens can assert them. */
    public var content: String
    /** Declared config the projection cannot recover from runtime state. */
    public var notRecovered: [String]?
    public var path: String
    public var written: Bool

    public init(
        check: CheckResult, content: String, notRecovered: [String]? = nil, path: String,
        written: Bool
    ) {
        self.check = check
        self.content = content
        self.notRecovered = notRecovered
        self.path = path
        self.written = written
    }
}

public struct LogsQueryParams: Codable, Equatable, Sendable {
    public var grep: String?
    public var name: String
    public var project: String
    public var since: Date?
    public var sinceMark: String?
    public var streams: [LogStream]?
    public var tail: Int?

    public init(
        grep: String? = nil,
        name: String,
        project: String,
        since: Date? = nil,
        sinceMark: String? = nil,
        streams: [LogStream]? = nil,
        tail: Int? = nil
    ) {
        self.grep = grep
        self.name = name
        self.project = project
        self.since = since
        self.sinceMark = sinceMark
        self.streams = streams
        self.tail = tail
    }
}

public struct LogsQueryResult: Codable, Equatable, Sendable {
    public var lines: [LogRecord]

    public init(lines: [LogRecord]) {
        self.lines = lines
    }
}

public struct MarkParams: Codable, Equatable, Sendable {
    /** Mark every server in the project instead of one by name. */
    public var all: Bool?
    public var label: String?
    public var name: String?
    public var project: String
    public var text: String

    public init(all: Bool? = nil, label: String? = nil, name: String? = nil, project: String, text: String) {
        self.all = all
        self.label = label
        self.name = name
        self.project = project
        self.text = text
    }
}

public struct MarkResult: Codable, Equatable, Sendable {
    public var marks: [PlacedMark]

    public init(marks: [PlacedMark]) {
        self.marks = marks
    }
}

public struct PlacedMark: Codable, Equatable, Sendable {
    public var at: Date
    public var id: String
    public var server: String

    public init(at: Date, id: String, server: String) {
        self.at = at
        self.id = id
        self.server = server
    }
}

public struct EventsQueryParams: Codable, Equatable, Sendable {
    public var project: String?
    public var since: Date?
    public var sinceMark: String?
    public var tail: Int?

    public init(project: String? = nil, since: Date? = nil, sinceMark: String? = nil, tail: Int? = nil) {
        self.project = project
        self.since = since
        self.sinceMark = sinceMark
        self.tail = tail
    }
}

public struct EventsQueryResult: Codable, Equatable, Sendable {
    public var events: [EventRecord]

    public init(events: [EventRecord]) {
        self.events = events
    }
}

// MARK: - NDJSON framing

/** Incremental NDJSON line assembler: feed raw bytes, get complete frames.
    JSONEncoder never emits interior newlines (no prettyPrinted), so framing on
    0x0A is safe. */
public struct NDJSONBuffer: Sendable {
    private var buffer = Data()

    public init() {}

    /** Appends bytes and returns any newly completed lines (without the newline). */
    public mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

public enum NDJSON {
    /** Encodes one frame with its trailing newline. */
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONCoding.encoder().encode(value)
        data.append(0x0A)
        return data
    }
}
