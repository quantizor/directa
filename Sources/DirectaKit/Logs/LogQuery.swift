import Foundation

/** Query parameters for reading structured logs, with the meanings
    `LogsQueryParams` gives them on the wire. Callers screen them with
    `LogsQueryParams.refusal` first; past that screen `after` wins over
    `since`, a conflicting trim resolves as `head`, then `tailByStream`, then
    `tail`, and a negative count reads as zero. */
public struct LogQueryOptions: Sendable {
    public var after: LogCursor?
    /** Swift Regex pattern (compiled once per run; Regex itself is not Sendable). */
    public var grep: String?
    public var head: Int?
    public var maxLineCharacters: Int?
    public var since: Date?
    public var streams: Set<LogStream>?
    public var tail: Int?
    public var tailByStream: LogStreamCounts?

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
        self.after = after
        self.grep = grep
        self.head = head
        self.maxLineCharacters = maxLineCharacters
        self.since = since
        self.streams = streams
        self.tail = tail
        self.tailByStream = tailByStream
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
    public var totals: LogStreamCounts?

    public init(cursor: LogCursor, lines: [LogRecord], totals: LogStreamCounts? = nil) {
        self.cursor = cursor
        self.lines = lines
        self.totals = totals
    }
}

/** File-level query engine over a structured log family (current.log plus
    rotated .1-.5). Timestamps are per-file monotonic (the store clamps on
    append), which is what makes the binary search sound. */
public enum LogQuery {
    /** Oldest-first file list for a log family: highest rotation number first. */
    public static func familyFiles(current: URL, rotations: Int = 5) -> [URL] {
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

    /** Why a caller-supplied grep pattern must be refused, or nil when it is safe
        to run. Callers validate before querying: a pattern the engine cannot
        compile must not silently degrade into "no filter", because returning
        every line reads exactly like a query that matched everything. A pattern
        that compiles but nests an unbounded quantifier inside another is refused
        too: Swift's `Regex` backtracks, so `^(a+)+$` against a handful of
        characters runs for seconds and against a longer line never returns,
        wedging the log actor while it churns. The match runs per line, so this
        screen is the only place to stop it before it starts. */
    public static func grepRejection(_ pattern: String) -> String? {
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
        let count = LogStream.allCases.reduce(0) { $0 + (scanned.totals[$1] ?? 0) }
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
        let readers = collected.readers ?? files.map { LogFileReader(url: $0, onDiskRead: onDiskRead) }
        let newest = LogScan.newestGroup(readers: readers, resume: collected.resume)
        let cursor = newest.map { newest in
            LogCursor(
                at: LogScan.date(milliseconds: newest.ms), count: newest.count,
                position: newest.count >= positionThreshold
                    ? readers[newest.file].map { LogFilePosition(file: $0.inode, offset: newest.end) } : nil)
        }
        return LogWindow(cursor: cursor ?? .origin, lines: collected.lines, totals: collected.totals)
    }

    /** Same as `run`, but also reports the byte size of every disk read to
        `onDiskRead`, in call order. Internal-only observation seam (mirrors
        `ExitWatcher`'s `sharedQueueDescriptorForTesting`) that lets
        `LogQueryTests` prove the tail-only fast path reads only a bounded
        number of bytes off the end of a family far larger than the requested
        tail, by summing what a real `run(...)`-shaped call reports, rather
        than a wall-clock budget that flakes under system load. Each call
        supplies its own callback, so unlike a shared counter this carries no
        risk of one test's reads contaminating another's measurement when the
        suite runs in parallel. */
    static func runMeasured(
        current: URL, options: LogQueryOptions, onDiskRead: (@Sendable (Int) -> Void)?
    ) -> [LogRecord] {
        collect(files: familyFiles(current: current), options: options, onDiskRead: onDiskRead).lines
    }

    /** The answer, plus, when a forward scan ran, the readers it opened and
        where a cursor's position let it resume. */
    private static func collect(
        files: [URL], options: LogQueryOptions, onDiskRead: (@Sendable (Int) -> Void)?
    ) -> (lines: [LogRecord], readers: [LogFileReader?]?, resume: LogScan.Resume?, totals: LogStreamCounts?) {
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
            answer with the whole log. Fail closed and say so instead: callers
            screen user input with grepRejection first. */
        var grep: Regex<AnyRegexOutput>?
        if let pattern = options.grep {
            guard let compiled = try? Regex(pattern) else {
                DirectaLog.daemon.error("log query grep pattern does not compile: \(pattern)")
                return ([], nil, nil, options.reportsTotals ? LogStreamCounts(err: 0, mark: 0, out: 0, sys: 0) : nil)
            }
            grep = compiled
        }
        let scanned = LogScan.scan(files: files, options: options, grep: grep, onDiskRead: onDiskRead)
        return (
            truncated(scanned.lines, to: options.maxLineCharacters), scanned.readers, scanned.resume,
            options.reportsTotals ? scanned.totals : nil
        )
    }

    /** Cuts each text to `limit` characters, the last being `…`. */
    static func truncated(_ records: [LogRecord], to limit: Int?) -> [LogRecord] {
        guard let limit, limit >= 1 else { return records }
        return records.map { record in
            let text = record.text
            guard let cut = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex),
                cut < text.endIndex
            else { return record }
            let keep = text.index(text.startIndex, offsetBy: limit - 1)
            return LogRecord(at: record.at, stream: record.stream, text: String(text[..<keep]) + "…")
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
        guard tail > 0 else { return [] }
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
        guard needed > 0, let reader = LogFileReader(url: url, onDiskRead: onDiskRead) else { return [] }
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

    public static func lastLineTimestamp(of url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        let window: UInt64 = 64 * 1024
        let offset = size > window ? size - window : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            if let stamp = LogRecord.timestampPrefix(of: line) { return stamp }
        }
        return nil
    }
}
