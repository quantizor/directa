import Foundation

/** Pure event-shaping for `directa monitor`: turns daemon-returned log records
    and health signals into the exact lines a human or an agent sees. No
    networking, no process lifetime, no wire types. Every timestamp comes from
    the caller (a tick's `at`, or the stream's own last-known time), never
    `Date()`, so a test's injected clock fully determines the output. */

/** Every tunable and its hard ceiling, gathered in one place so the CLI flag
    parser and this shaping core validate against the same numbers. */
public enum MonitorLimits {
    /** A terminal-width stack frame or SQL error is still readable at 400
        characters; past that the line is noise the agent has to scroll
        through, and `directa logs --head` is the bounded way to read more. */
    public static let truncationCharacterLimit = 400

    /** A request/response pair or a tight retry loop settles within a few
        seconds; 10 s absorbs that kind of storm as one suppressed run without
        swallowing a genuinely new error that happens to arrive moments later. */
    public static let burstWindow: TimeInterval = 10

    /** Bounds client memory for the life of the monitor regardless of how
        long it runs: enough distinct lines to track a busy window's repeat
        patterns without growing without limit. */
    public static let lruCapacity = 512

    /** Frequent enough that a suppressed line surfaces well within an agent's
        working memory of what it just did; rare enough not to compete with
        real output during a noisy stretch. */
    public static let summaryCadence: TimeInterval = 30

    /** Shorter than the summary cadence so a burst's tally appears promptly
        once the server actually goes quiet, instead of waiting out the rest
        of the 30 s window. */
    public static let quietTrigger: TimeInterval = 5

    /** The per-stream line count the client asks for on out and err in each
        tick's query (`tailByStream`): past this many lines in one tick, the
        daemon keeps the newest and drops the rest before the client sees
        them, so a tick can under-report volume even while the client's own
        budget has room left. */
    public static let perTickFetchCap = 300

    /** The same per-query count for sys and mark, independent of out/err's
        and much smaller: lifecycle can never be crowded out by a stdout
        flood, and there is normally very little of it to fetch. */
    public static let lifecycleFetchCap = 50

    public static func fetchCap(for stream: LogStream) -> Int {
        switch stream {
        case .err, .out: perTickFetchCap
        case .mark, .sys: lifecycleFetchCap
        }
    }

    /** Claude Code's Monitor tool kills its command after this long; the
        session context's Monitor call asks for exactly this `timeout_ms`. */
    public static let harnessKillSeconds: TimeInterval = 30 * 60

    /** A minute under the harness kill, so the run's own end marker, with
        its re-arm command, is delivered before the tool drops the process. */
    public static let hardCapSeconds: TimeInterval = harnessKillSeconds - 60

    /** stdout: 120/min covers a chatty dev server's request logging without
        the monitor itself becoming the flood; 1200 is a hard ceiling past
        which the budget stops doing useful shaping. 1 is the floor: 0 would
        silently mean "never show anything", which the CLI parser refuses
        outright instead of accepting as a budget. */
    public static let linesPerMinuteDefault = 120
    public static let linesPerMinuteRange = 1...1_200

    /** The total stdout lines a monitor invocation ever shows: high enough to
        outlast a normal working session, low enough that a runaway server
        cannot grow the agent's context without bound. Re-arming (running the
        command again) is the only reset, by design. */
    public static let linesPerArmDefault = 600
    public static let linesPerArmRange = 1...20_000

    /** stderr gets a smaller default than stdout: errors are rarer than
        request logs in a healthy server, so a tighter per-minute rate still
        leaves headroom before the burst allowance kicks in. */
    public static let errorsPerMinuteDefault = 30
    public static let errorsPerMinuteRange = 1...600

    /** Independent of stdout's per-arm cap so a server that goes quiet on
        stdout but keeps erroring is never silently cut off. */
    public static let errorsPerArmDefault = 300
    public static let errorsPerArmRange = 1...5_000

    /** The CLI's poll interval; MonitorStream itself is tick-driven and never
        reads this, but the same range lives here so the flag parser and this
        file cannot drift apart. */
    public static let tickDefault: TimeInterval = 2
    public static let tickRange: ClosedRange<TimeInterval> = 0.5...60

    /** A quarter of the per-minute rate absorbs a short spike (a request and
        the error it throws) without validating one flag against a wholly
        separate one; the 10-line floor keeps a low --lines-per-minute from
        starving that same two-line burst. */
    public static func burstCapacity(perMinute: Int) -> Int {
        max(10, perMinute / 4)
    }
}

/** Token-bucket budgets for stdout and stderr, each with an independent
    per-minute rate (refills) and per-arm ceiling (does not). */
public struct MonitorBudgets: Equatable, Sendable {
    public var errorsPerArm: Int
    public var errorsPerMinute: Int
    public var linesPerArm: Int
    public var linesPerMinute: Int

    public init(
        errorsPerArm: Int = MonitorLimits.errorsPerArmDefault,
        errorsPerMinute: Int = MonitorLimits.errorsPerMinuteDefault,
        linesPerArm: Int = MonitorLimits.linesPerArmDefault,
        linesPerMinute: Int = MonitorLimits.linesPerMinuteDefault
    ) {
        self.errorsPerArm = errorsPerArm
        self.errorsPerMinute = errorsPerMinute
        self.linesPerArm = linesPerArm
        self.linesPerMinute = linesPerMinute
    }

    public static let defaults = MonitorBudgets()
}

/** Everything a MonitorStream needs at construction. `label` is sanitized
    once, at construction, and every rendered event reuses that copy.
    `serverName` only ever appears inside a `directa logs <name> ...` command
    the reader may run, so it is pasted as written when shell-inert and
    replaced by `<name>` otherwise (`ShellWord.inertOr`): sanitizing it
    instead would name a different server. */
public struct MonitorConfig: Sendable {
    public var budgets: MonitorBudgets
    public var clockStart: Date
    public var label: String
    public var serverName: String

    public init(
        budgets: MonitorBudgets = .defaults, clockStart: Date, label: String, serverName: String
    ) {
        self.budgets = budgets
        self.clockStart = clockStart
        self.label = label
        self.serverName = serverName
    }
}

/** The fields `attached` needs to render the start marker. Deliberately plain
    types rather than `ServerStatus`/`ServerPhase`: this file has no dependency
    on the daemon's status model, only on strings the caller already knows how
    to compose. */
public struct MonitorAttachSummary: Sendable {
    public var checkoutPath: String
    public var statusDescription: String

    public init(checkoutPath: String, statusDescription: String) {
        self.checkoutPath = checkoutPath
        self.statusDescription = statusDescription
    }
}

/** One poll's worth of daemon state. `trimmed` is what the daemon matched but
    did not return for a stream (the CLI layer computes it from the query's
    `totals` minus what actually came back); `health` is non-nil only on a
    state change, so MonitorStream never needs to deduplicate it itself.
    `windowStart` is the time of the cursor the query read past: the daemon
    trims the oldest lines of a window, so that is where the lines it did not
    return begin. */
public struct MonitorTick: Sendable {
    public var at: Date
    public var health: String?
    public var records: [LogRecord]
    public var trimmed: [LogStream: Int]
    public var windowStart: Date

    public init(
        at: Date, health: String? = nil, records: [LogRecord] = [], trimmed: [LogStream: Int] = [:],
        windowStart: Date
    ) {
        self.at = at
        self.health = health
        self.records = records
        self.trimmed = trimmed
        self.windowStart = windowStart
    }
}

/** What kind of thing a MonitorEvent reports. `line` and `repeated` carry a
    `stream` (out/err/sys/mark) that picks the rendered namespace; every other
    kind always renders under the `directa <label>:` namespace regardless of
    `stream`. */
public enum MonitorEventKind: String, Codable, Sendable {
    case attached
    case budget
    case ended
    case health
    case lifecycle
    case line
    case repeated
    case suppressed
    case transient
}

/** One shaped line. `text` already carries every suffix the kind needs
    ("(again, 2nd in 3m)", the logs hint, and so on); `count` is the one piece
    of that text a machine reader (`--json`) needs as a number rather than a
    substring: the repeat count for `repeated`, the crossed cap for a
    `budget` overflow marker, the suppressed total for its resume marker or
    for `suppressed`. Encode only through `JSONCoding`; a raw `JSONEncoder`
    loses the millisecond ISO-8601 date format this type's golden depends on.
    Built only through the per-kind factories below, so a kind that carries a
    count always has one. */
public struct MonitorEvent: Codable, Equatable, Sendable {
    public var at: Date
    public var count: Int?
    public var kind: MonitorEventKind
    public var label: String
    public var stream: LogStream?
    public var text: String

    private init(
        at: Date, count: Int? = nil, kind: MonitorEventKind, label: String, stream: LogStream? = nil,
        text: String
    ) {
        self.at = at
        self.count = count
        self.kind = kind
        self.label = label
        self.stream = stream
        self.text = text
    }

    public static func attached(at: Date, label: String, text: String) -> MonitorEvent {
        MonitorEvent(at: at, kind: .attached, label: label, text: text)
    }

    /** `count` is the crossed cap for an over-budget marker, or the
        suppressed total for a resume marker. */
    public static func budget(at: Date, count: Int, label: String, stream: LogStream, text: String) -> MonitorEvent {
        MonitorEvent(at: at, count: count, kind: .budget, label: label, stream: stream, text: text)
    }

    public static func ended(at: Date, label: String, text: String) -> MonitorEvent {
        MonitorEvent(at: at, kind: .ended, label: label, text: text)
    }

    public static func health(at: Date, label: String, text: String) -> MonitorEvent {
        MonitorEvent(at: at, kind: .health, label: label, text: text)
    }

    public static func lifecycle(at: Date, label: String, stream: LogStream, text: String) -> MonitorEvent {
        MonitorEvent(at: at, kind: .lifecycle, label: label, stream: stream, text: text)
    }

    public static func line(at: Date, label: String, stream: LogStream, text: String) -> MonitorEvent {
        MonitorEvent(at: at, kind: .line, label: label, stream: stream, text: text)
    }

    /** `count` is how many more times `text` arrived after the one shown. */
    public static func repeated(at: Date, count: Int, label: String, stream: LogStream, text: String) -> MonitorEvent {
        MonitorEvent(at: at, count: count, kind: .repeated, label: label, stream: stream, text: text)
    }

    /** `count` is how many lines went unshown: skipped by the daemon on
        `stream`, or collapsed as repeats across every stream when `stream`
        is nil. */
    public static func suppressed(
        at: Date, count: Int, label: String, stream: LogStream? = nil, text: String
    ) -> MonitorEvent {
        MonitorEvent(at: at, count: count, kind: .suppressed, label: label, stream: stream, text: text)
    }

    public static func transient(at: Date, label: String, text: String) -> MonitorEvent {
        MonitorEvent(at: at, kind: .transient, label: label, text: text)
    }

    /** The exact line a terminal or an agent's Monitor tool sees. */
    public var humanLine: String {
        let suffix = kind == .repeated ? " (repeated x\(count ?? 0))" : ""
        return namespacePrefix + text + suffix
    }

    /** Structural, never parsed from `text`: a child line can contain
        anything, including something that reads like a directa line, and it
        still renders under the out|/err| namespace because the prefix comes
        from this event's own `stream`, not from its content. Only an actual
        child line (`line`, or a `repeated` collapse of one) ever takes that
        namespace; a budget or health marker keeps the `directa <label>:`
        namespace even when it names an out/err stream in `stream`. */
    private var namespacePrefix: String {
        guard kind == .line || kind == .repeated else {
            return "directa \(label): "
        }
        switch stream {
        case .out: return "\(label) out| "
        case .err: return "\(label) err| "
        case .mark, .sys, nil: return "directa \(label): "
        }
    }
}

/** Sanitizes text and labels before either reaches a terminal or an agent's
    context: child output is attacker-influenceable. Public: the CLI's monitor
    loop builds a `.transient` event itself (there is no `MonitorStream`
    method for a connection-level failure), before attaching as well as
    after, and needs the same guarantees on the label and reason it renders
    under `directa <label>:`. */
public enum MonitorSanitizer {
    /** ANSI/OSC escapes (a terminal-injection surface, stripped by the same
        routine `LogSanitizer` already uses for spool output), the Unicode
        control/format/line-and-paragraph-separator categories (Cc, Cf, Zl,
        Zp: this is what actually removes U+2028, U+2029, U+0085, and bidi
        overrides, none of which a `.whitespacesAndNewlines` check would
        catch), and a tab folded to a space before the category sweep so it
        does not also get removed as Cc. */
    public static func sanitize(_ raw: String) -> String {
        let stripped = LogSanitizer.stripEscapes(raw)
        let tabsFolded = stripped.replacing("\t", with: " ")
        let scalars = tabsFolded.unicodeScalars.filter { !isRemovedCategory($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func isRemovedCategory(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    /** The label additionally folds `|`, `:`, and whitespace to `_`: those
        are exactly the characters the out|/err|/directa: namespaces are built
        from, so a label cannot manufacture a fake namespace boundary. */
    public static func sanitizeLabel(_ raw: String) -> String {
        String(
            sanitize(raw).map { character in
                character == "|" || character == ":" || character.isWhitespace ? "_" : character
            })
    }
}

/** Normalizes volatile detail out of a line before it becomes a repeat-
    suppression lookup key, so two lines that differ only in a request id or a
    timestamp are recognized as the same recurring line. Order matters: UUIDs
    first (most specific), then timestamps, then hex runs, which need both a
    digit and an a-f letter: a plain digit run is left for the number pass
    (the rule that keeps "200" and "500" distinct), and a word spelled only
    with a-f letters ("decade", "facade") stays a word. */
enum LineNormalizer {
    /** `Regex` is a value type with no shared mutable state; these are
        `nonisolated(unsafe)` purely to avoid recompiling the pattern on every
        call, the pattern Apple documents for a static regex literal. */
    private nonisolated(unsafe) static let uuidPattern =
        /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/
    private nonisolated(unsafe) static let timestampPattern =
        /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z?/
    private nonisolated(unsafe) static let hexRunPattern =
        /\b(?=[0-9a-fA-F]*[a-fA-F])(?=[0-9a-fA-F]*[0-9])[0-9a-fA-F]{6,}\b/
    private nonisolated(unsafe) static let longNumberPattern = /\d{5,}/

    /** Each pass runs only when the line holds a character its pattern
        needs: a dash for UUIDs and timestamps, a digit for timestamps, hex
        runs, and numbers. A UUID may be all letters, so a dash alone still
        reaches that pass. */
    static func normalize(_ text: String) -> String {
        let hasDigit = text.utf8.contains { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
        let hasDash = text.utf8.contains(UInt8(ascii: "-"))
        guard hasDigit || hasDash else { return text }
        var result = text
        if hasDash {
            result.replace(uuidPattern, with: "<uuid>")
            if hasDigit { result.replace(timestampPattern, with: "<timestamp>") }
        }
        if hasDigit {
            result.replace(hexRunPattern, with: "<hex>")
            result.replace(longNumberPattern, with: "<num>")
        }
        return result
    }
}

/** The shaping core. A value type with mutating methods: one instance per
    `directa monitor` invocation, fed one MonitorTick at a time by the CLI's
    poll loop. */
public struct MonitorStream: Sendable {
    /** Repeat-suppression bookkeeping for one distinct out/err line. */
    private struct RepeatEntry {
        var firstShownAt: Date
        var lastDisplayText: String
        var lastSeenAt: Date
        var pendingSuppressed: Int
        var totalShownCount: Int
    }

    /** The two streams a child writes, the only ones with repeat suppression
        and budgets; sys and mark never reach either. */
    private enum ChildStream {
        case err
        case out

        /** Nil for sys and mark. */
        init?(_ stream: LogStream) {
            switch stream {
            case .err: self = .err
            case .out: self = .out
            case .mark, .sys: return nil
            }
        }

        var logStream: LogStream {
            switch self {
            case .err: .err
            case .out: .out
            }
        }
    }

    private struct RepeatKey: Hashable {
        var normalized: String
        var stream: ChildStream
    }

    /** A fixed-capacity cache ordered by last sighting, bounding client
        memory for the life of the run. At `MonitorLimits.lruCapacity`
        entries a linear position update on write costs less than a
        doubly-linked structure would. */
    private struct RepeatLRU {
        private let capacity: Int
        private var order: [RepeatKey] = []
        private var storage: [RepeatKey: RepeatEntry] = [:]

        init(capacity: Int) {
            self.capacity = capacity
        }

        var allEntries: [(key: RepeatKey, entry: RepeatEntry)] {
            order.compactMap { key in storage[key].map { (key, $0) } }
        }

        /** Zeroes every entry's suppressed count in place, leaving recency
            order alone: a summary has just reported them. */
        mutating func clearPendingSuppressed() {
            for key in storage.keys where (storage[key]?.pendingSuppressed ?? 0) > 0 {
                storage[key]?.pendingSuppressed = 0
            }
        }

        subscript(key: RepeatKey) -> RepeatEntry? {
            get { storage[key] }
            set {
                guard let newValue else {
                    storage.removeValue(forKey: key)
                    order.removeAll { $0 == key }
                    return
                }
                if storage[key] == nil {
                    order.append(key)
                    if order.count > capacity {
                        storage.removeValue(forKey: order.removeFirst())
                    }
                } else {
                    order.removeAll { $0 == key }
                    order.append(key)
                }
                storage[key] = newValue
            }
        }
    }

    /** Consecutive-collapse bookkeeping for lifecycle (sys) and mark lines,
        which bypass the LRU and budgets entirely: identical adjacent lines
        collapse, nothing else. */
    private struct PendingRun {
        var at: Date
        var count: Int
        var text: String
    }

    /** One stream's token bucket (rate, refills) plus its independent, non-
        refilling arm ceiling and the accounting a resume marker needs. */
    private struct TokenBudget {
        let armCap: Int
        var armCount = 0
        var armMarkerShown = false
        var daemonTrimmedSinceMarker = 0
        var lastRefillAt: Date
        var minuteOverBudget = false
        let perMinute: Int
        var tokens: Double
        var withheldSinceMarker = 0

        init(armCap: Int, perMinute: Int, at: Date) {
            self.armCap = armCap
            lastRefillAt = at
            self.perMinute = perMinute
            tokens = Double(MonitorLimits.burstCapacity(perMinute: perMinute))
        }

        var burstCapacity: Int { MonitorLimits.burstCapacity(perMinute: perMinute) }

        /** Moves forward only: a flushed `(repeated xN)` carries the time
            its run was last seen, which can be earlier than a line already
            charged this tick, and stepping `lastRefillAt` back to it would
            credit the same interval twice. */
        mutating func refill(at date: Date) {
            guard date > lastRefillAt else { return }
            let elapsed = date.timeIntervalSince(lastRefillAt)
            tokens = min(Double(burstCapacity), tokens + elapsed * Double(perMinute) / 60)
            lastRefillAt = date
        }
    }

    private struct StreamBudgets {
        var err: TokenBudget
        var out: TokenBudget

        subscript(stream: ChildStream) -> TokenBudget {
            get {
                switch stream {
                case .err: err
                case .out: out
                }
            }
            set {
                switch stream {
                case .err: err = newValue
                case .out: out = newValue
                }
            }
        }
    }

    private enum BudgetScope {
        case arm
        case minute
    }

    private var blockContinuation: [ChildStream: Bool] = [:]
    private var budgets: StreamBudgets
    private let config: MonitorConfig
    private let hintName: String
    /** The sanitized label every event of this run renders under. */
    public let label: String
    private var lastKnownAt: Date
    private var lastOutErrActivityAt: Date?
    private var lastRecordAt: [ChildStream: Date] = [:]
    private var lastSummaryAt: Date
    private var lifecyclePending: [LogStream: PendingRun] = [:]
    private var repeatLRU: RepeatLRU
    private var summaryDistinct: Set<RepeatKey> = []
    /** The oldest suppressed repeat still counted in `summaryTotal`: where
        the summary's read-what-was-skipped command has to start. */
    private var summaryEarliestAt: Date?
    private var summaryTotal = 0

    public init(config: MonitorConfig) {
        budgets = StreamBudgets(
            err: TokenBudget(
                armCap: config.budgets.errorsPerArm, perMinute: config.budgets.errorsPerMinute, at: config.clockStart),
            out: TokenBudget(
                armCap: config.budgets.linesPerArm, perMinute: config.budgets.linesPerMinute, at: config.clockStart))
        self.config = config
        hintName = ShellWord.inertOr(config.serverName)
        label = MonitorSanitizer.sanitizeLabel(config.label)
        lastKnownAt = config.clockStart
        lastSummaryAt = config.clockStart
        repeatLRU = RepeatLRU(capacity: MonitorLimits.lruCapacity)
    }

    // MARK: - Public surface

    public func attached(_ summary: MonitorAttachSummary) -> [MonitorEvent] {
        let budgets = config.budgets
        let text =
            "monitoring \(summary.checkoutPath) (\(summary.statusDescription); "
            + "budget \(budgets.linesPerMinute)/min and \(budgets.linesPerArm)/arm, "
            + "errors \(budgets.errorsPerMinute)/min and \(budgets.errorsPerArm)/arm); "
            + "earlier output: directa logs \(hintName) --tail 200"
        return [.attached(at: lastKnownAt, label: label, text: text)]
    }

    public mutating func ingest(_ tick: MonitorTick) -> [MonitorEvent] {
        lastKnownAt = tick.at
        var events: [MonitorEvent] = []
        /** Stamped at the window's start so it sorts ahead of this tick's
            returned lines: the daemon kept the newest lines, so the skipped
            ones came first. */
        events += applyDaemonTrimmed(tick.trimmed, at: tick.windowStart)
        for record in tick.records {
            events += process(record)
        }
        /** Records this tick already refreshed their own entries' `lastSeenAt`
            (to a time at or before `tick.at`), so this only reaches entries
            nothing in this tick touched: a record that just turned its own
            entry into a fresh recurrence must not also get swept here before
            it had a chance to report its own suppressed count. */
        events += flushPendingBurstRuns(at: tick.at, onlyStale: true)
        if let health = tick.health {
            let text = LogSanitizer.truncated(
                MonitorSanitizer.sanitize(health), toCharacters: MonitorLimits.truncationCharacterLimit)
            events.append(.health(at: tick.at, label: label, text: text))
        }
        events += evaluatePeriodicSummary(now: tick.at)
        /** A stale-run flush can carry an `at` from well before this tick (the
            last moment the run was actually seen), earlier than a fresh line
            this same tick already appended; a stable sort restores reading
            order without reordering same-instant events relative to each
            other (Swift's sort has been stable since Swift 5). */
        return events.sorted { $0.at < $1.at }
    }

    public mutating func ended(reason: String) -> [MonitorEvent] {
        var events = flushForEnd()
        events.append(.ended(at: lastKnownAt, label: label, text: "ended (\(reason))"))
        return events
    }

    /** The `MonitorLimits.hardCapSeconds` ending: worded as a next step
        rather than `ended(reason:)`'s parenthetical, since re-arming is the
        whole point of this ending. `resumeFrom` is the final cursor's time:
        a re-armed monitor starts at the end of the log, so the command reads
        whatever lands between this line and that attach. */
    public mutating func endedAtHardCap(resumeFrom: Date) -> [MonitorEvent] {
        var events = flushForEnd()
        let since = JSONCoding.formatISO8601(resumeFrom)
        let minutes = Int(MonitorLimits.hardCapSeconds / 60)
        events.append(
            .ended(
                at: lastKnownAt, label: label,
                text: "ended after \(minutes) minutes; run the same command again to keep watching; "
                    + "anything after this: directa logs \(hintName) --since \(since) --head 200"))
        return events
    }

    /** Shared by both endings: flushes every burst repeat still pending, the
        lifecycle/mark run still pending, and the periodic summary, in that
        order, so nothing counted along the way is silently dropped when the
        run stops. */
    private mutating func flushForEnd() -> [MonitorEvent] {
        var events: [MonitorEvent] = []
        events += flushPendingBurstRuns(at: lastKnownAt, onlyStale: false)
        for stream in [LogStream.sys, .mark] {
            if let pending = lifecyclePending[stream], pending.count > 1 {
                events.append(
                    .repeated(at: pending.at, count: pending.count - 1, label: label, stream: stream, text: pending.text))
            }
            lifecyclePending[stream] = nil
        }
        if summaryTotal > 0 {
            events.append(takeSummary(at: lastKnownAt))
        }
        return events.sorted { $0.at < $1.at }
    }

    // MARK: - Record classification

    private mutating func process(_ record: LogRecord) -> [MonitorEvent] {
        switch record.stream {
        case .sys:
            return processSys(record)
        case .mark:
            return collapseLifecycle(
                stream: .mark, text: "mark \(MonitorSanitizer.sanitize(record.text))", at: record.at)
        case .out:
            return processChildLine(record, stream: .out)
        case .err:
            return processChildLine(record, stream: .err)
        }
    }

    /** `SysLineText.rotated` is the one sys line that never reaches the
        transcript at all; every other producer (started/exited/stopping/
        spawn failed/adopted/watch suspended/spool catch-up/stuck stop, or
        anything a future producer adds) renders identically, so there is
        nothing else to branch on here. Record text needs no truncation here
        or on any other stream: the query asks the daemon to cut each line to
        `MonitorLimits.truncationCharacterLimit`, and sanitizing only removes
        characters. */
    private mutating func processSys(_ record: LogRecord) -> [MonitorEvent] {
        guard record.text != SysLineText.rotated else { return [] }
        return collapseLifecycle(stream: .sys, text: MonitorSanitizer.sanitize(record.text), at: record.at)
    }

    /** Lifecycle/mark bypass the LRU and the budgets entirely; the only
        deduplication they get is collapsing an identical line immediately
        following the pending one into a trailing `(repeated xN)`. */
    private mutating func collapseLifecycle(stream: LogStream, text: String, at: Date) -> [MonitorEvent]
    {
        if let pending = lifecyclePending[stream], pending.text == text {
            lifecyclePending[stream] = PendingRun(at: at, count: pending.count + 1, text: text)
            return []
        }
        var events: [MonitorEvent] = []
        if let pending = lifecyclePending[stream], pending.count > 1 {
            events.append(
                .repeated(at: pending.at, count: pending.count - 1, label: label, stream: stream, text: pending.text))
        }
        events.append(.lifecycle(at: at, label: label, stream: stream, text: text))
        lifecyclePending[stream] = PendingRun(at: at, count: 1, text: text)
        return events
    }

    // MARK: - Out/err repeat suppression and budgets

    private mutating func processChildLine(_ record: LogRecord, stream: ChildStream) -> [MonitorEvent] {
        let displayText = MonitorSanitizer.sanitize(record.text)
        let key = RepeatKey(normalized: LineNormalizer.normalize(displayText), stream: stream)

        /** A reprinted multi-line block (a stack trace) opens on its first
            line's recurrence and, while lines the LRU already holds keep
            arriving inside the same burst window, counts each as a burst
            repeat regardless of that line's own timer: the block's later
            lines never get their own individual "(again...)" annotation.
            Only a line seen before continues a block; the first unseen line
            ends it and is handled as the new line it is, so output that
            follows a reprinted trace is never hidden as part of it. */
        let gapSinceLastRecord =
            lastRecordAt[stream].map { record.at.timeIntervalSince($0) } ?? .infinity
        let existing = repeatLRU[key]
        let continuingBlock =
            (blockContinuation[stream] ?? false) && gapSinceLastRecord <= MonitorLimits.burstWindow
            && existing != nil
        lastRecordAt[stream] = record.at
        lastOutErrActivityAt = record.at

        if continuingBlock {
            recordBurstRepeat(key: key, displayText: displayText, at: record.at)
            return []
        }
        blockContinuation[stream] = false

        guard let entry = existing else {
            repeatLRU[key] = RepeatEntry(
                firstShownAt: record.at, lastDisplayText: displayText, lastSeenAt: record.at,
                pendingSuppressed: 0, totalShownCount: 1)
            return applyBudget(
                .line(at: record.at, label: label, stream: stream.logStream, text: displayText), stream: stream)
        }

        let elapsedSinceSeen = record.at.timeIntervalSince(entry.lastSeenAt)
        if elapsedSinceSeen <= MonitorLimits.burstWindow {
            recordBurstRepeat(key: key, displayText: displayText, at: record.at)
            return []
        }

        /** A recurrence: the same line returning after the agent's fix (or
            after it broke again) is always shown, annotated with how many
            times it has been shown and how long ago the first showing was. */
        let ordinal = entry.totalShownCount + 1
        let window = Self.formatWindow(record.at.timeIntervalSince(entry.firstShownAt))
        let suppressedBefore = entry.pendingSuppressed
        var text = "\(displayText) (again, \(Self.ordinalLabel(ordinal)) in \(window)"
        text += suppressedBefore > 0 ? "; +\(Self.lines(suppressedBefore)) seen before)" : ")"
        releaseFromSummary(suppressedBefore, key: key)

        repeatLRU[key] = RepeatEntry(
            firstShownAt: entry.firstShownAt, lastDisplayText: displayText, lastSeenAt: record.at,
            pendingSuppressed: 0, totalShownCount: ordinal)
        blockContinuation[stream] = true
        return applyBudget(.line(at: record.at, label: label, stream: stream.logStream, text: text), stream: stream)
    }

    private mutating func recordBurstRepeat(key: RepeatKey, displayText: String, at: Date) {
        let existing = repeatLRU[key]
        repeatLRU[key] = RepeatEntry(
            firstShownAt: existing?.firstShownAt ?? at, lastDisplayText: displayText, lastSeenAt: at,
            pendingSuppressed: (existing?.pendingSuppressed ?? 0) + 1,
            totalShownCount: existing?.totalShownCount ?? 0)
        summaryTotal += 1
        summaryDistinct.insert(key)
        summaryEarliestAt = min(summaryEarliestAt ?? at, at)
    }

    /** Repeats reported some other way (a `(repeated xN)` flush, a
        recurrence's `seen before` count) leave the summary; once nothing is
        left in it, its start time goes too. */
    private mutating func releaseFromSummary(_ count: Int, key: RepeatKey) {
        guard count > 0 else { return }
        summaryTotal -= count
        summaryDistinct.remove(key)
        if summaryTotal <= 0 {
            summaryTotal = 0
            summaryEarliestAt = nil
        }
    }

    /** Flushes every LRU entry still holding suppressed repeats: `onlyStale`
        limits this to entries whose burst window has actually closed (the
        per-tick housekeeping call); `ended()` flushes everything regardless,
        since the run is over. */
    private mutating func flushPendingBurstRuns(at now: Date, onlyStale: Bool) -> [MonitorEvent] {
        var events: [MonitorEvent] = []
        for (key, entry) in repeatLRU.allEntries where entry.pendingSuppressed > 0 {
            if onlyStale, now.timeIntervalSince(entry.lastSeenAt) <= MonitorLimits.burstWindow {
                continue
            }
            events += applyBudget(
                .repeated(
                    at: entry.lastSeenAt, count: entry.pendingSuppressed, label: label, stream: key.stream.logStream,
                    text: entry.lastDisplayText),
                stream: key.stream)
            releaseFromSummary(entry.pendingSuppressed, key: key)
            var updated = entry
            updated.pendingSuppressed = 0
            repeatLRU[key] = updated
        }
        return events
    }

    /** Daemon-side trimming (the query's `totals` minus what it returned)
        never disappears silently: while out or err is already inside an
        over-budget window it folds into that window's resume count (the
        same suppression the user was already told about); otherwise, and
        always for sys and mark, which have no budget, it gets its own
        marker here, since nothing else ever saw lines the daemon never
        sent. */
    private mutating func applyDaemonTrimmed(_ trimmed: [LogStream: Int], at: Date) -> [MonitorEvent] {
        var events: [MonitorEvent] = []
        for stream in [LogStream.out, .err, .sys, .mark] {
            guard let count = trimmed[stream], count > 0 else { continue }
            if let child = ChildStream(stream), budgets[child].minuteOverBudget {
                budgets[child].daemonTrimmedSinceMarker += count
            } else {
                events.append(trimmedSkippedEvent(stream: stream, at: at, count: count))
            }
        }
        return events
    }

    private func trimmedSkippedEvent(stream: LogStream, at: Date, count: Int) -> MonitorEvent {
        let since = JSONCoding.formatISO8601(at)
        let text =
            "\(Self.lines(count, of: stream.rawValue)) skipped "
            + "(more than \(MonitorLimits.fetchCap(for: stream)) in one tick); "
            + "read them: directa logs \(hintName) --since \(since) --stream \(stream.rawValue) --head 200"
        return .suppressed(at: at, count: count, label: label, stream: stream, text: text)
    }

    /** Every rendered out/err event passes here, a flushed `(repeated xN)`
        included: each costs one token, and one withheld while over budget
        counts toward the resume marker exactly like a line. Otherwise a
        stream of distinct-but-repeating lines would reach the reader
        through its collapse markers with no budget at all. */
    private mutating func applyBudget(_ event: MonitorEvent, stream: ChildStream) -> [MonitorEvent] {
        let at = event.at
        var budget = budgets[stream]
        defer { budgets[stream] = budget }
        var events: [MonitorEvent] = []

        if budget.armCount >= budget.armCap {
            if !budget.armMarkerShown {
                budget.armMarkerShown = true
                events.append(overBudgetEvent(stream: stream.logStream, at: at, cap: budget.armCap, scope: .arm))
            }
            return events
        }

        budget.refill(at: at)
        /** Hysteresis: once over, a stream stays withheld until its bucket
            refills to the full burst. Resuming on the first refilled token
            would alternate an over-budget and a resume marker on every tick
            of a steadily chatty server, more noise than the lines withheld. */
        let resumeAt = budget.minuteOverBudget ? Double(budget.burstCapacity) : 1
        if budget.tokens < resumeAt {
            budget.withheldSinceMarker += 1
            if !budget.minuteOverBudget {
                budget.minuteOverBudget = true
                events.append(overBudgetEvent(stream: stream.logStream, at: at, cap: budget.perMinute, scope: .minute))
            }
            return events
        }

        if budget.minuteOverBudget {
            let suppressed = budget.withheldSinceMarker + budget.daemonTrimmedSinceMarker
            events.append(resumeEvent(stream: stream.logStream, at: at, suppressed: suppressed))
            budget.minuteOverBudget = false
            budget.withheldSinceMarker = 0
            budget.daemonTrimmedSinceMarker = 0
        }

        budget.tokens -= 1
        budget.armCount += 1
        events.append(event)
        return events
    }

    private func overBudgetEvent(stream: LogStream, at: Date, cap: Int, scope: BudgetScope) -> MonitorEvent {
        let scopeText =
            scope == .minute
            ? "more than \(Self.lines(cap)) a minute"
            : "\(Self.lines(cap)) for the rest of this monitor; re-arm to reset"
        let since = JSONCoding.formatISO8601(at)
        let text =
            "\(stream.rawValue) over budget (\(scopeText)); read what was skipped: "
            + "directa logs \(hintName) --since \(since) --stream \(stream.rawValue) --head 200"
        return .budget(at: at, count: cap, label: label, stream: stream, text: text)
    }

    /** "1 line", "3 lines", "1 out line", "3 repeated lines". */
    private static func lines(_ count: Int, of qualifier: String? = nil) -> String {
        let noun = count == 1 ? "line" : "lines"
        return [String(count), qualifier, noun].compactMap { $0 }.joined(separator: " ")
    }

    private func resumeEvent(stream: LogStream, at: Date, suppressed: Int) -> MonitorEvent {
        let text = "\(stream.rawValue) resumed (\(Self.lines(suppressed)) suppressed while over budget)"
        return .budget(at: at, count: suppressed, label: label, stream: stream, text: text)
    }

    // MARK: - Periodic summary

    private mutating func evaluatePeriodicSummary(now: Date) -> [MonitorEvent] {
        guard summaryTotal > 0 else { return [] }
        let cadenceDue = now.timeIntervalSince(lastSummaryAt) >= MonitorLimits.summaryCadence
        let quiet = lastOutErrActivityAt.map { now.timeIntervalSince($0) >= MonitorLimits.quietTrigger } ?? false
        guard cadenceDue || quiet else { return [] }
        lastSummaryAt = now
        return [takeSummary(at: now)]
    }

    /** The summary line, and a reset of what it reports, including each
        entry's pending count, so a later `(repeated xN)` flush or `seen
        before` count covers only repeats after this summary. Its command
        reads from the oldest repeat it counts, so every suppressed line lies
        inside what that command returns. */
    private mutating func takeSummary(at: Date) -> MonitorEvent {
        repeatLRU.clearPendingSuppressed()
        let since = JSONCoding.formatISO8601(summaryEarliestAt ?? at)
        let text =
            "\(Self.lines(summaryTotal, of: "repeated")) suppressed (\(summaryDistinct.count) distinct); "
            + "directa logs \(hintName) --since \(since) --head 200"
        let event = MonitorEvent.suppressed(at: at, count: summaryTotal, label: label, text: text)
        summaryDistinct.removeAll()
        summaryEarliestAt = nil
        summaryTotal = 0
        return event
    }

    // MARK: - Formatting helpers

    private static func formatWindow(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped < 60 { return "\(Int(clamped))s" }
        if clamped < 3_600 { return "\(Int(clamped / 60))m" }
        return "\(Int(clamped / 3_600))h"
    }

    private static func ordinalLabel(_ n: Int) -> String {
        let mod100 = n % 100
        let suffix: String
        if (11...13).contains(mod100) {
            suffix = "th"
        } else {
            switch n % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }
}
