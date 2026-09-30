import Foundation

/** Query parameters for reading structured logs, with the meanings
    `LogsQueryParams` gives them on the wire. Callers screen them with
    `LogsQueryParams.refusal` first; past that screen `after` wins over
    `since`, a conflicting trim resolves as `head`, then `tailByStream`, then
    `tail`, and a negative count reads as zero. */
public struct LogQueryOptions: Sendable {
    public let after: LogCursor?
    /** Swift Regex pattern (compiled once per run; Regex itself is not Sendable). */
    public let grep: String?
    public let head: Int?
    public let maxLineCharacters: Int?
    public let since: Date?
    public let streams: Set<LogStream>?
    public let tail: Int?
    public let tailByStream: LogStreamCounts?

    /** Every count is stored at zero or more, so nothing past this point
        guards against a negative one. */
    public init(
        after: LogCursor? = nil,
        grep: String? = nil,
        head: Int? = nil,
        maxLineCharacters: Int? = nil,
        since: Date? = nil,
        streams: Set<LogStream>? = nil,
        tail: Int? = nil,
        tailByStream: LogStreamCounts? = nil
    ) {
        func count(_ value: Int?) -> Int? { value.map { max(0, $0) } }
        self.after = after.map { LogCursor(at: $0.at, count: max(0, $0.count), position: $0.position) }
        self.grep = grep
        self.head = count(head)
        self.maxLineCharacters = maxLineCharacters
        self.since = since
        self.streams = streams
        self.tail = count(tail)
        self.tailByStream = tailByStream.map {
            LogStreamCounts(err: count($0.err), mark: count($0.mark), out: count($0.out), sys: count($0.sys))
        }
    }

    /** The options a wire query asks for, with `since` already resolved
        from its `since` or `sinceMark`. */
    public init(_ params: LogsQueryParams, since: Date?) {
        self.init(
            after: params.after, grep: params.grep, head: params.head,
            maxLineCharacters: params.maxLineCharacters, since: since, streams: params.streams.map(Set.init),
            tail: params.tail, tailByStream: params.tailByStream)
    }

    /** The shapes that carry per-stream totals in their answer: the ones a
        poller reads past a cursor or trims per stream. A `head` alone does
        not, so it can stop reading once it holds its lines. */
    var reportsTotals: Bool { after != nil || tailByStream != nil }
}

/** A query's answer: the lines, the family's end position when it ran, and
    (for the shapes that report them) the matched count per stream before any
    trim, so a caller knows exactly how many lines it was not shown. */
public struct LogWindow: Equatable, Sendable {
    public var cursor: LogCursor
    public var lines: [LogRecord]
    public var totals: LogStreamTotals?

    public init(cursor: LogCursor, lines: [LogRecord], totals: LogStreamTotals? = nil) {
        self.cursor = cursor
        self.lines = lines
        self.totals = totals
    }
}

/** File-level query engine over a structured log family (current.log plus
    its numbered rotations). Timestamps are per-file monotonic (the store
    clamps on append), which is what makes the binary search sound. */
public enum LogQuery {
    /** How many rotated files a family keeps behind current.log. */
    public static let rotations = 5

    /** Oldest-first file list for a log family: highest rotation number first. */
    public static func familyFiles(current: URL) -> [URL] {
        var files: [URL] = []
        for index in stride(from: rotations, through: 1, by: -1) {
            let rotated = current.appendingPathExtension("\(index)")
            if FileManager.default.fileExists(atPath: rotated.path) {
                files.append(rotated)
            }
        }
        if FileManager.default.fileExists(atPath: current.path) {
            files.append(current)
        }
        return files
    }

    /** Why a caller-supplied grep pattern must be refused, or nil when it is
        safe to run. `LogsQueryParams.refusal` runs it before a query: a
        pattern the engine cannot compile must not silently degrade into "no
        filter", because returning every line reads exactly like a query that
        matched everything. A pattern
        that compiles but nests an unbounded quantifier inside another is refused
        too: Swift's `Regex` backtracks, so `^(a+)+$` against a handful of
        characters runs for seconds and against a longer line never returns,
        wedging the log actor while it churns. The match runs per line, so this
        screen is the only place to stop it before it starts. */
    static func grepRejection(_ pattern: String) -> String? {
        do {
            _ = try Regex(pattern)
        } catch {
            return String(describing: error)
        }
        if nestsUnboundedQuantifier(pattern) {
            return
                "'\(pattern)' repeats a group that itself repeats without bound (like (a+)+), which can make the log reader run for minutes on a single line; rewrite it without the nested repeat"
        }
        return nil
    }

    /** True when an unbounded quantifier (`*`, `+`, `{n,}`) is applied to a group
        whose body already contains an unbounded quantifier: the nested-quantifier
        form of catastrophic backtracking, e.g. `(a+)+`. A lexical scan rather
        than a full parser, tuned to reject that shape while leaving common safe
        patterns alone: a bounded outer repeat (`(a+){2}`), disjoint alternation
        (`(foo|bar)+`), a class (`[a-z]+`), and any top-level quantifier
        (`error.*failed`) are all fine because none nests an unbounded repeat
        inside a repeated group. This does not catch alternation-overlap
        backtracking (`(a|a)*`), the other exponential family the same engine is
        vulnerable to; the client response deadline is the backstop for that. */
    static func nestsUnboundedQuantifier(_ pattern: String) -> Bool {
        let chars = Array(pattern)
        /** One flag per open group: does its body hold an unbounded quantifier. */
        var groupHasUnbounded: [Bool] = []
        var inClass = false
        var index = 0
        func unboundedBraceLength(at start: Int) -> Int? {
            /** `{n,}` is unbounded; `{n}` and `{n,m}` are not. Returns the token
                length when unbounded so the caller can also treat it as applying
                to whatever precedes it. */
            guard start < chars.count, chars[start] == "{" else { return nil }
            var cursor = start + 1
            var digits = 0
            while cursor < chars.count, chars[cursor].isNumber { cursor += 1; digits += 1 }
            guard digits > 0, cursor < chars.count, chars[cursor] == "," else { return nil }
            cursor += 1
            guard cursor < chars.count, chars[cursor] == "}" else { return nil }
            return cursor - start + 1
        }
        while index < chars.count {
            let char = chars[index]
            if char == "\\" { index += 2; continue }
            if inClass {
                if char == "]" { inClass = false }
                index += 1
                continue
            }
            switch char {
            case "[":
                inClass = true
            case "(":
                groupHasUnbounded.append(false)
            case ")":
                let innerUnbounded = groupHasUnbounded.popLast() ?? false
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                let appliedUnbounded =
                    next == "*" || next == "+" || unboundedBraceLength(at: index + 1) != nil
                if appliedUnbounded && innerUnbounded { return true }
                /** A quantified group is itself an unbounded repeat inside its
                    parent, so propagate upward. */
                if appliedUnbounded, !groupHasUnbounded.isEmpty {
                    groupHasUnbounded[groupHasUnbounded.count - 1] = true
                }
            case "*", "+":
                if !groupHasUnbounded.isEmpty {
                    groupHasUnbounded[groupHasUnbounded.count - 1] = true
                }
            case "{":
                if unboundedBraceLength(at: index) != nil, !groupHasUnbounded.isEmpty {
                    groupHasUnbounded[groupHasUnbounded.count - 1] = true
                }
            default:
                break
            }
            index += 1
        }
        return false
    }

    /** Counts records on the given streams and brackets them in time, without
        building the array. The count and the two timestamps are directa's own
        arithmetic over the log, safe to put in an agent's context where the lines
        themselves must never go. `since` bounds the window to one process's run
        (current.log is append-only across spawns), and drives the same file-skip
        and binary search `run` uses, so it does not scan a long history. */
    public static func summarize(current: URL, streams: Set<LogStream>, since: Date?) -> ErrorSummary? {
        summarizeMeasured(current: current, streams: streams, since: since, onDiskRead: nil)
    }

    /** Keeps only the first and last match, so memory stays flat however
        many records match. */
    static func summarizeMeasured(
        current: URL, streams: Set<LogStream>, since: Date?, onDiskRead: (@Sendable (Int) -> Void)?
    ) -> ErrorSummary? {
        let scanned = LogScan.scan(
            files: familyFiles(current: current), options: LogQueryOptions(since: since, streams: streams),
            grep: nil, retention: .firstAndLast, onDiskRead: onDiskRead)
        let count = scanned.totals.sum
        guard count > 0, let first = scanned.lines.first, let last = scanned.lines.last else { return nil }
        return ErrorSummary(count: count, firstAt: first.at, lastAt: last.at)
    }

    public static func run(current: URL, options: LogQueryOptions) -> [LogRecord] {
        runMeasured(current: current, options: options, onDiskRead: nil)
    }

    /** `run` plus the family's end cursor and, for the shapes that report
        them, per-stream totals. */
    public static func window(current: URL, options: LogQueryOptions) -> LogWindow {
        windowMeasured(current: current, options: options, onDiskRead: nil)
    }

    /** A cursor carries a position once its millisecond holds this many
        records. Below it, counting through them again on the next poll
        costs one small read, and a count-only cursor keeps the wire
        answer in its older shape. */
    static let positionThreshold = 1024

    static func windowMeasured(
        current: URL, options: LogQueryOptions, positionThreshold: Int = positionThreshold,
        onDiskRead: (@Sendable (Int) -> Void)?
    ) -> LogWindow {
        let files = familyFiles(current: current)
        let collected = collect(files: files, options: options, onDiskRead: onDiskRead)
        let readers = collected.readers ?? LogFileReader.readers(for: files, onDiskRead: onDiskRead)
        let newest = LogScan.newestGroup(readers: readers, resume: collected.resume)
        let cursor = newest.map { newest in
            LogCursor(
                at: LogScan.date(milliseconds: newest.ms), count: newest.count,
                position: newest.count >= positionThreshold
                    ? LogFilePosition(file: readers[newest.file].inode, offset: newest.end) : nil)
        }
        return LogWindow(cursor: cursor ?? .origin, lines: collected.lines, totals: collected.totals)
    }

    /** `run`, reporting the byte count of every disk read to `onDiskRead`
        in call order: every read a query makes goes through
        `LogFileReader`, so a sum of these bounds what the query read. */
    static func runMeasured(
        current: URL, options: LogQueryOptions, onDiskRead: (@Sendable (Int) -> Void)?
    ) -> [LogRecord] {
        collect(files: familyFiles(current: current), options: options, onDiskRead: onDiskRead).lines
    }

    /** The answer, plus, when a forward scan ran, the readers it opened and
        where a cursor's position let it resume. */
    private static func collect(
        files: [URL], options: LogQueryOptions, onDiskRead: (@Sendable (Int) -> Void)?
    ) -> (lines: [LogRecord], readers: [LogFileReader]?, resume: LogScan.GroupEnd?, totals: LogStreamTotals?) {
        /** A tail with no grep and no lower bound is answerable from the end
            of the family backward, without reading older files a caller never
            asked to see: `directa logs <name> --tail 50` must not read a whole
            10 MB rotation to hand back 50 lines. Every other shape scans
            forward from its lower bound, so this fast path is scoped to the
            one shape that has no reason to touch bytes it will discard. */
        if let tail = options.tail, options.since == nil, options.after == nil,
            options.grep == nil, options.head == nil, options.tailByStream == nil
        {
            let lines = tailOnly(files: files, tail: tail, streams: options.streams, onDiskRead: onDiskRead)
            return (truncated(lines, to: options.maxLineCharacters), nil, nil, nil)
        }
        /** A pattern that will not compile filters nothing out, so it would
            answer with the whole log. Fail closed and say so instead: a wire
            query is screened by `LogsQueryParams.refusal` first. */
        var grep: Regex<AnyRegexOutput>?
        if let pattern = options.grep {
            guard let compiled = try? Regex(pattern) else {
                DirectaLog.daemon.error("log query grep pattern does not compile: \(pattern)")
                return ([], nil, nil, options.reportsTotals ? LogStreamTotals() : nil)
            }
            grep = compiled
        }
        let scanned = LogScan.scan(files: files, options: options, grep: grep, onDiskRead: onDiskRead)
        return (
            truncated(scanned.lines, to: options.maxLineCharacters), scanned.readers, scanned.resume,
            options.reportsTotals ? scanned.totals : nil
        )
    }

    private static func truncated(_ records: [LogRecord], to limit: Int?) -> [LogRecord] {
        guard let limit else { return records }
        return records.map { record in
            LogRecord(
                at: record.at, stream: record.stream,
                text: LogSanitizer.truncated(record.text, toCharacters: limit))
        }
    }

    /** Newest-file-first tail: pulls just enough lines off the end of the
        family to answer `tail`, oldest file only once a newer one runs dry.
        Reproduces the forward scan's trim-to-tail result exactly (same
        records, same order) without reading a file whose contribution to the
        tail is zero. */
    private static func tailOnly(
        files: [URL], tail: Int, streams: Set<LogStream>?,
        onDiskRead: (@Sendable (Int) -> Void)?
    ) -> [LogRecord] {
        var collected: [LogRecord] = []
        for file in files.reversed() {
            guard collected.count < tail else { break }
            let fromThisFile = tailRecords(
                of: file, needed: tail - collected.count, streams: streams, onDiskRead: onDiskRead)
            collected = fromThisFile + collected
        }
        return collected
    }

    /** Up to `needed` records off the end of one file, oldest-first, read
        backward in fixed chunks: a file far larger than the requested tail
        is never read past the bytes that satisfy it, and a `streams` filter
        that thins the tail out walks further back without holding more than
        a chunk. */
    private static func tailRecords(
        of url: URL, needed: Int, streams: Set<LogStream>?,
        onDiskRead: (@Sendable (Int) -> Void)?
    ) -> [LogRecord] {
        guard let reader = LogFileReader(url: url, onDiskRead: onDiskRead) else { return [] }
        var matched: [LogRecord] = []
        reader.forEachLineBackward(before: reader.size) { line, _ in
            guard let record = LogScan.record(from: line, streams: streams) else { return true }
            matched.append(record)
            return matched.count < needed
        }
        return matched.reversed()
    }

    /** Timestamp of a mark record whose payload starts with `<id>\t`. */
    public static func markDate(current: URL, markID: String) -> Date? {
        let marks = run(current: current, options: LogQueryOptions(streams: [.mark]))
        return marks.first { $0.text.hasPrefix("\(markID)\t") || $0.text == markID }?.at
    }

    /** The timestamp of the last record in one log file, or nil when it
        holds none or cannot be opened. */
    public static func lastRecordDate(of url: URL) -> Date? {
        LogFileReader(url: url, onDiskRead: nil)?.lastRecordMilliseconds().map(LogScan.date(milliseconds:))
    }
}
