import ArgumentParser
import Darwin
import DirectaKit
import Foundation
import os

/** `directa monitor <name>`: a client-side polling loop over `logs.query` and
    `server.status` that shapes daemon output for an agent's own streaming
    tool (Claude Code's Monitor, Grok Build's monitor). `MonitorStream`
    (DirectaKit) owns every shaping decision (namespaces, sanitizing,
    repeat suppression, budgets); this file owns the network loop, the
    daemon's transient states, and the process's lifetime. */
struct Monitor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            "Stream one server's output shaped for an agent's own monitor tool: Claude Code's Monitor tool, or Grok Build's monitor tool."
    )

    @Option(
        help:
            "Total stderr lines for this run (\(MonitorFlagOption.rangeText(MonitorLimits.errorsPerArmRange))); re-arm (run the command again) to reset.",
        transform: MonitorFlagOption.lines(in: MonitorLimits.errorsPerArmRange))
    var errorsPerArm = MonitorLimits.errorsPerArmDefault

    @Option(
        help: "Stderr lines allowed per minute (\(MonitorFlagOption.rangeText(MonitorLimits.errorsPerMinuteRange))).",
        transform: MonitorFlagOption.lines(in: MonitorLimits.errorsPerMinuteRange))
    var errorsPerMinute = MonitorLimits.errorsPerMinuteDefault

    @OptionGroup var global: GlobalOptions

    @Option(
        help:
            "Total stdout lines for this run (\(MonitorFlagOption.rangeText(MonitorLimits.linesPerArmRange))); re-arm (run the command again) to reset.",
        transform: MonitorFlagOption.lines(in: MonitorLimits.linesPerArmRange))
    var linesPerArm = MonitorLimits.linesPerArmDefault

    @Option(
        help: "Stdout lines allowed per minute (\(MonitorFlagOption.rangeText(MonitorLimits.linesPerMinuteRange))).",
        transform: MonitorFlagOption.lines(in: MonitorLimits.linesPerMinuteRange))
    var linesPerMinute = MonitorLimits.linesPerMinuteDefault

    @Argument(help: "Server name.")
    var name: String

    @Option(
        help: "Seconds between polls (\(MonitorFlagOption.rangeText(MonitorLimits.tickRange))).",
        transform: MonitorFlagOption.tick)
    var tick = MonitorLimits.tickDefault

    func run() async throws {
        let project = global.resolvedProject()
        let budgets = MonitorBudgets(
            errorsPerArm: errorsPerArm, errorsPerMinute: errorsPerMinute, linesPerArm: linesPerArm,
            linesPerMinute: linesPerMinute)
        let config = MonitorRunConfig(budgets: budgets, name: name, project: project, tickSeconds: tick)
        let json = global.json

        /** Ignored once, for the life of the process: a write into a pipe or
            socket whose reader is gone must fail the write with EPIPE, never
            terminate the process by signal. */
        signal(SIGPIPE, SIG_IGN)

        /** Off by default: one line per `step()` call on stderr (never
            stdout, which carries the actual monitor output), so
            scripts/smoke.sh can count polls without any daemon-side
            instrumentation. Every `step()` call makes exactly one
            `logs.query`, attaching or ticking, so counting calls to
            `step()` is counting `logs.query` calls. */
        let debugPolls = ProcessInfo.processInfo.environment["DIRECTA_MONITOR_DEBUG"] == "1"

        let lifetime = MonitorLifetime()
        let loopTask = Task<MonitorRunOutcome, Never> {
            var session = MonitorSession(
                client: CLIRunner.client(), clock: SystemMonitorClock(), config: config)
            while !Task.isCancelled {
                let outcome = await session.step()
                if debugPolls {
                    CLIRunner.note("directa monitor: poll at \(Date())")
                }
                switch outcome {
                case .exit(let error):
                    return .failure(error)
                case .ended(let events):
                    Self.emit(events, json: json)
                    return .success
                case .endedWithError(let events, let error):
                    Self.emit(events, json: json)
                    return .endedWithError(error)
                case .events(let events, let delaySeconds):
                    /** A write that fails (EPIPE, since SIGPIPE is ignored
                        above) means the reader is already gone; the kqueue
                        watcher usually catches this first, but a write
                        landing in the same instant must not be retried or
                        looped on, so this is treated as the same reader-gone
                        exit: no further write attempted. */
                    guard Self.emit(events, json: json) else { return .success }
                    do {
                        try await Task.sleep(for: .seconds(delaySeconds))
                    } catch {
                        /** Cancelled mid-sleep: the reader is gone, so there
                            is no one to print an end marker to. */
                        return .success
                    }
                }
            }
            return .success
        }
        lifetime.attach(to: loopTask)
        switch await loopTask.value {
        case .success:
            return
        case .endedWithError(let error):
            Foundation.exit(CLIRunner.exitStatus(for: error.code))
        case .failure(let error):
            CLIRunner.fail(error, json: json)
        }
    }

    /** Returns false when the flush itself failed (EPIPE: nothing is reading
        anymore), so the caller can stop instead of retrying or looping on a
        write that will keep failing the same way. */
    @discardableResult
    private static func emit(_ events: [MonitorEvent], json: Bool) -> Bool {
        guard !events.isEmpty else { return true }
        if json {
            let encoder = JSONCoding.encoder()
            for event in events {
                if let data = try? encoder.encode(event) {
                    print(String(decoding: data, as: UTF8.self))
                }
            }
        } else {
            for event in events {
                print(event.humanLine)
            }
        }
        /** `print` block-buffers into a pipe; flushing after every batch is
            what lets an agent's Monitor tool see a line the moment it
            arrives instead of once kilobytes pile up (the same reason
            `Logs.emit` flushes under `--follow`). `fflush` also surfaces
            write(2)'s result for those buffered writes. */
        return fflush(nil) == 0
    }
}

/** Screens every monitor budget flag at the parser boundary: a value outside
    `MonitorLimits`' range is refused by the argument parser (exit 64) with a
    message naming the range,
    rather than reaching `MonitorStream` and silently behaving as an
    unlimited or a zero budget. ArgumentParser prefixes each message with the
    flag it came from. */
enum MonitorFlagOption {
    static func lines(in range: ClosedRange<Int>) -> @Sendable (String) throws -> Int {
        { raw in
            guard let value = Int(raw) else {
                throw ValidationError("'\(raw)' is not a whole number of lines")
            }
            guard range.contains(value) else {
                throw ValidationError("must be between \(range.lowerBound) and \(range.upperBound), got \(raw)")
            }
            return value
        }
    }

    static func tick(_ raw: String) throws -> Double {
        guard let value = Double(raw), value.isFinite else {
            throw ValidationError("'\(raw)' is not a number of seconds")
        }
        let range = MonitorLimits.tickRange
        guard range.contains(value) else {
            throw ValidationError(
                "must be between \(formatSeconds(range.lowerBound)) and \(formatSeconds(range.upperBound)) seconds, got \(raw)")
        }
        return value
    }

    /** "1-1200": the range as the help text shows it. */
    static func rangeText(_ range: ClosedRange<Int>) -> String {
        "\(range.lowerBound)-\(range.upperBound)"
    }

    static func rangeText(_ range: ClosedRange<Double>) -> String {
        "\(formatSeconds(range.lowerBound))-\(formatSeconds(range.upperBound))"
    }

    /** A whole number of seconds (60) prints as "60" rather than "60.0", so
        the message and the help text read like something a person wrote. */
    private static func formatSeconds(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/** The two daemon requests the monitor loop makes, behind a protocol so
    every transient, budget, and lifetime decision is unit-tested against a
    fake without a socket. */
protocol MonitorRequesting: Sendable {
    func fetchStatus(_ params: ProjectParams) async throws -> ServerListResult
    func queryLogs(_ params: LogsQueryParams) async throws -> LogsQueryResult
}

extension DaemonClient: MonitorRequesting {
    /** `request` is not itself `async`, and this call is same-actor (no hop
        to await), but the protocol requirement is `async` so a fake in
        tests can suspend; the actor isolation alone is what makes this a
        safe synchronous call here. */
    func fetchStatus(_ params: ProjectParams) async throws -> ServerListResult {
        try request(.serverStatus, params: params, expecting: ServerListResult.self)
    }

    func queryLogs(_ params: LogsQueryParams) async throws -> LogsQueryResult {
        try request(.logsQuery, params: params, expecting: LogsQueryResult.self)
    }
}

/** Wall time behind a protocol so a test drives every backoff, status-poll,
    and hard-cap decision without a real clock. The sleep between steps is
    the caller's (`Monitor.run`), outside `MonitorSession`, so it needs no
    seam: a step only returns the delay. */
protocol MonitorClock: Sendable {
    func now() async -> Date
}

struct SystemMonitorClock: MonitorClock {
    func now() async -> Date { Date() }
}

/** Everything one `directa monitor` invocation needs that does not change
    once parsed. */
struct MonitorRunConfig: Sendable {
    var budgets: MonitorBudgets
    var name: String
    var project: String
    var tickSeconds: Double
}

/** How the daemon last failed to answer, so the loop reports it once per
    transition rather than once per retry, and applies the right recovery
    rule: `configInvalid` and `restoring` retry until the daemon resolves
    them on its own; `unreachable` (nothing answered) and `unreadable` (an
    answer this client could not decode) share one clock that ends the run
    past `MonitorRunTuning.unreachableGiveUpSeconds` of continuous failure.
    Every other daemon error is not transient: it ends the run. */
enum MonitorTransient: Equatable {
    case configInvalid
    case restoring
    case unreachable
    case unreadable

    /** Nil for a code that is not a transient state of the daemon. */
    init?(_ code: WireErrorCode) {
        switch code {
        case .configInvalid: self = .configInvalid
        case .daemonStarting: self = .restoring
        case .daemonUnreachable: self = .unreachable
        case .alreadyExists, .internalError, .notFound, .notTrusted, .portDrift, .portHeld,
            .projectStillExists, .requestTooLarge, .resourceLocked, .resourceMutated, .spawnFailed,
            .usage, .versionMismatch:
            return nil
        }
    }

    var countsTowardGiveUp: Bool { self == .unreachable || self == .unreadable }
}

/** Tunables for the loop itself, distinct from `MonitorLimits` (the budget
    flags and their ranges, shared with the parser boundary): nothing here is
    user-configurable, so nothing here needs to agree with a flag. */
enum MonitorRunTuning {
    /** The exponential backoff ceiling while a transient failure persists. */
    static let backoffCeilingSeconds: Double = 10
    static let statusPollInterval: TimeInterval = 10
    /** Continuous "the daemon is unreachable" past this long ends the run
        (mid-stream) or gives up on attaching (before any output), rather
        than retrying forever against a daemon that may be gone for good. */
    static let unreachableGiveUpSeconds: TimeInterval = 60
}

/** One `directa monitor` invocation's state machine: attaches (confirms the
    server exists, feature-gates the daemon, prints the start marker), then
    ticks (one `logs.query` past the last cursor, an occasional
    `server.status` for health, transient/backoff handling, and the
    `MonitorLimits.hardCapSeconds` cap). Free of stdout and process lifetime,
    so a fake client and clock exercise every decision. */
struct MonitorSession: Sendable {
    enum StepOutcome: Sendable {
        /** The run is over on its own initiative (not-found, 60 s
            unreachable, or the hard cap); `events` include the
            `MonitorStream.ended`/`endedAtHardCap` marker. */
        case ended([MonitorEvent])
        /** The run is over because the daemon refused it after attaching
            (an error that is not a transient state, or a daemon too old to
            report `totals`): `events` end with a line naming the message,
            and the process exits with the status that error maps to. */
        case endedWithError([MonitorEvent], WireError)
        case events([MonitorEvent], delaySeconds: Double)
        /** Only ever produced before attaching: the caller may still exit
            through `CLIRunner.fail`, since nothing has printed yet. */
        case exit(WireError)
    }

    /** Everything a run carries once attached. */
    private struct Streaming: Sendable {
        var cursor: LogCursor
        var lastHealth: String
        var lastStatusPollAt: Date
        let startedAt: Date
        var stream: MonitorStream
    }

    private enum State: Sendable {
        case attaching
        case streaming(Streaming)
    }

    /** What a transient failure does next: retry after `delay` (with the
        transition's report, if any), or give up because the daemon has
        failed to answer for `MonitorRunTuning.unreachableGiveUpSeconds`. */
    private enum TransientStep {
        case giveUp
        case retry([MonitorEvent], delay: Double)
    }

    /** The label transient lines render under before attaching, when there
        is no `MonitorStream` yet: the bare server name, sanitized. */
    private let attachingLabel: String
    private let client: any MonitorRequesting
    private let clock: any MonitorClock
    private let config: MonitorRunConfig
    private var currentBackoff: Double
    private var state: State = .attaching
    private var transientKind: MonitorTransient?
    private var unreachableSince: Date?

    init(client: any MonitorRequesting, clock: any MonitorClock, config: MonitorRunConfig) {
        attachingLabel = MonitorSanitizer.sanitizeLabel(config.name)
        self.client = client
        self.clock = clock
        self.config = config
        currentBackoff = config.tickSeconds
    }

    mutating func step() async -> StepOutcome {
        switch state {
        case .attaching:
            return await attachStep()
        case .streaming(var streaming):
            let outcome = await tickStep(&streaming)
            state = .streaming(streaming)
            return outcome
        }
    }

    /** One `tail: 0` query plus one status call, in that order. `tail: 0`
        takes the daemon's tail fast path: the family's end cursor, no
        lines, and no read of the log's history (a per-stream trim of 0
        would scan the whole family forward to count totals nobody reads).
        The query feature-gates the daemon on `cursor` and, via `not-found`,
        confirms the name exists before the status call composes the
        marker; `totals` is checked on the first tick, the first query that
        carries it. */
    private mutating func attachStep() async -> StepOutcome {
        let now = await clock.now()
        do {
            let logsResult = try await client.queryLogs(
                LogsQueryParams(name: config.name, project: config.project, tail: 0))
            guard let cursor = logsResult.cursor else {
                return .exit(Logs.olderDaemon)
            }
            let statusResult = try await client.fetchStatus(
                ProjectParams(name: config.name, project: config.project))
            guard let server = statusResult.servers.first(where: { $0.server == config.name }) else {
                return .exit(ProjectConfigLoader.serverNotFound(name: config.name, project: config.project))
            }
            let stream = MonitorStream(
                config: MonitorConfig(
                    budgets: config.budgets, clockStart: now, label: Self.rawLabel(name: config.name, server: server),
                    serverName: config.name))
            let description = Self.statusDescription(for: server)
            let events = stream.attached(
                MonitorAttachSummary(checkoutPath: config.project, statusDescription: description))
            transientKind = nil
            unreachableSince = nil
            currentBackoff = config.tickSeconds
            state = .streaming(
                Streaming(cursor: cursor, lastHealth: description, lastStatusPollAt: now, startedAt: now, stream: stream))
            return .events(events, delaySeconds: config.tickSeconds)
        } catch let error as WireError {
            if error.code == .notFound {
                return .exit(ProjectConfigLoader.serverNotFound(name: config.name, project: config.project))
            }
            guard let kind = MonitorTransient(error.code) else { return .exit(error) }
            return attachTransient(kind, detail: error.message, at: now)
        } catch {
            return attachTransient(.unreadable, detail: String(describing: error), at: now)
        }
    }

    private mutating func attachTransient(_ kind: MonitorTransient, detail: String, at now: Date) -> StepOutcome {
        switch handleTransient(kind, detail: detail, at: now, label: attachingLabel) {
        case .retry(let events, let delay):
            return .events(events, delaySeconds: delay)
        case .giveUp:
            let seconds = Int(MonitorRunTuning.unreachableGiveUpSeconds)
            if kind == .unreadable {
                return .exit(
                    WireError(
                        code: .internalError, hint: "run: directa daemon restart",
                        message: "the daemon's answers could not be read for \(seconds)s: \(detail)"))
            }
            return .exit(
                WireError(
                    code: .daemonUnreachable, hint: "run: directa daemon status",
                    message: "the daemon has been unreachable for \(seconds)s"))
        }
    }

    private func tickParams(after cursor: LogCursor) -> LogsQueryParams {
        LogsQueryParams(
            after: cursor, maxLineCharacters: MonitorLimits.truncationCharacterLimit, name: config.name,
            project: config.project,
            tailByStream: LogStreamCounts(
                err: MonitorLimits.fetchCap(for: .err), mark: MonitorLimits.fetchCap(for: .mark),
                out: MonitorLimits.fetchCap(for: .out), sys: MonitorLimits.fetchCap(for: .sys)))
    }

    /** What the daemon matched on each stream past `cursor` but did not
        return (its per-stream trim), stamped at the cursor it read past. */
    private static func tick(
        _ result: LogsQueryResult, totals: LogStreamTotals, after cursor: LogCursor, at now: Date,
        health: String? = nil
    ) -> MonitorTick {
        var trimmed: [LogStream: Int] = [:]
        for streamKind in LogStream.allCases {
            let returned = result.lines.count { $0.stream == streamKind }
            let total = totals[streamKind]
            if total > returned { trimmed[streamKind] = total - returned }
        }
        return MonitorTick(at: now, health: health, records: result.lines, trimmed: trimmed, windowStart: cursor.at)
    }

    /** The cap's last word: one more read past the cursor, so lines that
        landed since the previous tick show before the end marker, whose
        command then starts where this read stopped. A failed read is an
        accepted loss here (the run is ending either way): the marker names
        the cursor already held, so its command still covers those lines. */
    private func finalDrain(cursor: LogCursor, stream: MonitorStream, at now: Date) async -> [MonitorEvent] {
        var stream = stream
        var events: [MonitorEvent] = []
        var resumeFrom = cursor
        let drained = try? await client.queryLogs(tickParams(after: cursor))
        if let drained, let next = drained.cursor, let totals = drained.totals {
            events = stream.ingest(Self.tick(drained, totals: totals, after: cursor, at: now))
            resumeFrom = next
        }
        return events + stream.endedAtHardCap(resumeFrom: resumeFrom.at)
    }

    private mutating func tickStep(_ streaming: inout Streaming) async -> StepOutcome {
        let now = await clock.now()
        if now.timeIntervalSince(streaming.startedAt) >= MonitorLimits.hardCapSeconds {
            return .ended(await finalDrain(cursor: streaming.cursor, stream: streaming.stream, at: now))
        }

        let logsResult: LogsQueryResult
        do {
            logsResult = try await client.queryLogs(tickParams(after: streaming.cursor))
        } catch let error as WireError {
            if error.code == .notFound {
                return .ended(streaming.stream.ended(reason: "server unregistered"))
            }
            guard let kind = MonitorTransient(error.code) else {
                return .endedWithError(streaming.stream.ended(reason: Self.reason(error)), error)
            }
            return tickTransient(kind, detail: error.message, stream: streaming.stream, at: now)
        } catch {
            return tickTransient(.unreadable, detail: String(describing: error), stream: streaming.stream, at: now)
        }

        transientKind = nil
        unreachableSince = nil
        currentBackoff = config.tickSeconds

        guard let nextCursor = logsResult.cursor, let totals = logsResult.totals else {
            /** The first query shaped to carry `totals`, or a daemon swapped
                for an older one mid-run: either way the per-tick accounting
                cannot be trusted, so the run ends the way attach refuses. */
            return .endedWithError(
                streaming.stream.ended(reason: Self.reason(Logs.olderDaemon)), Logs.olderDaemon)
        }

        var health: String?
        var endedFromStatus: [MonitorEvent]?
        if now.timeIntervalSince(streaming.lastStatusPollAt) >= MonitorRunTuning.statusPollInterval {
            do {
                let statusResult = try await client.fetchStatus(
                    ProjectParams(name: config.name, project: config.project))
                if let server = statusResult.servers.first(where: { $0.server == config.name }) {
                    let description = Self.statusDescription(for: server)
                    if description != streaming.lastHealth {
                        health = description
                        streaming.lastHealth = description
                    }
                    streaming.lastStatusPollAt = now
                } else {
                    endedFromStatus = streaming.stream.ended(reason: "server unregistered")
                }
            } catch let error as WireError {
                if error.code == .notFound {
                    endedFromStatus = streaming.stream.ended(reason: "server unregistered")
                }
                /** Any other failure here retries on the next tick (the poll
                    time has not been advanced); the logs.query call above
                    already reported a transient this tick when there was a
                    new one to report, and a second marker for the same
                    underlying failure would be noise. */
            } catch {
                /** Retried on the next tick, as above. */
            }
        }

        let tickEvents = streaming.stream.ingest(
            Self.tick(logsResult, totals: totals, after: streaming.cursor, at: now, health: health))
        streaming.cursor = nextCursor

        if let endedFromStatus {
            return .ended(tickEvents + endedFromStatus)
        }
        return .events(tickEvents, delaySeconds: config.tickSeconds)
    }

    private mutating func tickTransient(
        _ kind: MonitorTransient, detail: String, stream: MonitorStream, at now: Date
    ) -> StepOutcome {
        switch handleTransient(kind, detail: detail, at: now, label: stream.label) {
        case .retry(let events, let delay):
            return .events(events, delaySeconds: delay)
        case .giveUp:
            var stream = stream
            let seconds = Int(MonitorRunTuning.unreachableGiveUpSeconds)
            let reason =
                kind == .unreadable ? "daemon answers unreadable for \(seconds)s" : "daemon unreachable for \(seconds)s"
            return .ended(stream.ended(reason: reason))
        }
    }

    /** Shared by attach and every tick: reports a transient state once per
        transition, tracks how long the daemon has continuously failed to
        answer (unreachable or unreadable), and computes the next backoff
        delay. Gives up once that failure has lasted
        `MonitorRunTuning.unreachableGiveUpSeconds`: the caller ends the run
        (a tick) or exits (still attaching) instead of retrying again. */
    private mutating func handleTransient(
        _ kind: MonitorTransient, detail: String, at now: Date, label: String
    ) -> TransientStep {
        if kind.countsTowardGiveUp {
            let since = unreachableSince ?? now
            unreachableSince = since
            if now.timeIntervalSince(since) >= MonitorRunTuning.unreachableGiveUpSeconds {
                return .giveUp
            }
        } else {
            unreachableSince = nil
        }
        var events: [MonitorEvent] = []
        if transientKind != kind {
            events = [.transient(at: now, label: label, text: Self.transientText(kind, detail: detail))]
            transientKind = kind
        }
        let delay = currentBackoff
        currentBackoff = min(currentBackoff * 2, MonitorRunTuning.backoffCeilingSeconds)
        return .retry(events, delay: delay)
    }

    private static func transientText(_ kind: MonitorTransient, detail: String) -> String {
        switch kind {
        case .configInvalid: return "config is invalid, waiting (directa config check)"
        case .restoring: return "the daemon is restoring supervised servers, waiting"
        case .unreachable: return "the daemon is unreachable, retrying"
        case .unreadable: return "the daemon's answer could not be read (\(reason(detail))), retrying"
        }
    }

    /** A daemon message or a decoding error's description, made safe to
        print in the `directa <label>:` namespace. */
    private static func reason(_ text: String) -> String {
        LogSanitizer.truncated(MonitorSanitizer.sanitize(text), toCharacters: MonitorLimits.truncationCharacterLimit)
    }

    /** The ended line for a refusal carries its fix: the message, then the
        hint command when the error has one. */
    private static func reason(_ error: WireError) -> String {
        reason(error.hint.map { "\(error.message); \($0)" } ?? error.message)
    }

    private static func rawLabel(name: String, server: ServerStatus) -> String {
        server.worktree.map { "\(name)@\($0)" } ?? name
    }

    /** `phase, pid=N, last exit …`: the start marker's view of the server
        (docs/cli-contract.md, monitor), reused as the health baseline so a
        later `server.status` poll can tell "changed" from "same" by
        comparing this same string. */
    private static func statusDescription(for server: ServerStatus) -> String {
        var parts = [server.phase.rawValue]
        if let pid = server.pid { parts.append("pid=\(pid)") }
        if let exit = server.lastExit { parts.append(exit.summary) }
        return parts.joined(separator: ", ")
    }
}

/** How a `directa monitor` process ended, decided inside the loop's own
    `Task` and read once by `run()` after awaiting it: `.failure` is the only
    case that still exits through `CLIRunner.fail`, and only because nothing
    has printed yet (it can only come from `MonitorSession.attachStep`).
    `.endedWithError` has already printed its ended line and exits with the
    status `CLIRunner` maps the error's code to, without a second report. */
private enum MonitorRunOutcome: Sendable {
    case endedWithError(WireError)
    case failure(WireError)
    case success
}

/** Detects the moment nothing is reading `directa monitor`'s stdout, so the
    loop stops instead of writing into a void forever, and cancels the loop's
    `Task` the instant it does. A pipe or socket fd 1 (Claude Code's Monitor
    tool, and a piped smoke test, both look like this) gets the primary
    signal: `EVFILT_WRITE` with `EV_CLEAR` (without `EV_CLEAR` the filter
    fires continuously while still writable, spinning the loop) reports
    `EV_EOF` the instant the reader closes, with no write required to notice
    it. A regular file or a TTY has no such edge, so that case instead
    watches `CLAUDE_PID` (`EVFILT_PROC`/`NOTE_EXIT`) when the harness set it,
    else the parent's own `NOTE_EXIT`, and polls `getppid()` for a change
    only when the kernel refuses every registration. */
final class MonitorLifetime: Sendable {
    /** The signal that ends the run; a kqueue signal carries its descriptor,
        already registered. */
    enum Watch: Equatable {
        /** Polls until `getppid()` stops returning `from`. */
        case parentChange(from: pid_t)
        /** `NOTE_EXIT` registered on `parent`. A parent that exited between
            reading its pid and registering never delivers the note, so
            `arm` confirms `parent` is still the parent afterward. */
        case parentExit(kqueue: Int32, parent: pid_t)
        case processExit(kqueue: Int32)
        case stdoutEOF(kqueue: Int32)
    }

    private let onGone = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    func attach<Success, Failure: Error>(to task: Task<Success, Failure>) {
        onGone.withLock { $0 = { task.cancel() } }
        arm()
    }

    private func fire() {
        let handler = onGone.withLock { handler in
            defer { handler = nil }
            return handler
        }
        handler?()
    }

    private func arm() {
        var st = stat()
        let stdoutIsStream =
            fstat(1, &st) == 0 && [S_IFIFO, S_IFSOCK].contains(mode_t(st.st_mode) & S_IFMT)
        let claudePID = ProcessInfo.processInfo.environment["CLAUDE_PID"].flatMap { pid_t($0) }
        let watch = Self.choose(
            claudePID: claudePID, parentPID: getppid(), registerProcessExit: Self.registerProcessExit,
            registerStdoutEOF: Self.registerStdoutEOF, stdoutIsStream: stdoutIsStream)
        switch watch {
        case .parentChange(let parent):
            watchParentChange(from: parent)
        case .parentExit(let kq, let parent):
            guard getppid() == parent else {
                close(kq)
                fire()
                return
            }
            runWatcher(kqueue: kq, name: "parent") { _ in true }
        case .processExit(let kq):
            runWatcher(kqueue: kq, name: "claude") { _ in true }
        case .stdoutEOF(let kq):
            runWatcher(kqueue: kq, name: "stdout") { $0.flags & UInt16(EV_EOF) != 0 }
        }
    }

    /** The first signal whose registration succeeds, most direct first. A
        `CLAUDE_PID` naming a process that already exited (the kernel
        refuses the registration with ESRCH), or a kqueue the kernel will
        not create, falls through to the next signal, and the parent-change
        poll is the last resort, never no lifetime watch at all. A parent of
        pid 1 means the process is already orphaned to launchd, which never
        exits, so that case goes straight to the poll. */
    static func choose(
        claudePID: pid_t?, parentPID: pid_t, registerProcessExit: (pid_t) -> Int32?,
        registerStdoutEOF: () -> Int32?, stdoutIsStream: Bool
    ) -> Watch {
        if stdoutIsStream, let kq = registerStdoutEOF() { return .stdoutEOF(kqueue: kq) }
        if let claudePID, let kq = registerProcessExit(claudePID) { return .processExit(kqueue: kq) }
        if parentPID > 1, let kq = registerProcessExit(parentPID) {
            return .parentExit(kqueue: kq, parent: parentPID)
        }
        return .parentChange(from: parentPID)
    }

    /** A kqueue with `pid`'s `NOTE_EXIT` registered, or nil (nothing left
        open) when the kernel refuses either step. */
    static func registerProcessExit(_ pid: pid_t) -> Int32? {
        register(
            kevent(
                ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                fflags: UInt32(NOTE_EXIT), data: 0, udata: nil))
    }

    static func registerStdoutEOF() -> Int32? {
        register(
            kevent(
                ident: UInt(1), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0,
                data: 0, udata: nil))
    }

    private static func register(_ change: kevent) -> Int32? {
        let kq = kqueue()
        guard kq >= 0 else { return nil }
        var change = change
        guard kevent(kq, &change, 1, nil, 0, nil) == 0 else {
            close(kq)
            return nil
        }
        return kq
    }

    /** Blocks a dedicated thread on `kq` until an event `firesOn` accepts,
        then ends the run; a kqueue error other than EINTR ends the watch
        without ending the run. */
    private func runWatcher(kqueue kq: Int32, name: String, firesOn: @escaping @Sendable (kevent) -> Bool) {
        let thread = Thread { [self] in
            defer { close(kq) }
            var event = kevent()
            while true {
                let n = kevent(kq, nil, 0, &event, 1, nil)
                if n < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if n > 0, firesOn(event) {
                    fire()
                    return
                }
            }
        }
        thread.name = "dev.quantizor.directa.monitor-lifetime-\(name)"
        thread.start()
    }

    private func watchParentChange(from parent: pid_t) {
        let thread = Thread { [self] in
            while getppid() == parent {
                usleep(500_000)
            }
            fire()
        }
        thread.name = "dev.quantizor.directa.monitor-lifetime-ppid"
        thread.start()
    }
}
