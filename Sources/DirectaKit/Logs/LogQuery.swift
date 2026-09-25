import Foundation

/** Query parameters for reading structured logs. `sinceMark` resolves to the
    timestamp of the mark whose payload begins with that id. */
public struct LogQueryOptions: Sendable {
    /** Swift Regex pattern (compiled once per run; Regex itself is not Sendable). */
    public var grep: String?
    public var since: Date?
    public var streams: Set<LogStream>?
    public var tail: Int?

    public init(
        grep: String? = nil,
        since: Date? = nil,
        streams: Set<LogStream>? = nil,
        tail: Int? = nil
    ) {
        self.grep = grep
        self.since = since
        self.streams = streams
        self.tail = tail
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
        var count = 0
        var first: Date?
        var last: Date?
        for record in run(current: current, options: LogQueryOptions(since: since, streams: streams)) {
            count += 1
            if first == nil { first = record.at }
            last = record.at
        }
        guard count > 0, let first, let last else { return nil }
        return ErrorSummary(count: count, firstAt: first, lastAt: last)
    }

    public static func run(current: URL, options: LogQueryOptions) -> [LogRecord] {
        /** A tail with no grep and no since is answerable from the end of the
            family backward, without materializing older files a caller never
            asked to see: `directa logs <name> --tail 50` must not read a whole
            10 MB rotation to hand back 50 lines. `since` already skips whole
            files via `lastLineTimestamp`, and `grep` must scan forward for
            correctness, so this fast path is scoped to the one shape that has
            no reason to touch bytes it will discard. */
        if let tail = options.tail, options.since == nil, options.grep == nil {
            return tailOnly(current: current, tail: tail, streams: options.streams)
        }
        /** A pattern that will not compile filters nothing out, so it would
            answer with the whole log. Fail closed and say so instead: callers
            screen user input with grepRejection first. */
        var grep: Regex<AnyRegexOutput>?
        if let pattern = options.grep {
            guard let compiled = try? Regex(pattern) else {
                DirectaLog.daemon.error("log query grep pattern does not compile: \(pattern)")
                return []
            }
            grep = compiled
        }
        var records: [LogRecord] = []
        for file in familyFiles(current: current) {
            /** Whole-file skip: a file whose last line predates `since` cannot
                contribute. */
            if let since = options.since,
                let last = lastLineTimestamp(of: file), last < since {
                continue
            }
            guard let data = try? Data(contentsOf: file), !data.isEmpty else { continue }
            let text = String(decoding: data, as: UTF8.self)
            var startIndex = text.startIndex
            if let since = options.since {
                startIndex = firstLineIndex(atOrAfter: since, in: text)
            }
            for line in text[startIndex...].split(separator: "\n", omittingEmptySubsequences: true) {
                guard let record = LogRecord.parse(line) else { continue }
                if let since = options.since, record.at < since { continue }
                if let streams = options.streams, !streams.contains(record.stream) { continue }
                if let grep, (try? grep.firstMatch(in: record.text)) == nil { continue }
                records.append(record)
            }
        }
        if let tail = options.tail, records.count > tail {
            records.removeFirst(records.count - tail)
        }
        return records
    }

    /** Newest-file-first tail: pulls just enough lines off the end of the
        family to answer `tail`, oldest file only once a newer one runs dry.
        Reproduces `run`'s trim-to-tail result exactly (same records, same
        order) without reading a file whose contribution to the tail is zero. */
    private static func tailOnly(current: URL, tail: Int, streams: Set<LogStream>?) -> [LogRecord] {
        guard tail > 0 else { return [] }
        var collected: [LogRecord] = []
        for file in familyFiles(current: current).reversed() {
            guard collected.count < tail else { break }
            let fromThisFile = tailRecords(of: file, needed: tail - collected.count, streams: streams)
            collected = fromThisFile + collected
        }
        return collected
    }

    /** Up to `needed` records off the end of one file, oldest-first. Reads a
        doubling window from the end (64 KB, 128 KB, ...) so a file far larger
        than the requested tail is never read past the bytes that satisfy it;
        the window only grows past `needed` lines when a `streams` filter
        thins the tail out. Growth is geometric, so total bytes read stay
        within roughly twice whatever window finally satisfied the request. */
    private static func tailRecords(of url: URL, needed: Int, streams: Set<LogStream>?) -> [LogRecord] {
        guard needed > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return [] }
        var window: UInt64 = 64 * 1024
        while true {
            let start = size > window ? size - window : 0
            let clean = start == 0 || startsAtLineBoundary(start, handle: handle)
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd()
            else { return [] }
            var lines = Array(String(decoding: data, as: UTF8.self).split(
                separator: "\n", omittingEmptySubsequences: true))
            /** A window boundary that does not land on a newline cuts a line in
                half; the half inside this window is missing its earlier bytes
                and must not be parsed, or a partial line would masquerade as a
                real (and wrong) record. The next-older window recovers it whole. */
            if !clean, !lines.isEmpty { lines.removeFirst() }
            var matched: [LogRecord] = []
            for line in lines.reversed() {
                guard let record = LogRecord.parse(line) else { continue }
                if let streams, !streams.contains(record.stream) { continue }
                matched.append(record)
                if matched.count == needed { break }
            }
            if matched.count >= needed || start == 0 {
                return matched.reversed()
            }
            window *= 2
        }
    }

    /** True when the byte immediately before `offset` is a newline, i.e.
        `offset` itself opens a new line rather than landing mid-line. */
    private static func startsAtLineBoundary(_ offset: UInt64, handle: FileHandle) -> Bool {
        guard offset > 0 else { return true }
        guard (try? handle.seek(toOffset: offset - 1)) != nil,
            let byte = try? handle.read(upToCount: 1), byte.first == 0x0A
        else { return false }
        return true
    }

    /** Timestamp of a mark record whose payload starts with `<id>\t`. */
    public static func markDate(current: URL, markID: String) -> Date? {
        let marks = run(current: current, options: LogQueryOptions(streams: [.mark]))
        return marks.first { $0.text.hasPrefix("\(markID)\t") || $0.text == markID }?.at
    }

    /** Binary search over byte-offset midpoints: seek, scan to the next line
        start, read that line's timestamp prefix. Returns the string index of the
        first line whose timestamp is at or after `since`. */
    static func firstLineIndex(atOrAfter since: Date, in text: String) -> String.Index {
        let utf8 = text.utf8
        var low = 0
        var high = utf8.count
        while low < high {
            let mid = (low + high) / 2
            let lineStart = lineStartOffset(atOrBefore: mid, utf8: utf8)
            guard let stamp = timestamp(atOffset: lineStart, in: text) else {
                /** Unparseable midpoint line: fall back to linear from here. */
                high = lineStart
                if high <= low { break }
                continue
            }
            if stamp < since {
                let next = nextLineOffset(after: lineStart, utf8: utf8)
                if next == lineStart { break }
                low = next
            } else {
                high = lineStart
            }
        }
        let offset = lineStartOffset(atOrBefore: min(low, utf8.count), utf8: utf8)
        return text.utf8.index(text.utf8.startIndex, offsetBy: offset)
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

    private static func lineStartOffset(atOrBefore offset: Int, utf8: String.UTF8View) -> Int {
        guard offset > 0 else { return 0 }
        var index = utf8.index(utf8.startIndex, offsetBy: min(offset, utf8.count))
        while index > utf8.startIndex {
            let previous = utf8.index(before: index)
            if utf8[previous] == 0x0A {
                return utf8.distance(from: utf8.startIndex, to: index)
            }
            index = previous
        }
        return 0
    }

    private static func nextLineOffset(after offset: Int, utf8: String.UTF8View) -> Int {
        var index = utf8.index(utf8.startIndex, offsetBy: min(offset, utf8.count))
        while index < utf8.endIndex {
            let current = utf8[index]
            index = utf8.index(after: index)
            if current == 0x0A {
                return utf8.distance(from: utf8.startIndex, to: index)
            }
        }
        return utf8.distance(from: utf8.startIndex, to: utf8.endIndex)
    }

    private static func timestamp(atOffset offset: Int, in text: String) -> Date? {
        let start = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
        guard let lineEnd = text[start...].firstIndex(of: "\n") else {
            return LogRecord.timestampPrefix(of: text[start...])
        }
        return LogRecord.timestampPrefix(of: text[start..<lineEnd])
    }
}
