import Foundation
import os

/** A kind of in-flight work the daemon's telemetry counts. The raw values are
    the names telemetry.log and scripts/daemon-deaths.sh read. */
public enum ActivityKind: String, CaseIterable, Codable, Sendable {
    case git
    case launchctl
    case logShow = "log-show"
    case lsof
    case ps
    case request
    case restart
    case spawnWait = "spawn-wait"
    case stop
    case stopWait = "stop-wait"
    case subprocess

    /** Work that holds a thread in a synchronous wait (a child process the
        caller blocks on). A mark is written when one outlasts
        `TelemetryCadence.slowOperationSeconds`. */
    public var isBlocking: Bool {
        switch self {
        case .git, .launchctl, .logShow, .lsof, .ps, .subprocess: true
        case .request, .restart, .spawnWait, .stop, .stopWait: false
        }
    }

    /** Work that switches the sampler to its fast cadence. Requests are left
        out because a `directa monitor` polls every second forever, and the
        boot-time `log show` is left out because the daemon runs it on
        itself. */
    public var triggersBurst: Bool {
        switch self {
        case .logShow, .request: false
        case .git, .launchctl, .lsof, .ps, .restart, .spawnWait, .stop, .stopWait, .subprocess: true
        }
    }

    /** The kind for a synchronous child process, named by its executable. */
    public static func forExecutable(_ path: String) -> ActivityKind {
        switch (path as NSString).lastPathComponent {
        case "git": .git
        case "launchctl": .launchctl
        case "log": .logShow
        case "lsof": .lsof
        case "ps": .ps
        default: .subprocess
        }
    }
}

/** How many of one kind of work are in flight, and the one waiting longest. */
public struct ActivityGroup: Codable, Equatable, Sendable {
    public var count: Int
    public var oldestLabel: String
    public var oldestSeconds: Double

    public init(count: Int, oldestLabel: String, oldestSeconds: Double) {
        self.count = count
        self.oldestLabel = oldestLabel
        self.oldestSeconds = oldestSeconds
    }
}

/** One piece of in-flight work, for the longest-running list. */
public struct InFlightEntry: Codable, Equatable, Sendable {
    public var kind: ActivityKind
    public var label: String
    public var seconds: Double

    public init(kind: ActivityKind, label: String, seconds: Double) {
        self.kind = kind
        self.label = label
        self.seconds = seconds
    }
}

/** What the daemon is doing at one instant, read without awaiting any actor. */
public struct ActivitySnapshot: Codable, Equatable, Sendable {
    public var connectedClients: Int
    /** The longest-running work of every kind, oldest first, capped at
        `DaemonActivity.longestRunningCap`. */
    public var longestRunning: [InFlightEntry]
    /** Keyed by `ActivityKind` raw value; wire requests are under `requests`. */
    public var operations: [String: ActivityGroup]
    /** Keyed by wire method. */
    public var requests: [String: ActivityGroup]
    /** Supervisor count per phase. */
    public var serverPhases: [String: Int]

    public init(
        connectedClients: Int, longestRunning: [InFlightEntry], operations: [String: ActivityGroup],
        requests: [String: ActivityGroup], serverPhases: [String: Int]
    ) {
        self.connectedClients = connectedClients
        self.longestRunning = longestRunning
        self.operations = operations
        self.requests = requests
        self.serverPhases = serverPhases
    }
}

/** The in-flight registry the telemetry sampler reads. Every call takes one
    unfair lock for a few dictionary operations and never suspends, so a
    snapshot answers even while every cooperative-pool thread is blocked,
    which is the condition it exists to record. */
public final class DaemonActivity: Sendable {
    public static let shared = DaemonActivity()

    /** The longest-running list's length: enough to name what a starved pool
        is stuck behind, bounded so one snapshot line stays small. */
    public static let longestRunningCap = 8

    /** Labels past this length are cut, since a command line can be long. */
    public static let labelCap = 160

    /** Returned by `begin`, handed back to `end`. */
    public struct Token: Sendable {
        public let id: UInt64
        public let kind: ActivityKind
        public let label: String
        public let startedAt: ContinuousClock.Instant
    }

    /** What an observer hears: a begin, an end with its duration, or a job
        that waited past `TelemetryCadence.slowOperationSeconds` for a
        `BlockingLane` thread. */
    public enum Event: Sendable {
        case began(Token)
        case ended(Token, outcome: String?, seconds: Double)
        case laneWaited(lane: String, seconds: Double)
    }

    private struct State {
        var clients = 0
        var inFlight: [UInt64: Token] = [:]
        var lastTriggerAt: ContinuousClock.Instant?
        var nextID: UInt64 = 0
        var observer: (@Sendable (Event) -> Void)?
        var phases: [String: String] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func begin(_ kind: ActivityKind, label: String) -> Token {
        let now = ContinuousClock.now
        let trimmed = label.count > Self.labelCap ? String(label.prefix(Self.labelCap)) + "..." : label
        let (token, observer) = state.withLock { state in
            state.nextID &+= 1
            let token = Token(id: state.nextID, kind: kind, label: trimmed, startedAt: now)
            state.inFlight[token.id] = token
            if kind.triggersBurst { state.lastTriggerAt = now }
            return (token, state.observer)
        }
        observer?(.began(token))
        return token
    }

    public func end(_ token: Token, outcome: String? = nil) {
        let now = ContinuousClock.now
        let observer = state.withLock { state in
            state.inFlight[token.id] = nil
            if token.kind.triggersBurst { state.lastTriggerAt = now }
            return state.observer
        }
        observer?(.ended(token, outcome: outcome, seconds: Self.seconds(token.startedAt.duration(to: now))))
    }

    /** Brackets a synchronous call. */
    public func measure<T>(_ kind: ActivityKind, label: String, _ body: () throws -> T) rethrows -> T {
        let token = begin(kind, label: label)
        defer { end(token) }
        return try body()
    }

    public func recordLaneWait(lane: String, seconds: Double) {
        let observer = state.withLock { $0.observer }
        observer?(.laneWaited(lane: lane, seconds: seconds))
    }

    public func clientConnected() {
        state.withLock { $0.clients += 1 }
    }

    public func clientDisconnected() {
        state.withLock { $0.clients = max(0, $0.clients - 1) }
    }

    /** Records a supervisor's phase under a key unique to that supervisor
        (not its server id, which a replacement supervisor shares while the
        old one is still being released). */
    public func recordPhase(_ phase: String, key: String) {
        state.withLock { $0.phases[key] = phase }
    }

    public func forgetPhase(key: String) {
        state.withLock { $0.phases[key] = nil }
    }

    /** One observer at a time; nil removes it. Called outside the lock, on the
        thread that began or ended the work. */
    public func setObserver(_ observer: (@Sendable (Event) -> Void)?) {
        state.withLock { $0.observer = observer }
    }

    /** True while burst-triggering work is in flight, and the instant such
        work last began or ended. */
    public func triggerState() -> (inFlight: Bool, lastAt: ContinuousClock.Instant?) {
        state.withLock { state in
            (state.inFlight.values.contains { $0.kind.triggersBurst }, state.lastTriggerAt)
        }
    }

    public func snapshot(now: ContinuousClock.Instant = .now) -> ActivitySnapshot {
        let (clients, entries, phases) = state.withLock { state in
            (state.clients, Array(state.inFlight.values), state.phases)
        }
        var operations: [String: ActivityGroup] = [:]
        var requests: [String: ActivityGroup] = [:]
        for token in entries {
            let age = Self.seconds(token.startedAt.duration(to: now))
            let key = token.kind == .request ? token.label : token.kind.rawValue
            let label = token.kind == .request ? "" : token.label
            let merged: ActivityGroup
            if let group = token.kind == .request ? requests[key] : operations[key] {
                merged = ActivityGroup(
                    count: group.count + 1,
                    oldestLabel: age > group.oldestSeconds ? label : group.oldestLabel,
                    oldestSeconds: max(age, group.oldestSeconds))
            } else {
                merged = ActivityGroup(count: 1, oldestLabel: label, oldestSeconds: age)
            }
            if token.kind == .request {
                requests[key] = merged
            } else {
                operations[key] = merged
            }
        }
        let longest =
            entries
            .sorted { $0.startedAt < $1.startedAt }
            .prefix(Self.longestRunningCap)
            .map {
                InFlightEntry(kind: $0.kind, label: $0.label, seconds: Self.seconds($0.startedAt.duration(to: now)))
            }
        var phaseCounts: [String: Int] = [:]
        for phase in phases.values {
            phaseCounts[phase, default: 0] += 1
        }
        return ActivitySnapshot(
            connectedClients: clients, longestRunning: Array(longest), operations: operations,
            requests: requests, serverPhases: phaseCounts)
    }

    /** Millisecond resolution, which keeps snapshot lines short and stable. */
    public static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return ((Double(seconds) + Double(attoseconds) / 1e18) * 1000).rounded() / 1000
    }
}
