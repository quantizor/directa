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

    /** The daemon's own `tailByStream` cap on out and err per query (the
        command layer's per-tick fetch uses the same number): past this many
        lines in one tick, the daemon trims before the client ever sees them,
        so a tick can under-report volume even while the client's own budget
        has room left. */
    public static let perTickFetchCap = 300

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

/** Everything a MonitorStream needs at construction. `label` and `serverName`
    are sanitized once, at construction, and every rendered event reuses that
    sanitized copy; nothing else in this file re-sanitizes them. */
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
    state change, so MonitorStream never needs to deduplicate it itself. */
public struct MonitorTick: Sendable {
    public var at: Date
    public var health: String?
    public var records: [LogRecord]
    public var trimmed: [LogStream: Int]

    public init(
        at: Date, health: String? = nil, records: [LogRecord] = [], trimmed: [LogStream: Int] = [:]
    ) {
        self.at = at
        self.health = health
        self.records = records
        self.trimmed = trimmed
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
    loses the millisecond ISO-8601 date format this type's golden depends on. */
public struct MonitorEvent: Codable, Equatable, Sendable {
    public var at: Date
    public var count: Int?
    public var kind: MonitorEventKind
    public var label: String
    public var stream: LogStream?
    public var text: String

    public init(
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
    loop constructs a `.transient` `MonitorEvent` directly (there is no
    `MonitorStream` method for a connection-level failure), and needs the same
    guarantees on the label it renders that as `directa <label>:`. */
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

    public static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

/** Normalizes volatile detail out of a line before it becomes a repeat-
    suppression lookup key, so two lines that differ only in a request id or a
    timestamp are recognized as the same recurring line. Order matters: UUIDs
    first (most specific), then timestamps, then hex runs (which require at
    least one a-f letter so a plain digit run is left for the number pass,
    the rule that keeps "200" and "500" distinct). */
enum LineNormalizer {
    /** `Regex` is a value type with no shared mutable state; these are
        `nonisolated(unsafe)` purely to avoid recompiling the pattern on every
        call, the pattern Apple documents for a static regex literal. */
    private nonisolated(unsafe) static let uuidPattern =
        /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/
    private nonisolated(unsafe) static let timestampPattern =
        /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z?/
    private nonisolated(unsafe) static let hexRunPattern =
        /\b(?=[0-9a-fA-F]*[a-fA-F])[0-9a-fA-F]{6,}\b/
    private nonisolated(unsafe) static let longNumberPattern = /\d{5,}/

    static func normalize(_ text: String) -> String {
        var result = text
        result.replace(uuidPattern, with: "<uuid>")
        result.replace(timestampPattern, with: "<timestamp>")
        result.replace(hexRunPattern, with: "<hex>")
        result.replace(longNumberPattern, with: "<num>")
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

    private struct RepeatKey: Hashable {
        var normalized: String
        var stream: LogStream
    }

    /** A fixed-capacity, insertion/access-ordered cache: the LRU the plan
        calls for. 512 entries is small enough that a linear position update
        on write is not worth a doubly-linked structure. */
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
        var armCount = 0
        var armMarkerShown = false
        var daemonTrimmedSinceMarker = 0
        var lastRefillAt: Date
        var minuteOverBudget = false
        var tokens: Double
        var withheldSinceMarker = 0

        init(capacity: Double, at: Date) {
            tokens = capacity
            lastRefillAt = at
        }

        mutating func refill(at date: Date, ratePerMinute: Int, capacity: Int) {
            let elapsed = max(0, date.timeIntervalSince(lastRefillAt))
            tokens = min(Double(capacity), tokens + elapsed * Double(ratePerMinute) / 60)
            lastRefillAt = date
        }
    }

    private enum BudgetScope {
        case arm
        case minute
    }

    private var blockContinuation: [LogStream: Bool] = [:]
    private let config: MonitorConfig
    private var errBudget: TokenBudget
    private var lastKnownAt: Date
    private var lastOutErrActivityAt: Date?
    private var lastRecordAt: [LogStream: Date] = [:]
    private var lastSummaryAt: Date
    private var lifecyclePending: [LogStream: PendingRun] = [:]
    private var outBudget: TokenBudget
    private var repeatLRU: RepeatLRU
    private var sanitizedLabel: String
    private var sanitizedServerName: String
    private var summaryDistinct: Set<RepeatKey> = []
    private var summaryTotal = 0

    public init(config: MonitorConfig) {
        self.config = config
        errBudget = TokenBudget(
            capacity: Double(MonitorLimits.burstCapacity(perMinute: config.budgets.errorsPerMinute)),
            at: config.clockStart)
        lastKnownAt = config.clockStart
        lastSummaryAt = config.clockStart
        outBudget = TokenBudget(
            capacity: Double(MonitorLimits.burstCapacity(perMinute: config.budgets.linesPerMinute)),
            at: config.clockStart)
        repeatLRU = RepeatLRU(capacity: MonitorLimits.lruCapacity)
        sanitizedLabel = MonitorSanitizer.sanitizeLabel(config.label)
        sanitizedServerName = MonitorSanitizer.sanitize(config.serverName)
    }

    // MARK: - Public surface

    public mutating func attached(_ summary: MonitorAttachSummary) -> [MonitorEvent] {
        let budgets = config.budgets
        let text =
            "monitoring \(summary.checkoutPath) (\(summary.statusDescription); "
            + "budget \(budgets.linesPerMinute)/min and \(budgets.linesPerArm)/arm, "
            + "errors \(budgets.errorsPerMinute)/min and \(budgets.errorsPerArm)/arm); "
            + "earlier output: directa logs \(sanitizedServerName) --tail 200"
        return [MonitorEvent(at: lastKnownAt, kind: .attached, label: sanitizedLabel, text: text)]
    }

    public mutating func ingest(_ tick: MonitorTick) -> [MonitorEvent] {
        lastKnownAt = tick.at
        var events: [MonitorEvent] = []
        events += applyDaemonTrimmed(tick.trimmed, at: tick.at)
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
            let text = MonitorSanitizer.truncate(
                MonitorSanitizer.sanitize(health), limit: MonitorLimits.truncationCharacterLimit)
            events.append(MonitorEvent(at: tick.at, kind: .health, label: sanitizedLabel, text: text))
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
        events.append(MonitorEvent(at: lastKnownAt, kind: .ended, label: sanitizedLabel, text: "ended (\(reason))"))
        return events
    }

    /** The 29-minute hard cap (below Claude Code's 30-minute Monitor kill, so
        this line is delivered before the tool would drop the process
        itself): worded as a next step rather than `ended(reason:)`'s
        parenthetical, since re-arming is the whole point of this ending. */
    public mutating func endedAtHardCap() -> [MonitorEvent] {
        var events = flushForEnd()
        events.append(
            MonitorEvent(
                at: lastKnownAt, kind: .ended, label: sanitizedLabel,
                text: "ended after 29 minutes; run the same command again to keep watching"))
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
                    MonitorEvent(
                        at: pending.at, count: pending.count - 1, kind: .repeated, label: sanitizedLabel,
                        stream: stream, text: pending.text))
            }
            lifecyclePending[stream] = nil
        }
        if summaryTotal > 0 {
            events.append(summaryEvent(at: lastKnownAt))
            summaryTotal = 0
            summaryDistinct.removeAll()
        }
        return events.sorted { $0.at < $1.at }
    }

    // MARK: - Record classification

    private mutating func process(_ record: LogRecord) -> [MonitorEvent] {
        switch record.stream {
        case .sys:
            return processSys(record)
        case .mark:
            return processMark(record)
        case .out, .err:
            return processChildLine(record)
        }
    }

    /** `rotated` is the one sys line that never reaches the transcript at
        all; every other producer (started/exited/stopping/spawn failed/
        adopted/watch suspended/spool catch-up/stuck stop, or anything a
        future producer adds) renders identically, so there is nothing else
        to branch on here. */
    private mutating func processSys(_ record: LogRecord) -> [MonitorEvent] {
        guard record.text != "rotated" else { return [] }
        let text = MonitorSanitizer.truncate(
            MonitorSanitizer.sanitize(record.text), limit: MonitorLimits.truncationCharacterLimit)
        return collapseLifecycle(stream: .sys, text: text, at: record.at)
    }

    private mutating func processMark(_ record: LogRecord) -> [MonitorEvent] {
        let inner = MonitorSanitizer.truncate(
            MonitorSanitizer.sanitize(record.text), limit: MonitorLimits.truncationCharacterLimit)
        return collapseLifecycle(stream: .mark, text: "mark \(inner)", at: record.at)
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
                MonitorEvent(
                    at: pending.at, count: pending.count - 1, kind: .repeated, label: sanitizedLabel,
                    stream: stream, text: pending.text))
        }
        events.append(MonitorEvent(at: at, kind: .lifecycle, label: sanitizedLabel, stream: stream, text: text))
        lifecyclePending[stream] = PendingRun(at: at, count: 1, text: text)
        return events
    }

    // MARK: - Out/err repeat suppression and budgets

    private mutating func processChildLine(_ record: LogRecord) -> [MonitorEvent] {
        let stream = record.stream
        let displayText = MonitorSanitizer.truncate(
            MonitorSanitizer.sanitize(record.text), limit: MonitorLimits.truncationCharacterLimit)
        let key = RepeatKey(normalized: LineNormalizer.normalize(displayText), stream: stream)

        /** A reprinted multi-line block (a stack trace) opens on its first
            line's recurrence and, while lines keep arriving inside the same
            burst window, forces every following line into burst-repeat
            handling regardless of that line's own timer: the block's later
            lines never get their own individual "(again...)" annotation. */
        let gapSinceLastRecord =
            lastRecordAt[stream].map { record.at.timeIntervalSince($0) } ?? .infinity
        let continuingBlock =
            (blockContinuation[stream] ?? false) && gapSinceLastRecord <= MonitorLimits.burstWindow
        lastRecordAt[stream] = record.at
        if gapSinceLastRecord > MonitorLimits.burstWindow {
            blockContinuation[stream] = false
        }
        lastOutErrActivityAt = record.at

        if continuingBlock {
            recordBurstRepeat(key: key, displayText: displayText, at: record.at)
            return []
        }

        guard let entry = repeatLRU[key] else {
            repeatLRU[key] = RepeatEntry(
                firstShownAt: record.at, lastDisplayText: displayText, lastSeenAt: record.at,
                pendingSuppressed: 0, totalShownCount: 1)
            blockContinuation[stream] = false
            return applyBudget(stream: stream, text: displayText, at: record.at)
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
        if suppressedBefore > 0 {
            summaryTotal -= suppressedBefore
            summaryDistinct.remove(key)
        }

        repeatLRU[key] = RepeatEntry(
            firstShownAt: entry.firstShownAt, lastDisplayText: displayText, lastSeenAt: record.at,
            pendingSuppressed: 0, totalShownCount: ordinal)
        blockContinuation[stream] = true
        return applyBudget(stream: stream, text: text, at: record.at)
    }

    private mutating func recordBurstRepeat(key: RepeatKey, displayText: String, at: Date) {
        let existing = repeatLRU[key]
        repeatLRU[key] = RepeatEntry(
            firstShownAt: existing?.firstShownAt ?? at, lastDisplayText: displayText, lastSeenAt: at,
            pendingSuppressed: (existing?.pendingSuppressed ?? 0) + 1,
            totalShownCount: existing?.totalShownCount ?? 0)
        summaryTotal += 1
        summaryDistinct.insert(key)
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
            events.append(
                MonitorEvent(
                    at: entry.lastSeenAt, count: entry.pendingSuppressed, kind: .repeated,
                    label: sanitizedLabel, stream: key.stream, text: entry.lastDisplayText))
            summaryTotal -= entry.pendingSuppressed
            summaryDistinct.remove(key)
            var updated = entry
            updated.pendingSuppressed = 0
            repeatLRU[key] = updated
        }
        return events
    }

    /** Daemon-side trimming (the query's `totals` minus what it returned)
        never disappears silently: while a stream is already inside an
        over-budget window it folds into that window's resume count (the
        same suppression the user was already told about); otherwise it gets
        its own marker here, since the client budget never got a chance to
        suppress lines the daemon itself never sent. */
    private mutating func applyDaemonTrimmed(_ trimmed: [LogStream: Int], at: Date) -> [MonitorEvent] {
        var events: [MonitorEvent] = []
        for stream in [LogStream.out, .err] {
            guard let count = trimmed[stream], count > 0 else { continue }
            var budget = budget(for: stream)
            if budget.minuteOverBudget {
                budget.daemonTrimmedSinceMarker += count
            } else {
                events.append(trimmedSkippedEvent(stream: stream, at: at, count: count))
            }
            setBudget(budget, for: stream)
        }
        return events
    }

    private func trimmedSkippedEvent(stream: LogStream, at: Date, count: Int) -> MonitorEvent {
        let since = JSONCoding.formatISO8601(at)
        let text =
            "\(Self.lines(count, of: stream)) skipped (more than \(MonitorLimits.perTickFetchCap) in one tick); "
            + "read them: directa logs \(sanitizedServerName) --since \(since) --stream \(stream.rawValue) --head 200"
        return MonitorEvent(at: at, count: count, kind: .suppressed, label: sanitizedLabel, stream: stream, text: text)
    }

    private mutating func applyBudget(stream: LogStream, text: String, at: Date) -> [MonitorEvent] {
        var budget = budget(for: stream)
        defer { setBudget(budget, for: stream) }
        var events: [MonitorEvent] = []

        let armCeiling = armCap(for: stream)
        if budget.armCount >= armCeiling {
            if !budget.armMarkerShown {
                budget.armMarkerShown = true
                events.append(overBudgetEvent(stream: stream, at: at, cap: armCeiling, scope: .arm))
            }
            return events
        }

        budget.refill(at: at, ratePerMinute: perMinuteCap(for: stream), capacity: burstCapacity(for: stream))
        /** Hysteresis: once over, a stream stays withheld until its bucket
            refills to the full burst. Resuming on the first refilled token
            would alternate an over-budget and a resume marker on every tick
            of a steadily chatty server, more noise than the lines withheld. */
        let resumeAt = budget.minuteOverBudget ? Double(burstCapacity(for: stream)) : 1
        if budget.tokens < resumeAt {
            budget.withheldSinceMarker += 1
            if !budget.minuteOverBudget {
                budget.minuteOverBudget = true
                events.append(
                    overBudgetEvent(stream: stream, at: at, cap: perMinuteCap(for: stream), scope: .minute))
            }
            return events
        }

        if budget.minuteOverBudget {
            let suppressed = budget.withheldSinceMarker + budget.daemonTrimmedSinceMarker
            events.append(resumeEvent(stream: stream, at: at, suppressed: suppressed))
            budget.minuteOverBudget = false
            budget.withheldSinceMarker = 0
            budget.daemonTrimmedSinceMarker = 0
        }

        budget.tokens -= 1
        budget.armCount += 1
        events.append(MonitorEvent(at: at, kind: .line, label: sanitizedLabel, stream: stream, text: text))
        return events
    }

    private func budget(for stream: LogStream) -> TokenBudget {
        stream == .out ? outBudget : errBudget
    }

    private mutating func setBudget(_ value: TokenBudget, for stream: LogStream) {
        if stream == .out {
            outBudget = value
        } else {
            errBudget = value
        }
    }

    private func armCap(for stream: LogStream) -> Int {
        stream == .out ? config.budgets.linesPerArm : config.budgets.errorsPerArm
    }

    private func perMinuteCap(for stream: LogStream) -> Int {
        stream == .out ? config.budgets.linesPerMinute : config.budgets.errorsPerMinute
    }

    private func burstCapacity(for stream: LogStream) -> Int {
        MonitorLimits.burstCapacity(perMinute: perMinuteCap(for: stream))
    }

    private func overBudgetEvent(stream: LogStream, at: Date, cap: Int, scope: BudgetScope) -> MonitorEvent {
        let scopeText =
            scope == .minute
            ? "more than \(Self.lines(cap)) a minute"
            : "\(Self.lines(cap)) for the rest of this monitor; re-arm to reset"
        let since = JSONCoding.formatISO8601(at)
        let text =
            "\(stream.rawValue) over budget (\(scopeText)); read what was skipped: "
            + "directa logs \(sanitizedServerName) --since \(since) --stream \(stream.rawValue) --head 200"
        return MonitorEvent(at: at, count: cap, kind: .budget, label: sanitizedLabel, stream: stream, text: text)
    }

    /** "1 line", "3 lines", "1 out line", "3 repeated lines". */
    private static func lines(_ count: Int, of qualifier: String? = nil) -> String {
        let noun = count == 1 ? "line" : "lines"
        return [String(count), qualifier, noun].compactMap { $0 }.joined(separator: " ")
    }

    private static func lines(_ count: Int, of stream: LogStream) -> String {
        lines(count, of: stream.rawValue)
    }

    private func resumeEvent(stream: LogStream, at: Date, suppressed: Int) -> MonitorEvent {
        let text = "\(stream.rawValue) resumed (\(Self.lines(suppressed)) suppressed while over budget)"
        return MonitorEvent(
            at: at, count: suppressed, kind: .budget, label: sanitizedLabel, stream: stream, text: text)
    }

    // MARK: - Periodic summary

    private mutating func evaluatePeriodicSummary(now: Date) -> [MonitorEvent] {
        guard summaryTotal > 0 else { return [] }
        let cadenceDue = now.timeIntervalSince(lastSummaryAt) >= MonitorLimits.summaryCadence
        let quiet = lastOutErrActivityAt.map { now.timeIntervalSince($0) >= MonitorLimits.quietTrigger } ?? false
        guard cadenceDue || quiet else { return [] }
        let event = summaryEvent(at: now)
        summaryTotal = 0
        summaryDistinct.removeAll()
        lastSummaryAt = now
        return [event]
    }

    private func summaryEvent(at: Date) -> MonitorEvent {
        let since = JSONCoding.formatISO8601(at)
        let text =
            "\(Self.lines(summaryTotal, of: "repeated")) suppressed (\(summaryDistinct.count) distinct); "
            + "directa logs \(sanitizedServerName) --since \(since) --head 200"
        return MonitorEvent(at: at, count: summaryTotal, kind: .suppressed, label: sanitizedLabel, text: text)
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
