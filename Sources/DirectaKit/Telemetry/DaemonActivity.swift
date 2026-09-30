import Foundation
import os

/** A kind of in-flight work the daemon's telemetry counts. The raw values are
    the names telemetry.log and scripts/daemon-deaths.sh read. */
public enum ActivityKind: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
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

    /** Work that switches the sampler to its fast cadence. Requests are left
        out because a `directa monitor` polls every second forever, and
        `log show` because the daemon only runs it on itself at boot. Work of
        any kind begun inside `DaemonActivity.selfDirected` is left out too. */
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

extension ServerPhase: CodingKeyRepresentable {}

/** How many of one kind of work are in flight, and the one waiting longest. */
public struct ActivityGroup: Codable, Equatable, Sendable {
    public var count: Int
    /** The oldest item's label; nil for wire requests, whose group key is
        already the method. */
    public var oldestLabel: String?
    public var oldestSeconds: Double

    public init(count: Int, oldestLabel: String?, oldestSeconds: Double) {
        self.count = count
        self.oldestLabel = oldestLabel
        self.oldestSeconds = oldestSeconds
    }

    /** This group with one more item of the given age and label. */
    func adding(label: String?, seconds: Double) -> ActivityGroup {
        ActivityGroup(
            count: count + 1, oldestLabel: seconds > oldestSeconds ? label : oldestLabel,
            oldestSeconds: max(seconds, oldestSeconds))
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
    /** Every kind but `request`, which is grouped under `requests`. */
    public var operations: [ActivityKind: ActivityGroup]
    /** Keyed by wire method, as the request's line named it. */
    public var requests: [String: ActivityGroup]
    public var serverPhases: [ServerPhase: Int]

    public init(
        connectedClients: Int, longestRunning: [InFlightEntry], operations: [ActivityKind: ActivityGroup],
        requests: [String: ActivityGroup], serverPhases: [ServerPhase: Int]
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

    @TaskLocal private static var isSelfDirected = false

    /** Returned by `begin`, handed back to `end`. */
    public struct Token: Sendable {
        public let id: UInt64
        public let kind: ActivityKind
        public let label: String
        public let startedAt: ContinuousClock.Instant
        /** The kind triggers the fast cadence and the work was not begun
            inside `selfDirected`. */
        public let triggersBurst: Bool

        init(
            id: UInt64, kind: ActivityKind, label: String, startedAt: ContinuousClock.Instant,
            triggersBurst: Bool? = nil
        ) {
            self.id = id
            self.kind = kind
            self.label = label
            self.startedAt = startedAt
            self.triggersBurst = triggersBurst ?? kind.triggersBurst
        }
    }

    /** What an observer hears: a begin, an end with its duration, or a job
        that waited past `TelemetryMark.slowOperationSeconds` for a
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
        var phases: [String: ServerPhase] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /** Runs `body` with every piece of work begun inside it, on this thread
        or its task, kept from triggering the fast cadence: for the daemon's
        own boot-time reads of itself, which say nothing about load. */
    public static func selfDirected<T>(_ body: () throws -> T) rethrows -> T {
        try $isSelfDirected.withValue(true, operation: body)
    }

    public func begin(_ kind: ActivityKind, label: String) -> Token {
        let now = ContinuousClock.now
        let trimmed = label.count > Self.labelCap ? String(label.prefix(Self.labelCap)) + "..." : label
        let triggers = kind.triggersBurst && !Self.isSelfDirected
        let (token, observer) = state.withLock { state in
            state.nextID &+= 1
            let token = Token(id: state.nextID, kind: kind, label: trimmed, startedAt: now, triggersBurst: triggers)
            state.inFlight[token.id] = token
            if triggers { state.lastTriggerAt = now }
            return (token, state.observer)
        }
        observer?(.began(token))
        return token
    }

    public func end(_ token: Token, outcome: String? = nil) {
        let now = ContinuousClock.now
        let observer = state.withLock { state in
            state.inFlight[token.id] = nil
            if token.triggersBurst { state.lastTriggerAt = now }
            return state.observer
        }
        observer?(.ended(token, outcome: outcome, seconds: token.startedAt.duration(to: now).roundedSeconds))
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

    /** A disconnect with no matching connect is a counting bug in the
        caller: it traps in a debug build and is clamped at zero in release,
        where a wrong count must not take the daemon down. */
    public func clientDisconnected() {
        let unmatched = state.withLock { state -> Bool in
            guard state.clients > 0 else { return true }
            state.clients -= 1
            return false
        }
        if unmatched {
            assertionFailure("DaemonActivity.clientDisconnected called with no connected client")
        }
    }

    /** Records a supervisor's phase under a key unique to that supervisor
        (not its server id, which a replacement supervisor shares while the
        old one is still being released). */
    public func recordPhase(_ phase: ServerPhase, key: String) {
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
            (state.inFlight.values.contains(where: \.triggersBurst), state.lastTriggerAt)
        }
    }

    public func snapshot(now: ContinuousClock.Instant = .now) -> ActivitySnapshot {
        let (clients, entries, phases) = state.withLock { state in
            (state.clients, Array(state.inFlight.values), state.phases)
        }
        var operations: [ActivityKind: ActivityGroup] = [:]
        var requests: [String: ActivityGroup] = [:]
        for token in entries {
            let age = token.startedAt.duration(to: now).roundedSeconds
            if token.kind == .request {
                requests[token.label] = Self.merge(requests[token.label], label: nil, seconds: age)
            } else {
                operations[token.kind] = Self.merge(operations[token.kind], label: token.label, seconds: age)
            }
        }
        let longest =
            entries
            .sorted { $0.startedAt < $1.startedAt }
            .prefix(Self.longestRunningCap)
            .map {
                InFlightEntry(kind: $0.kind, label: $0.label, seconds: $0.startedAt.duration(to: now).roundedSeconds)
            }
        var phaseCounts: [ServerPhase: Int] = [:]
        for phase in phases.values {
            phaseCounts[phase, default: 0] += 1
        }
        return ActivitySnapshot(
            connectedClients: clients, longestRunning: Array(longest), operations: operations,
            requests: requests, serverPhases: phaseCounts)
    }

    private static func merge(_ group: ActivityGroup?, label: String?, seconds: Double) -> ActivityGroup {
        group?.adding(label: label, seconds: seconds)
            ?? ActivityGroup(count: 1, oldestLabel: label, oldestSeconds: seconds)
    }
}
