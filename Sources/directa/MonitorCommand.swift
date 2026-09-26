import ArgumentParser
import Darwin
import DirectaKit
import Foundation

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
            "Total stderr lines for this run (\(MonitorLimits.errorsPerArmRange.lowerBound)-\(MonitorLimits.errorsPerArmRange.upperBound)); re-arm (run the command again) to reset.",
        transform: MonitorFlagOption.errorsPerArm)
    var errorsPerArm = MonitorLimits.errorsPerArmDefault

    @Option(
        help:
            "Stderr lines allowed per minute (\(MonitorLimits.errorsPerMinuteRange.lowerBound)-\(MonitorLimits.errorsPerMinuteRange.upperBound)).",
        transform: MonitorFlagOption.errorsPerMinute)
    var errorsPerMinute = MonitorLimits.errorsPerMinuteDefault

    @OptionGroup var global: GlobalOptions

    @Option(
        help:
            "Total stdout lines for this run (\(MonitorLimits.linesPerArmRange.lowerBound)-\(MonitorLimits.linesPerArmRange.upperBound)); re-arm (run the command again) to reset.",
        transform: MonitorFlagOption.linesPerArm)
    var linesPerArm = MonitorLimits.linesPerArmDefault

    @Option(
        help:
            "Stdout lines allowed per minute (\(MonitorLimits.linesPerMinuteRange.lowerBound)-\(MonitorLimits.linesPerMinuteRange.upperBound)).",
        transform: MonitorFlagOption.linesPerMinute)
    var linesPerMinute = MonitorLimits.linesPerMinuteDefault

    @Argument(help: "Server name.")
    var name: String

    @Option(
        help:
            "Seconds between polls (\(MonitorFlagOption.formatSeconds(MonitorLimits.tickRange.lowerBound))-\(MonitorFlagOption.formatSeconds(MonitorLimits.tickRange.upperBound))).",
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
                    FileHandle.standardError.write(Data("directa monitor: poll at \(Date())\n".utf8))
                }
                switch outcome {
                case .exit(let error):
                    return .failure(error)
                case .ended(let events):
                    Self.emit(events, json: json)
                    return .success
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
                        /** Cancelled mid-sleep: the reader is gone. Per the
                            design, an end marker prints only on self-exit, so
                            nothing more is written here. */
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
            for event in events {
                if let data = try? JSONCoding.encoder().encode(event) {
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

/** Screens every monitor budget flag at the parser boundary, the same
    boundary `TimeoutOption` screens `--timeout` at: a value outside
    `MonitorLimits`' range is refused with a message naming the range,
    rather than reaching `MonitorStream` and silently behaving as an
    unlimited or a zero budget. */
enum MonitorFlagOption {
    static func errorsPerArm(_ raw: String) throws -> Int {
        try parseInt(raw, range: MonitorLimits.errorsPerArmRange, flag: "--errors-per-arm")
    }

    static func errorsPerMinute(_ raw: String) throws -> Int {
        try parseInt(raw, range: MonitorLimits.errorsPerMinuteRange, flag: "--errors-per-minute")
    }

    static func linesPerArm(_ raw: String) throws -> Int {
        try parseInt(raw, range: MonitorLimits.linesPerArmRange, flag: "--lines-per-arm")
    }

    static func linesPerMinute(_ raw: String) throws -> Int {
        try parseInt(raw, range: MonitorLimits.linesPerMinuteRange, flag: "--lines-per-minute")
    }

    static func tick(_ raw: String) throws -> Double {
        guard let value = Double(raw), value.isFinite else {
            throw ValidationError("'\(raw)' is not a number of seconds")
        }
        let range = MonitorLimits.tickRange
        guard range.contains(value) else {
            throw ValidationError(
                "--tick must be between \(formatSeconds(range.lowerBound)) and "
                    + "\(formatSeconds(range.upperBound)) seconds, got \(raw)")
        }
        return value
    }

    /** `MonitorLimits.tickRange`'s bounds are `TimeInterval`; printing a
        whole one (60) as "60" rather than "60.0" keeps the message and the
        help text reading like something a person wrote. */
    static func formatSeconds(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func parseInt(_ raw: String, range: ClosedRange<Int>, flag: String) throws -> Int {
        guard let value = Int(raw) else {
            throw ValidationError("'\(raw)' is not a whole number of lines")
        }
        guard range.contains(value) else {
            throw ValidationError(
                "\(flag) must be between \(range.lowerBound) and \(range.upperBound), got \(raw)")
        }
        return value
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

/** Wall time and sleep behind a protocol so a test drives every backoff,
    poll-interval, and hard-cap decision without a real clock. */
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
    them on its own; `unreachable` also ends the run past
    `MonitorRunTuning.unreachableGiveUpSeconds` of continuous failure. */
private enum MonitorTransient: Equatable {
    case configInvalid
    case restoring
    case unreachable
}

/** Tunables for the loop itself, distinct from `MonitorLimits` (the budget
    flags and their ranges, shared with the parser boundary): nothing here is
    user-configurable, so nothing here needs to agree with a flag. */
enum MonitorRunTuning {
    /** The exponential backoff ceiling while a transient failure persists. */
    static let backoffCeilingSeconds: Double = 10
    /** Below Claude Code's 30-minute Monitor-tool kill, so the end marker is
        delivered before the tool would drop the process itself. */
    static let hardCapSeconds: TimeInterval = 29 * 60
    /** Per tick, sys and mark are fetched with their own small cap,
        independent of `MonitorLimits.perTickFetchCap` (out/err's, much
        larger): lifecycle can never be crowded out by a stdout flood, and
        there is normally very little of it to fetch anyway. */
    static let lifecycleFetchCap = 50
    static let statusPollInterval: TimeInterval = 10
    /** Continuous "the daemon is unreachable" past this long ends the run
        (mid-stream) or gives up on attaching (before any output), rather
        than retrying forever against a daemon that may be gone for good. */
    static let unreachableGiveUpSeconds: TimeInterval = 60
}

/** One `directa monitor` invocation's state machine: attaches (confirms the
    server exists, feature-gates the daemon, prints the start marker), then
    ticks (one `logs.query` past the last cursor, an occasional
    `server.status` for health, transient/backoff handling, and the 29-minute
    hard cap). Free of stdout and process lifetime, so a fake client and
    clock exercise every decision. */
struct MonitorSession: Sendable {
    enum StepOutcome: Sendable {
        /** The run is over on its own initiative (not-found, 60 s
            unreachable, or the 29-minute cap); `events` include the
            `MonitorStream.ended`/`endedAtHardCap` marker. */
        case ended([MonitorEvent])
        case events([MonitorEvent], delaySeconds: Double)
        /** Only ever produced before attaching: the caller may still exit
            through `CLIRunner.fail`, since nothing has printed yet. */
        case exit(WireError)
    }

    private enum State {
        case attaching
        case streaming(cursor: LogCursor, stream: MonitorStream, lastHealthDescription: String, startedAt: Date)
    }

    private let client: any MonitorRequesting
    private let clock: any MonitorClock
    private let config: MonitorRunConfig
    private var currentBackoff: Double
    private var label: String
    private var lastStatusPollAt: Date?
    private var state: State = .attaching
    private var transientKind: MonitorTransient?
    private var unreachableSince: Date?

    init(client: any MonitorRequesting, clock: any MonitorClock, config: MonitorRunConfig) {
        self.client = client
        self.clock = clock
        self.config = config
        currentBackoff = config.tickSeconds
        label = MonitorSanitizer.sanitizeLabel(config.name)
    }

    mutating func step() async -> StepOutcome {
        switch state {
        case .attaching:
            return await attachStep()
        case .streaming:
            return await tickStep()
        }
    }

    /** One query with every stream trimmed to 0 (the cursor without any
        lines) plus one status call, in that order: the query alone both
        feature-gates the daemon (`cursor`/`totals` present) and, via
        `not-found`, confirms the name exists before the status call ever
        needs to compose the marker. */
    private mutating func attachStep() async -> StepOutcome {
        let now = await clock.now()
        do {
            let logsResult = try await client.queryLogs(
                LogsQueryParams(
                    maxLineCharacters: MonitorLimits.truncationCharacterLimit, name: config.name,
                    project: config.project, tailByStream: LogStreamCounts(err: 0, mark: 0, out: 0, sys: 0)))
            guard let cursor = logsResult.cursor, logsResult.totals != nil else {
                return .exit(Logs.olderDaemon)
            }
            let statusResult = try await client.fetchStatus(
                ProjectParams(name: config.name, project: config.project))
            guard let server = statusResult.servers.first(where: { $0.server == config.name }) else {
                return .exit(ProjectConfigLoader.serverNotFound(name: config.name, project: config.project))
            }
            label = MonitorSanitizer.sanitizeLabel(Self.rawLabel(name: config.name, server: server))
            var stream = MonitorStream(
                config: MonitorConfig(
                    budgets: config.budgets, clockStart: now, label: label, serverName: config.name))
            let description = Self.statusDescription(for: server)
            let events = stream.attached(
                MonitorAttachSummary(checkoutPath: config.project, statusDescription: description))
            transientKind = nil
            unreachableSince = nil
            currentBackoff = config.tickSeconds
            lastStatusPollAt = now
            state = .streaming(cursor: cursor, stream: stream, lastHealthDescription: description, startedAt: now)
            return .events(events, delaySeconds: config.tickSeconds)
        } catch let error as WireError {
            if error.code == .notFound {
                return .exit(ProjectConfigLoader.serverNotFound(name: config.name, project: config.project))
            }
            let outcome = handleTransient(error, at: now)
            if outcome.giveUpUnreachable {
                return .exit(
                    WireError(
                        code: .daemonUnreachable, hint: "run: directa daemon status",
                        message: "the daemon has been unreachable for \(Int(MonitorRunTuning.unreachableGiveUpSeconds))s"))
            }
            return .events(outcome.events, delaySeconds: outcome.delaySeconds)
        } catch {
            return .exit(WireError(code: .internalError, message: String(describing: error)))
        }
    }

    private mutating func tickStep() async -> StepOutcome {
        guard case .streaming(let cursor, var stream, let lastHealth, let startedAt) = state else {
            return .events([], delaySeconds: config.tickSeconds)
        }
        let now = await clock.now()
        if now.timeIntervalSince(startedAt) >= MonitorRunTuning.hardCapSeconds {
            return .ended(stream.endedAtHardCap())
        }

        let logsResult: LogsQueryResult
        do {
            logsResult = try await client.queryLogs(
                LogsQueryParams(
                    after: cursor, maxLineCharacters: MonitorLimits.truncationCharacterLimit, name: config.name,
                    project: config.project,
                    tailByStream: LogStreamCounts(
                        err: MonitorLimits.perTickFetchCap, mark: MonitorRunTuning.lifecycleFetchCap,
                        out: MonitorLimits.perTickFetchCap, sys: MonitorRunTuning.lifecycleFetchCap)))
        } catch let error as WireError {
            state = .streaming(cursor: cursor, stream: stream, lastHealthDescription: lastHealth, startedAt: startedAt)
            if error.code == .notFound {
                return .ended(stream.ended(reason: "server unregistered"))
            }
            let outcome = handleTransient(error, at: now)
            if outcome.giveUpUnreachable {
                return .ended(
                    stream.ended(reason: "daemon unreachable for \(Int(MonitorRunTuning.unreachableGiveUpSeconds))s"))
            }
            return .events(outcome.events, delaySeconds: outcome.delaySeconds)
        } catch {
            state = .streaming(cursor: cursor, stream: stream, lastHealthDescription: lastHealth, startedAt: startedAt)
            return .events([], delaySeconds: config.tickSeconds)
        }

        transientKind = nil
        unreachableSince = nil
        currentBackoff = config.tickSeconds

        guard let nextCursor = logsResult.cursor, let totals = logsResult.totals else {
            /** Should not happen once the feature gate at attach has passed
                (a running daemon does not lose the field mid-session); kept
                as a no-op tick rather than a crash, holding the old cursor
                so nothing is skipped once the daemon answers normally again. */
            state = .streaming(cursor: cursor, stream: stream, lastHealthDescription: lastHealth, startedAt: startedAt)
            return .events([], delaySeconds: config.tickSeconds)
        }

        var trimmed: [LogStream: Int] = [:]
        for streamKind in [LogStream.out, .err] {
            let returned = logsResult.lines.count { $0.stream == streamKind }
            let total = totals[streamKind] ?? 0
            if total > returned { trimmed[streamKind] = total - returned }
        }

        var health: String?
        var updatedLastHealth = lastHealth
        var polledAt = lastStatusPollAt ?? startedAt
        var endedFromStatus: [MonitorEvent]?
        if now.timeIntervalSince(polledAt) >= MonitorRunTuning.statusPollInterval {
            do {
                let statusResult = try await client.fetchStatus(
                    ProjectParams(name: config.name, project: config.project))
                if let server = statusResult.servers.first(where: { $0.server == config.name }) {
                    let description = Self.statusDescription(for: server)
                    if description != updatedLastHealth {
                        health = description
                        updatedLastHealth = description
                    }
                    polledAt = now
                } else {
                    endedFromStatus = stream.ended(reason: "server unregistered")
                }
            } catch let error as WireError {
                if error.code == .notFound {
                    endedFromStatus = stream.ended(reason: "server unregistered")
                }
                /** Any other failure here retries on the next tick (the poll
                    interval has not been advanced); the logs.query call
                    above already reported a transient this tick when there
                    was a new one to report, and a second marker for the
                    same underlying failure would be noise. */
            } catch {
                // Ignored; the next scheduled poll retries.
            }
        }

        let tickEvents = stream.ingest(
            MonitorTick(at: now, health: health, records: logsResult.lines, trimmed: trimmed))
        lastStatusPollAt = polledAt
        state = .streaming(
            cursor: nextCursor, stream: stream, lastHealthDescription: updatedLastHealth, startedAt: startedAt)

        if let endedFromStatus {
            return .ended(tickEvents + endedFromStatus)
        }
        return .events(tickEvents, delaySeconds: config.tickSeconds)
    }

    /** Shared by attach and every tick: classifies a daemon failure into the
        transient state an agent should see, tracks how long "unreachable"
        has been continuous, and computes the next backoff delay.
        `giveUpUnreachable` means unreachable for
        `MonitorRunTuning.unreachableGiveUpSeconds`: the caller ends the run
        (a tick) or exits (still attaching) instead of retrying again. */
    private mutating func handleTransient(
        _ error: WireError, at now: Date
    ) -> (events: [MonitorEvent], delaySeconds: Double, giveUpUnreachable: Bool) {
        let kind = Self.classify(error.code)
        if kind == .unreachable {
            let since = unreachableSince ?? now
            unreachableSince = since
            if now.timeIntervalSince(since) >= MonitorRunTuning.unreachableGiveUpSeconds {
                return ([], 0, true)
            }
        } else {
            unreachableSince = nil
        }
        var events: [MonitorEvent] = []
        if transientKind != kind {
            events = [MonitorEvent(at: now, kind: .transient, label: label, text: Self.transientText(kind))]
            transientKind = kind
        }
        let delay = currentBackoff
        currentBackoff = min(currentBackoff * 2, MonitorRunTuning.backoffCeilingSeconds)
        return (events, delay, false)
    }

    private static func classify(_ code: WireErrorCode) -> MonitorTransient {
        switch code {
        case .configInvalid: return .configInvalid
        case .daemonStarting: return .restoring
        default: return .unreachable
        }
    }

    private static func transientText(_ kind: MonitorTransient) -> String {
        switch kind {
        case .configInvalid: return "config is invalid, waiting (directa config check)"
        case .restoring: return "the daemon is restoring supervised servers, waiting"
        case .unreachable: return "the daemon is unreachable, retrying"
        }
    }

    private static func rawLabel(name: String, server: ServerStatus) -> String {
        server.worktree.map { "\(name)@\($0)" } ?? name
    }

    /** `phase, pid=N, last exit …`: the fields the plan names for the start
        marker, reused as the health baseline so a later `server.status` poll
        can tell "changed" from "same" by comparing this same string. */
    private static func statusDescription(for server: ServerStatus) -> String {
        var parts = [server.phase.rawValue]
        if let pid = server.pid { parts.append("pid=\(pid)") }
        if let exit = server.lastExit {
            let cause = exit.code.map { "exit \($0)" } ?? exit.signal.map { "signal \($0)" } ?? "unknown"
            parts.append("last exit \(cause) at \(JSONCoding.formatISO8601(exit.at))")
        }
        return parts.joined(separator: ", ")
    }
}

/** How a `directa monitor` process ended, decided inside the loop's own
    `Task` and read once by `run()` after awaiting it: `.failure` is the only
    case that still exits through `CLIRunner.fail`, and only because nothing
    has printed yet (it can only come from `MonitorSession.attachStep`). */
private enum MonitorRunOutcome: Sendable {
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
    or falls back to polling `getppid()` for a change. */
final class MonitorLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var onGone: (() -> Void)?

    func attach<Success, Failure: Error>(to task: Task<Success, Failure>) {
        lock.lock()
        onGone = { task.cancel() }
        lock.unlock()
        arm()
    }

    private func fire() {
        lock.lock()
        let handler = onGone
        onGone = nil
        lock.unlock()
        handler?()
    }

    private func arm() {
        var st = stat()
        guard fstat(1, &st) == 0 else { return }
        switch mode_t(st.st_mode) & S_IFMT {
        case S_IFIFO, S_IFSOCK:
            watchStdoutEOF()
        default:
            if let raw = ProcessInfo.processInfo.environment["CLAUDE_PID"], let pid = pid_t(raw) {
                watchClaudeExit(pid)
            } else {
                watchParentChange()
            }
        }
    }

    private func watchStdoutEOF() {
        let thread = Thread { [self] in
            let kq = kqueue()
            guard kq >= 0 else { return }
            defer { close(kq) }
            var change = kevent(
                ident: UInt(1), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0,
                data: 0, udata: nil)
            guard kevent(kq, &change, 1, nil, 0, nil) == 0 else { return }
            var events: [kevent] = Array(repeating: kevent(), count: 1)
            while true {
                let n = kevent(kq, nil, 0, &events, 1, nil)
                if n < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if n > 0, events[0].flags & UInt16(EV_EOF) != 0 {
                    fire()
                    return
                }
            }
        }
        thread.name = "dev.quantizor.directa.monitor-lifetime"
        thread.start()
    }

    private func watchClaudeExit(_ pid: pid_t) {
        let thread = Thread { [self] in
            let kq = kqueue()
            guard kq >= 0 else { return }
            defer { close(kq) }
            var change = kevent(
                ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
            guard kevent(kq, &change, 1, nil, 0, nil) == 0 else { return }
            var events: [kevent] = Array(repeating: kevent(), count: 1)
            if kevent(kq, nil, 0, &events, 1, nil) > 0 { fire() }
        }
        thread.name = "dev.quantizor.directa.monitor-lifetime-claude"
        thread.start()
    }

    private func watchParentChange() {
        let startPpid = getppid()
        let thread = Thread {
            while getppid() == startPpid {
                usleep(500_000)
            }
            self.fire()
        }
        thread.name = "dev.quantizor.directa.monitor-lifetime-ppid"
        thread.start()
    }
}
