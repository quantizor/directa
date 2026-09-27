import DirectaTestSupport
import Foundation
import Testing
import os

@testable import DirectaKit

@Suite struct LogFormatTests {
    @Test func recordRoundTrip() {
        let record = LogRecord(
            at: Date(timeIntervalSince1970: 1_752_868_000.5), stream: .out, text: "hello\tworld")
        let line = record.formatted()
        let parsed = LogRecord.parse(line[...])
        /** Payload tabs survive: parsers split on the first two tabs only. */
        #expect(parsed == record)
    }

    @Test func unparseableLinesReturnNil() {
        #expect(LogRecord.parse("no tabs here") == nil)
        #expect(LogRecord.parse("2026-01-01T00:00:00.000Z\tbogus\ttext") == nil)
        #expect(LogRecord.parse("not-a-date\tout\ttext") == nil)
    }

    @Test func contextLineTagsStream() {
        let record = LogRecord(at: Date(timeIntervalSince1970: 1), stream: .err, text: "boom")
        #expect(record.contextLine == "err: boom")
        let out = LogRecord(at: Date(timeIntervalSince1970: 1), stream: .out, text: "listening")
        #expect(out.contextLine == "out: listening")
    }

    @Test func sanitizerStripsSpinnersAnsiAndNul() {
        #expect(LogSanitizer.sanitize("10%\r50%\r100% done") == "100% done")
        #expect(LogSanitizer.sanitize("\u{1B}[31mred\u{1B}[0m plain") == "red plain")
        #expect(LogSanitizer.sanitize("\u{1B}]0;title\u{7}after") == "after")
        #expect(LogSanitizer.sanitize("nul\u{0}led") == "nulled")
    }
}

@Suite(.temporaryTree) struct LogQueryTests {
    private func writeFamily(_ linesPerFile: [[LogRecord]]) throws -> URL {
        let dir = try TemporaryTree.directory(named: "logq")
        let current = dir.appending(path: "current.log")
        /** linesPerFile oldest-first: earlier arrays land in higher rotations. */
        for (index, records) in linesPerFile.enumerated() {
            let isCurrent = index == linesPerFile.count - 1
            let url = isCurrent
                ? current
                : current.appendingPathExtension("\(linesPerFile.count - 1 - index)")
            let text = records.map { $0.formatted() }.joined(separator: "\n") + "\n"
            try Data(text.utf8).write(to: url)
        }
        return current
    }

    private func record(_ offset: TimeInterval, _ stream: LogStream, _ text: String) -> LogRecord {
        LogRecord(at: Date(timeIntervalSince1970: 1_700_000_000 + offset), stream: stream, text: text)
    }

    @Test func sinceSkipsWholeFilesAndBinarySearches() throws {
        let old = (0..<100).map { record(Double($0), .out, "old \($0)") }
        let recent = (100..<200).map { record(Double($0), .out, "recent \($0)") }
        let current = try writeFamily([old, recent])
        let results = LogQuery.run(
            current: current,
            options: LogQueryOptions(since: Date(timeIntervalSince1970: 1_700_000_150)))
        #expect(results.count == 50)
        #expect(results.first?.text == "recent 150")
        #expect(results.last?.text == "recent 199")
    }

    @Test func grepStreamsAndTailCompose() throws {
        let lines = [
            record(1, .out, "listening on 3000"),
            record(2, .err, "warning: deprecated"),
            record(3, .err, "error: boom"),
            record(4, .out, "ok"),
            record(5, .err, "error: bang"),
        ]
        let current = try writeFamily([lines])
        let errors = LogQuery.run(
            current: current,
            options: LogQueryOptions(grep: "error", streams: [.err], tail: 1))
        #expect(errors.map(\.text) == ["error: bang"])
    }

    @Test func markResolution() throws {
        let lines = [
            record(1, .out, "before"),
            record(2, .mark, "m1700-1\tpid-99\tcheckout test begins"),
            record(3, .out, "after"),
        ]
        let current = try writeFamily([lines])
        let markDate = LogQuery.markDate(current: current, markID: "m1700-1")
        #expect(markDate == Date(timeIntervalSince1970: 1_700_000_002))
        #expect(LogQuery.markDate(current: current, markID: "m-nope") == nil)
    }

    @Test func invalidGrepIsRejectedNotIgnored() throws {
        /** An unbalanced group cannot compile; the old `try? Regex` turned it into
            "no filter" and returned every line, which reads exactly like a query
            that matched everything. Fail closed instead. */
        #expect(LogQuery.grepRejection("(unbalanced") != nil)
        #expect(LogQuery.grepRejection("error|warn") == nil)
        let lines = [record(1, .err, "error: boom"), record(2, .out, "fine")]
        let current = try writeFamily([lines])
        #expect(LogQuery.run(current: current, options: LogQueryOptions(grep: "(unbalanced")).isEmpty)
    }

    @Test func catastrophicBacktrackingPatternsAreRejected() throws {
        /** Swift's Regex backtracks, so a group that repeats a group that itself
            repeats runs for seconds on a short line and never returns on a long
            one, wedging the log actor. These compile, so only the ReDoS screen
            stops them. Each is refused before it ever runs. */
        for pattern in ["^(a+)+$", "(a*)*", "(.*)+", "(a+)*$", "(\\d+)+", "(ab+)+"] {
            #expect(LogQuery.grepRejection(pattern) != nil, "expected \(pattern) rejected")
            #expect(LogQuery.nestsUnboundedQuantifier(pattern), "expected \(pattern) flagged")
        }
    }

    @Test func safePatternsAreNotRejectedByTheReDoSScreen() throws {
        /** Common log-grep shapes carry no nested unbounded repeat and must keep
            working: a top-level quantifier, disjoint alternation, a character
            class, a bounded outer repeat, and a plain literal. */
        for pattern in [
            "error.*failed", "(foo|bar)+", "[a-z]+", "(a+){2}", "(a+)?", "\\bwarn\\b",
            "GET /api/\\d+", "timeout|refused",
        ] {
            #expect(!LogQuery.nestsUnboundedQuantifier(pattern), "expected \(pattern) allowed")
            #expect(LogQuery.grepRejection(pattern) == nil, "expected \(pattern) accepted")
        }
    }

    @Test func summarizeCountsAndBracketsErrorStream() throws {
        let lines = [
            record(1, .out, "listening"),
            record(2, .err, "error one"),
            record(5, .err, "error two"),
            record(9, .err, "error three"),
        ]
        let current = try writeFamily([lines])
        let summary = LogQuery.summarize(current: current, streams: [.err], since: nil)
        #expect(summary == ErrorSummary(
            count: 3,
            firstAt: Date(timeIntervalSince1970: 1_700_000_002),
            lastAt: Date(timeIntervalSince1970: 1_700_000_009)))
    }

    @Test func summarizeIsNilOnEmptyWindow() throws {
        let lines = [record(1, .out, "listening"), record(2, .out, "ready")]
        let current = try writeFamily([lines])
        #expect(LogQuery.summarize(current: current, streams: [.err], since: nil) == nil)
        /** A since past every err line is also empty, not a spurious zero-count. */
        let withErr = try writeFamily([[record(1, .err, "old error")]])
        #expect(LogQuery.summarize(
            current: withErr, streams: [.err], since: Date(timeIntervalSince1970: 1_700_000_100)) == nil)
    }

    @Test func summarizeAnchorsSinceAcrossRotation() throws {
        let old = (0..<50).map { record(Double($0), .err, "old \($0)") }
        let recent = (50..<60).map { record(Double($0), .err, "recent \($0)") }
        let current = try writeFamily([old, recent])
        let summary = LogQuery.summarize(
            current: current, streams: [.err], since: Date(timeIntervalSince1970: 1_700_000_050))
        #expect(summary?.count == 10)
        #expect(summary?.firstAt == Date(timeIntervalSince1970: 1_700_000_050))
        #expect(summary?.lastAt == Date(timeIntervalSince1970: 1_700_000_059))
    }

    @Test func aCapSizedFamilyStillAnswersTailSinceAndGrep() throws {
        /** 30k lines across one rotate is still under the 10 MB file cap, but
            two orders past the 200-line queries this suite used. Whole-file
            parse, `since` skip of the rotated file, tail-after-filter, and a
            literal grep all have to stay correct and bounded; unbounded work
            here is the log actor wedging on a real noisy server. The bound is
            the bytes each query reads, never elapsed time, which a loaded
            machine stretches whether or not the code is correct: a tail reads
            a window off the end, a `since` query reads its search probes and
            the lines from its searched start (so less than current.log alone),
            and grep reads each byte once. */
        func stream(for offset: Int) -> LogStream { offset % 500 == 0 ? .err : .out }
        let rotated = (0..<10_000).map {
            record(Double($0), stream(for: $0), "old \($0)")
        }
        var recent = (10_000..<30_000).map {
            record(Double($0), stream(for: $0), "new \($0)")
        }
        recent[5_000] = record(15_000, .out, "NEEDLE-MID")
        let current = try writeFamily([rotated, recent])
        let currentBytes = recent.map { $0.formatted().utf8.count + 1 }.reduce(0, +)
        let familyBytes = rotated.map { $0.formatted().utf8.count + 1 }.reduce(currentBytes, +)
        func measured<Result>(_ query: (@escaping @Sendable (Int) -> Void) -> Result) -> (Result, Int) {
            let read = OSAllocatedUnfairLock<Int>(initialState: 0)
            let result = query { bytes in read.withLock { $0 += bytes } }
            return (result, read.withLock { $0 })
        }

        let (tail, tailBytes) = measured {
            LogQuery.runMeasured(current: current, options: LogQueryOptions(tail: 5), onDiskRead: $0)
        }
        #expect(tail.map(\.text) == ["new 29995", "new 29996", "new 29997", "new 29998", "new 29999"])
        #expect(tailBytes < 256 * 1024)

        let since = Date(timeIntervalSince1970: 1_700_000_000 + 25_000)
        let (window, windowRead) = measured {
            LogQuery.runMeasured(current: current, options: LogQueryOptions(since: since), onDiskRead: $0)
        }
        #expect(window.count == 5_000)
        #expect(window.first?.text == "new 25000")
        #expect(window.last?.text == "new 29999")
        /** The window starts inside current.log, so its search and scan never
            open the rotated file and never read current.log whole. */
        #expect(windowRead < currentBytes)

        let (hits, grepRead) = measured {
            LogQuery.runMeasured(current: current, options: LogQueryOptions(grep: "NEEDLE-MID"), onDiskRead: $0)
        }
        #expect(hits.map(\.text) == ["NEEDLE-MID"])
        #expect(grepRead < familyBytes + 64 * 1024)

        let (summary, summaryRead) = measured {
            LogQuery.summarizeMeasured(current: current, streams: [.err], since: since, onDiskRead: $0)
        }
        #expect(summary?.count == 10)
        #expect(summaryRead < currentBytes)
    }

    @Test func tailCrossesARotationBoundary() throws {
        /** The newest file alone does not cover the tail window, so the reader
            must fall back to the end of the older file for the remainder:
            `directa logs <name> --tail 5` against 4 lines in current.log needs
            one more line, which sits at the end of current.log.1. */
        let old = (0..<5).map { record(Double($0), .out, "old \($0)") }
        let recent = (5..<9).map { record(Double($0), .out, "new \($0)") }
        let current = try writeFamily([old, recent])
        let tail = LogQuery.run(current: current, options: LogQueryOptions(tail: 5))
        #expect(tail.map(\.text) == ["old 4", "new 5", "new 6", "new 7", "new 8"])
    }

    @Test func tailIgnoresATrailingPartialLine() throws {
        /** A line with no trailing newline (a crash mid-write, or a read
            racing an in-flight append) must not surface as a phantom record:
            LogRecord.parse rejects it for lacking a full timestamp/stream/
            payload shape, the same as the full-parse path already does. */
        let dir = try TemporaryTree.directory(named: "logq")
        let current = dir.appending(path: "current.log")
        let complete = (0..<3).map { record(Double($0), .out, "line \($0)") }
        let text = complete.map { $0.formatted() }.joined(separator: "\n")
            + "\n2026-01-01T00:00:00.00partial-garbage-no-tabs"
        try Data(text.utf8).write(to: current)
        let tail = LogQuery.run(current: current, options: LogQueryOptions(tail: 5))
        #expect(tail.map(\.text) == ["line 0", "line 1", "line 2"])
    }

    @Test func tailLargerThanTheWholeFamilyReturnsEverything() throws {
        let old = [record(0, .out, "old 0"), record(1, .out, "old 1")]
        let recent = [record(2, .out, "new 0")]
        let current = try writeFamily([old, recent])
        let tail = LogQuery.run(current: current, options: LogQueryOptions(tail: 100))
        #expect(tail.map(\.text) == ["old 0", "old 1", "new 0"])
    }

    @Test func tailAfterStreamsFilterMatchesFilterThenSuffix() throws {
        /** Spec for `tail` combined with `streams`: filter first, then keep
            the last `n` of what remains, in original chronological order.
            The expected value is computed independently of LogQuery (filter
            + suffix on the fixture records this test built), so it pins the
            documented behavior rather than whatever the code happens to do. */
        func stream(for offset: Int) -> LogStream { offset % 7 == 0 ? .err : .out }
        let old = (0..<40).map { record(Double($0), stream(for: $0), "old \($0)") }
        let recent = (40..<70).map { record(Double($0), stream(for: $0), "new \($0)") }
        let current = try writeFamily([old, recent])
        let all = old + recent
        for tailSize in [1, 3, 10, 25] {
            let expected = all.filter { $0.stream == .err }.suffix(tailSize)
            let got = LogQuery.run(
                current: current, options: LogQueryOptions(streams: [.err], tail: tailSize))
            #expect(got.map(\.text) == expected.map(\.text), "tail \(tailSize)")
        }
    }

    @Test func tailOnlyStaysFastOnAFarLargerFamilyThanRequested() throws {
        /** 150k lines across a rotation, asking for the last 50: the fast
            path reads a handful of kilobytes off the end of current.log alone,
            never touching the 100k-line rotated file. A wall-clock budget here
            flakes under a loaded machine even when the code is correct, so the
            proof is the actual byte count `runMeasured` reports rather than
            elapsed time: bounded regardless of family size when the fast path
            runs, and blown past by two orders of magnitude the moment it is
            disabled (see `red/green` note below), since the whole 150k-line,
            2-file family would then be read to answer a tail of 50. */
        let old = (0..<100_000).map { record(Double($0), .out, "old \($0)") }
        let recent = (100_000..<150_000).map { record(Double($0), .out, "new \($0)") }
        let current = try writeFamily([old, recent])
        let bytesRead = OSAllocatedUnfairLock<Int>(initialState: 0)
        let tail = LogQuery.runMeasured(
            current: current, options: LogQueryOptions(tail: 50),
            onDiskRead: { bytes in bytesRead.withLock { $0 += bytes } })
        #expect(tail.map(\.text) == (149_950..<150_000).map { "new \($0)" })
        /** The fast path satisfies 50 short lines from its first 64 KB window
            off the end of current.log alone; 256 KB leaves headroom for a
            window doubling or two while staying two orders of magnitude under
            the several-MB size of the full family a regression would read. */
        #expect(bytesRead.withLock { $0 } < 256 * 1024)
    }

    private func stamped(_ ms: Int, _ stream: LogStream, _ text: String) -> LogRecord {
        LogRecord(at: Date(timeIntervalSince1970: 1_700_000_000 + Double(ms) / 1000), stream: stream, text: text)
    }

    private func append(_ records: [LogRecord], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((records.map { $0.formatted() + "\n" }.joined()).utf8))
    }

    @Test func afterSkipsExactlyCountRecordsAtTheCursorMillisecondAcrossStreams() throws {
        let lines = [
            stamped(1, .out, "a"), stamped(5, .out, "b"), stamped(5, .err, "c"), stamped(5, .sys, "d"),
            stamped(5, .out, "e"), stamped(6, .out, "f"),
        ]
        let current = try writeFamily([lines])
        let cursor = LogCursor(at: stamped(5, .out, "").at, count: 2)
        let all = LogQuery.window(current: current, options: LogQueryOptions(after: cursor))
        #expect(all.lines.map(\.text) == ["d", "e", "f"])
        /** The skipped records count every stream, so a stream filter does
            not change which records lie behind the cursor. */
        let outOnly = LogQuery.window(current: current, options: LogQueryOptions(after: cursor, streams: [.out]))
        #expect(outOnly.lines.map(\.text) == ["e", "f"])
    }

    @Test func recordsAppendedAtTheCursorMillisecondAfterItWasIssuedAreReturned() throws {
        let current = try writeFamily([[stamped(1, .out, "a"), stamped(2, .out, "b"), stamped(2, .err, "c")]])
        let first = LogQuery.window(current: current, options: LogQueryOptions(tail: 10))
        #expect(first.cursor == LogCursor(at: stamped(2, .out, "").at, count: 2))
        try append([stamped(2, .sys, "d"), stamped(2, .out, "e"), stamped(3, .out, "f")], to: current)
        let next = LogQuery.window(current: current, options: LogQueryOptions(after: first.cursor))
        #expect(next.lines.map(\.text) == ["d", "e", "f"])
        #expect(next.cursor == LogCursor(at: stamped(3, .out, "").at, count: 1))
    }

    @Test func theCursorIsReturnedWhenNothingMatches() throws {
        let current = try writeFamily([[stamped(1, .out, "a"), stamped(4, .err, "b"), stamped(4, .out, "c")]])
        let window = LogQuery.window(current: current, options: LogQueryOptions(grep: "nothing-matches"))
        #expect(window.lines.isEmpty)
        #expect(window.cursor == LogCursor(at: stamped(4, .out, "").at, count: 2))
        let caughtUp = LogQuery.window(current: current, options: LogQueryOptions(after: window.cursor))
        #expect(caughtUp.lines.isEmpty)
        #expect(caughtUp.cursor == window.cursor)
        #expect(caughtUp.totals == LogStreamCounts(err: 0, mark: 0, out: 0, sys: 0))
    }

    @Test func anEmptyFamilyAnswersTheOriginCursor() throws {
        let dir = try TemporaryTree.path(named: "logq")
        let window = LogQuery.window(current: dir.appending(path: "current.log"), options: LogQueryOptions())
        #expect(window == LogWindow(cursor: .origin, lines: []))
        /** The origin lies before every record, so the first query after it
            returns everything a later append writes. */
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let current = dir.appending(path: "current.log")
        try Data((stamped(0, .out, "first").formatted() + "\n").utf8).write(to: current)
        #expect(
            LogQuery.window(current: current, options: LogQueryOptions(after: .origin)).lines.map(\.text)
                == ["first"])
    }

    @Test func aCursorMillisecondStraddlingARotationCountsBothFiles() throws {
        let current = try writeFamily([
            [stamped(1, .out, "a"), stamped(7, .out, "b"), stamped(7, .out, "c")],
            [stamped(7, .sys, "rotated"), stamped(7, .out, "d")],
        ])
        let window = LogQuery.window(current: current, options: LogQueryOptions(tail: 1))
        #expect(window.cursor == LogCursor(at: stamped(7, .out, "").at, count: 4))
        let resumed = LogQuery.window(
            current: current, options: LogQueryOptions(after: LogCursor(at: stamped(7, .out, "").at, count: 3)))
        #expect(resumed.lines.map(\.text) == ["d"])
    }

    /** Sixty-plus records in one millisecond (one spool chunk) read in
        pieces: every tick reads past the previous cursor, and together the
        ticks return each record exactly once. */
    @Test func aMillisecondBurstSplitAcrossQueriesLosesAndRepeatsNothing() throws {
        let current = try writeFamily([[stamped(0, .sys, "started pid=1")]])
        var cursor = LogQuery.window(current: current, options: LogQueryOptions(tail: 0)).cursor
        var seen: [String] = []
        let bursts = [(0..<25), (25..<61), (61..<64)]
        for (index, burst) in bursts.enumerated() {
            try append(burst.map { stamped(9, .out, "line \($0)") }, to: current)
            let window = LogQuery.window(
                current: current,
                options: LogQueryOptions(after: cursor, tailByStream: LogStreamCounts(err: 300, out: 300)))
            seen += window.lines.map(\.text)
            #expect(window.totals?.out == burst.count, "tick \(index)")
            cursor = window.cursor
        }
        #expect(seen == (0..<64).map { "line \($0)" })
        #expect(cursor == LogCursor(at: stamped(9, .out, "").at, count: 64))
    }

    @Test func tailByStreamKeepsSysLinesInsideAnOutBurst() throws {
        var lines = (0..<500).map { stamped($0, .out, "out \($0)") }
        lines.insert(stamped(100, .sys, "exited code=1"), at: 101)
        lines.insert(stamped(200, .sys, "started pid=9"), at: 202)
        let current = try writeFamily([lines])
        let window = LogQuery.window(
            current: current,
            options: LogQueryOptions(tailByStream: LogStreamCounts(err: 5, mark: 5, out: 3, sys: 5)))
        #expect(window.lines.map(\.text) == ["exited code=1", "started pid=9", "out 497", "out 498", "out 499"])
        #expect(window.totals == LogStreamCounts(err: 0, mark: 0, out: 500, sys: 2))
        let plainTail = LogQuery.run(current: current, options: LogQueryOptions(tail: 5))
        #expect(!plainTail.contains { $0.stream == .sys })
    }

    @Test func tailByStreamHonorsEachStreamsOwnValue() throws {
        let lines = [
            stamped(1, .err, "e1"), stamped(2, .out, "o1"), stamped(3, .mark, "m1"), stamped(4, .sys, "s1"),
            stamped(5, .err, "e2"), stamped(6, .out, "o2"), stamped(7, .sys, "s2"), stamped(8, .out, "o3"),
            stamped(9, .err, "e3"),
        ]
        let current = try writeFamily([lines])
        /** err keeps its newest one, out its newest two, mark is excluded by
            0, and sys (nil) is untrimmed. */
        let window = LogQuery.window(
            current: current,
            options: LogQueryOptions(tailByStream: LogStreamCounts(err: 1, mark: 0, out: 2, sys: nil)))
        #expect(window.lines.map(\.text) == ["s1", "o2", "s2", "o3", "e3"])
        #expect(window.totals == LogStreamCounts(err: 3, mark: 1, out: 3, sys: 2))
    }

    @Test func headKeepsTheOldestMatches() throws {
        let lines = (0..<20).map { stamped($0, $0 % 2 == 0 ? .out : .err, "line \($0)") }
        let current = try writeFamily([Array(lines[..<10]), Array(lines[10...])])
        let window = LogQuery.window(
            current: current, options: LogQueryOptions(head: 3, since: stamped(5, .out, "").at, streams: [.err]))
        #expect(window.lines.map(\.text) == ["line 5", "line 7", "line 9"])
        #expect(window.totals == nil)
        #expect(LogQuery.window(current: current, options: LogQueryOptions(head: 0)).lines.isEmpty)
        /** Past a cursor, a head still counts the whole window. */
        let afterCursor = LogQuery.window(
            current: current, options: LogQueryOptions(after: LogCursor(at: stamped(4, .out, "").at, count: 1), head: 2))
        #expect(afterCursor.lines.map(\.text) == ["line 5", "line 6"])
        #expect(afterCursor.totals == LogStreamCounts(err: 8, mark: 0, out: 7, sys: 0))
    }

    /** A head with no cursor stops reading once it holds its lines: the
        read-what-was-skipped shape (`--since <ts> --head 200`) near the
        start of a multi-megabyte family reads a few chunks, not the rest of
        the family. */
    @Test func aHeadStopsReadingOnceItHoldsItsLines() throws {
        let files = (0..<3).map { file in
            (0..<8_000).map { index in
                stamped(file * 8_000 + index, .out, "GET /api/items/\(file * 8_000 + index) 200 12ms padding-padding")
            }
        }
        let current = try writeFamily(files)
        let familyBytes = try LogQuery.familyFiles(current: current)
            .map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int ?? 0 }
            .reduce(0, +)
        let bytesRead = OSAllocatedUnfairLock<Int>(initialState: 0)
        let window = LogQuery.windowMeasured(
            current: current, options: LogQueryOptions(head: 200, since: stamped(100, .out, "").at),
            onDiskRead: { bytes in bytesRead.withLock { $0 += bytes } })
        #expect(window.lines.map(\.text) == (100..<300).map { "GET /api/items/\($0) 200 12ms padding-padding" })
        #expect(window.totals == nil)
        #expect(familyBytes > 1536 * 1024)
        /** One 256 KB scan chunk plus the binary search, the read-back, and
            the end cursor: a third of a family over 1.5 MB. */
        #expect(bytesRead.withLock { $0 } < 512 * 1024)
    }

    /** `tail: 0` is how `directa monitor` attaches: the tail fast path
        answers the family's end cursor from the last bytes of current.log,
        while the same zero trim spelled per stream scans the whole family
        forward to count totals. */
    @Test func aZeroTailAnswersTheEndCursorFromTheEndOfTheFamily() throws {
        let files = (0..<3).map { file in
            (0..<5_000).map { index in stamped(file * 5_000 + index, .out, "line \(file * 5_000 + index) padding") }
        }
        let current = try writeFamily(files)
        let familyBytes = try LogQuery.familyFiles(current: current)
            .map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int ?? 0 }
            .reduce(0, +)
        #expect(familyBytes > 512 * 1024)
        let tailRead = OSAllocatedUnfairLock<Int>(initialState: 0)
        let tail = LogQuery.windowMeasured(
            current: current, options: LogQueryOptions(tail: 0),
            onDiskRead: { bytes in tailRead.withLock { $0 += bytes } })
        #expect(tail == LogWindow(cursor: LogCursor(at: stamped(14_999, .out, "").at, count: 1), lines: []))
        /** One 64 KB window off the end of current.log (plus the byte
            before it, to tell a clean line start): the other two files are
            never opened. */
        #expect(tailRead.withLock { $0 } < 128 * 1024)

        let perStreamRead = OSAllocatedUnfairLock<Int>(initialState: 0)
        let perStream = LogQuery.windowMeasured(
            current: current, options: LogQueryOptions(tailByStream: LogStreamCounts(err: 0, mark: 0, out: 0, sys: 0)),
            onDiskRead: { bytes in perStreamRead.withLock { $0 += bytes } })
        #expect(perStream.cursor == tail.cursor)
        #expect(perStreamRead.withLock { $0 } >= familyBytes)
    }

    @Test func maxLineCharactersCutsEachTextWithAnEllipsis() throws {
        let lines = [
            stamped(1, .out, "abcdef"), stamped(2, .out, "abcd"), stamped(3, .out, "👩‍👩‍👧‍👦 family emoji"),
            stamped(4, .out, ""),
        ]
        let current = try writeFamily([lines])
        let four = LogQuery.window(current: current, options: LogQueryOptions(maxLineCharacters: 4, tail: 10))
        #expect(four.lines.map(\.text) == ["abc…", "abcd", "👩‍👩‍👧‍👦 f…", ""])
        let one = LogQuery.window(
            current: current, options: LogQueryOptions(after: .origin, maxLineCharacters: 1))
        #expect(one.lines.map(\.text) == ["…", "…", "…", ""])
    }

    @Test func totalsAreAbsentForTheShapesThatPredateThem() throws {
        let current = try writeFamily([[stamped(1, .out, "a"), stamped(2, .err, "b")]])
        for options in [
            LogQueryOptions(), LogQueryOptions(tail: 1), LogQueryOptions(since: stamped(0, .out, "").at),
            LogQueryOptions(grep: "a"), LogQueryOptions(head: 1),
        ] {
            let window = LogQuery.window(current: current, options: options)
            #expect(window.totals == nil)
            #expect(window.cursor == LogCursor(at: stamped(2, .out, "").at, count: 1))
        }
    }

    /** A sub-millisecond `since` (the CLI's `5m` form) keeps the old
        `record.at < since` exclusion exactly: a record in the same
        millisecond but before the instant is excluded. */
    @Test func aSubMillisecondSinceExcludesTheEarlierPartOfItsMillisecond() throws {
        let current = try writeFamily([[stamped(1, .out, "a"), stamped(2, .out, "b"), stamped(3, .out, "c")]])
        let since = stamped(2, .out, "").at.addingTimeInterval(0.0004)
        #expect(LogQuery.run(current: current, options: LogQueryOptions(since: since)).map(\.text) == ["c"])
        let exact = stamped(2, .out, "").at
        #expect(LogQuery.run(current: current, options: LogQueryOptions(since: exact)).map(\.text) == ["b", "c"])
    }

    @Test func theDigitParserAgreesWithTheISO8601Parser() throws {
        let samples = [
            "2024-02-29T23:59:59.999Z", "2025-12-31T00:00:00.000Z", "1970-01-01T00:00:00.001Z",
            "2100-03-01T12:34:56.789Z", "2026-09-26T05:30:40.118Z", "2026-01-01T00:00:00Z",
        ]
        for sample in samples {
            let parsed = try #require(JSONCoding.parseISO8601(sample))
            let bytes = Array(sample.utf8)
            let ms = bytes.withUnsafeBufferPointer { LogScan.epochMilliseconds($0) }
            #expect(ms == LogScan.milliseconds(of: parsed), "\(sample)")
            #expect(ms.map(LogScan.date(milliseconds:)) == parsed, "\(sample)")
        }
        for invalid in ["2025-02-29T00:00:00.000Z", "2025-13-01T00:00:00.000Z", "not a timestamp at all!"] {
            let bytes = Array(invalid.utf8)
            #expect(
                bytes.withUnsafeBufferPointer { LogScan.epochMilliseconds($0) }
                    == JSONCoding.parseISO8601(invalid).map(LogScan.milliseconds(of:)), "\(invalid)")
        }
    }

    /** Memory tracks the answer, not the window: over a multi-megabyte
        family the scan reads in bounded chunks and reads back only what it
        keeps, so no single read approaches a file's size and the total read
        stays near one pass over the family. */
    @Test func aLargeWindowIsStreamedInBoundedReads() throws {
        let files = (0..<3).map { file in
            (0..<16_000).map { index in
                let ms = file * 16_000 + index
                return stamped(
                    ms / 20, ms % 50 == 0 ? .err : .out,
                    "GET /api/items/\(ms) 200 12ms padding-padding-padding-padding")
            }
        }
        let current = try writeFamily(files)
        let familyBytes = try LogQuery.familyFiles(current: current)
            .map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int ?? 0 }
            .reduce(0, +)
        let reads = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let window = LogQuery.windowMeasured(
            current: current,
            options: LogQueryOptions(after: .origin, tailByStream: LogStreamCounts(err: 300, out: 300)),
            onDiskRead: { bytes in reads.withLock { $0.append(bytes) } })
        #expect(window.lines.count == 600)
        #expect(window.totals == LogStreamCounts(err: 960, mark: 0, out: 47_040, sys: 0))
        let observed = reads.withLock { $0 }
        #expect(familyBytes > 3 * 1024 * 1024)
        #expect((observed.max() ?? 0) <= 1024 * 1024)
        #expect(observed.reduce(0, +) < familyBytes + familyBytes / 4)
    }

    /** Differential check against a naive reading of the spec: parse every
        record, apply the lower bound, filters, trim, and truncation in
        order, and derive the cursor from the last record. Seeded, so a
        failure reproduces. */
    @Test func randomQueriesMatchANaiveModelOfTheSpec() throws {
        var random = SplitMix64(seed: 0x5EED)
        for iteration in 0..<250 {
            var ms = 0
            let fileCount = Int(random.next() % 3) + 1
            var family: [[LogRecord]] = []
            var sequence = 0
            for _ in 0..<fileCount {
                /** A file always holds at least one record, as a rotation
                    writes `rotated` into the fresh file. */
                let count = Int(random.next() % 40) + 1
                family.append(
                    (0..<count).map { _ in
                        ms += Int(random.next() % 3) == 0 ? 1 : 0
                        sequence += 1
                        let stream = LogStream.allCases[Int(random.next() % 4)]
                        let text = random.next() % 4 == 0 ? "needle \(sequence) long text" : "hay \(sequence)"
                        return stamped(ms, stream, text)
                    })
            }
            let current = try writeFamily(family)
            defer { try? FileManager.default.removeItem(at: current.deletingLastPathComponent()) }
            let records = family.flatMap { $0 }
            var options = LogQueryOptions()
            switch random.next() % 3 {
            case 0:
                options.after = LogCursor(
                    at: stamped(Int(random.next() % UInt64(ms + 2)), .out, "").at, count: Int(random.next() % 5))
            case 1:
                options.since = stamped(Int(random.next() % UInt64(ms + 2)), .out, "").at
                    .addingTimeInterval(random.next() % 2 == 0 ? 0 : 0.0004)
            default:
                break
            }
            if random.next() % 3 == 0 { options.streams = [.out, .sys] }
            if random.next() % 4 == 0 { options.grep = "needle" }
            switch random.next() % 4 {
            case 0: options.tail = Int(random.next() % 10)
            case 1: options.head = Int(random.next() % 10)
            case 2:
                options.tailByStream = LogStreamCounts(
                    err: Int(random.next() % 4), mark: nil, out: Int(random.next() % 6), sys: 0)
            default: break
            }
            if random.next() % 3 == 0 { options.maxLineCharacters = Int(random.next() % 8) + 1 }
            let got = LogQuery.window(current: current, options: options)
            #expect(got == naiveWindow(records, options), "iteration \(iteration)")
        }
    }

    /** The backward walk hands back exactly the lines a forward split
        finds, newest first with the same offsets, at every chunk size down
        to one byte: a line or a multi-byte character cut by a chunk edge is
        reassembled, empty lines are skipped, and an unterminated last line
        counts. */
    @Test func aBackwardWalkMatchesAForwardSplitAtEveryChunkSize() throws {
        let dir = try TemporaryTree.directory(named: "logq")
        let url = dir.appending(path: "current.log")
        let bytes = Array("first é line\n\nsecond 👩‍👩‍👧‍👦 line\nü\n\n\nthird, unterminated ☃".utf8)
        try Data(bytes).write(to: url)
        var expected: [(String, Int)] = []
        var start = 0
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            if index > start { expected.append((String(decoding: bytes[start..<index], as: UTF8.self), start)) }
            start = index + 1
        }
        expected.append((String(decoding: bytes[start...], as: UTF8.self), start))
        let reader = try #require(LogFileReader(url: url, onDiskRead: nil))
        for chunk in [1, 2, 3, 5, 7, 16, 64 * 1024] {
            var got: [(String, Int)] = []
            let finished = reader.forEachLineBackward(before: reader.size, chunkBytes: chunk) { line, offset in
                got.append((String(decoding: line, as: UTF8.self), offset))
                return true
            }
            #expect(finished, "chunk \(chunk)")
            #expect(got.reversed().map(\.0) == expected.map(\.0), "chunk \(chunk)")
            #expect(got.reversed().map(\.1) == expected.map(\.1), "chunk \(chunk)")
            var stoppedAfter: [String] = []
            let stopped = !reader.forEachLineBackward(before: reader.size, chunkBytes: chunk) { line, _ in
                stoppedAfter.append(String(decoding: line, as: UTF8.self))
                return stoppedAfter.count < 2
            }
            #expect(stopped, "chunk \(chunk)")
            #expect(stoppedAfter == ["third, unterminated ☃", "ü"], "chunk \(chunk)")
        }
    }

    /** A read that comes back short (the file shrank under an open reader,
        or an I/O error) ends the walk as stopped, never as a walk that
        reached the start of the file: a caller that reads "finished" moves
        on to an older file as if nothing newer were left. */
    @Test func aShortReadStopsTheBackwardWalk() throws {
        let dir = try TemporaryTree.directory(named: "logq")
        let url = dir.appending(path: "current.log")
        try Data("first\nsecond\nthird\n".utf8).write(to: url)
        let reader = try #require(LogFileReader(url: url, onDiskRead: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 9)
        try handle.close()
        for chunk in [4, 64 * 1024] {
            var got: [String] = []
            let finished = reader.forEachLineBackward(before: reader.size, chunkBytes: chunk) { line, _ in
                got.append(String(decoding: line, as: UTF8.self))
                return true
            }
            #expect(!finished, "chunk \(chunk)")
            #expect(got.isEmpty, "chunk \(chunk)")
        }
    }

    /** A tail whose stream filter thins the file out walks back past many
        chunk edges, some of them splitting a multi-byte character, and must
        answer exactly what parsing the whole file would, in reads no larger
        than one chunk. */
    @Test func aSparseStreamTailMatchesAWholeFileReadInChunkSizedReads() throws {
        var records: [LogRecord] = []
        for index in 0..<6_000 {
            let text = "req \(index) " + String(repeating: index % 3 == 0 ? "é" : "ü👍", count: index % 11) + " done"
            records.append(stamped(index / 4, index % 37 == 0 ? .err : .out, text))
        }
        let chunk = LogScan.backwardChunkBytes
        /** A last line of the right length puts a chunk edge, counted back
            from the end, inside a multi-byte character: the hard case. */
        func splitsACharacter(_ bytes: [UInt8]) -> Bool {
            stride(from: bytes.count - chunk, to: 0, by: -chunk).contains { bytes[$0] & 0xC0 == 0x80 }
        }
        var padding = 0
        var current = try writeFamily([records])
        while !splitsACharacter(try Array(Data(contentsOf: current))), padding < 16 {
            try? FileManager.default.removeItem(at: current.deletingLastPathComponent())
            padding += 1
            current = try writeFamily([records + [stamped(9_999, .out, String(repeating: "x", count: padding))]])
        }
        defer { try? FileManager.default.removeItem(at: current.deletingLastPathComponent()) }
        let bytes = try Array(Data(contentsOf: current))
        #expect(bytes.count > 4 * chunk)
        #expect(splitsACharacter(bytes))
        let wholeFile = String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).compactMap(LogRecord.parse)
        for (streams, tail) in [([LogStream.err], 1), ([.err], 50), ([.err], 10_000), ([.mark], 5), ([.out, .err], 7)] {
            let reads = OSAllocatedUnfairLock<[Int]>(initialState: [])
            let got = LogQuery.runMeasured(
                current: current, options: LogQueryOptions(streams: Set(streams), tail: tail),
                onDiskRead: { count in reads.withLock { $0.append(count) } })
            let expected = wholeFile.filter { streams.contains($0.stream) }.suffix(tail)
            #expect(got == Array(expected), "streams \(streams) tail \(tail)")
            #expect((reads.withLock { $0 }.max() ?? 0) <= chunk, "streams \(streams) tail \(tail)")
        }
    }

    /** A summary keeps two records, not every match: over a family where
        half the lines match, it reads the family once and reads back only
        the first and last match. */
    @Test func summarizeReadsTheFamilyOnceAndKeepsTwoRecords() throws {
        let files = (0..<2).map { file in
            (0..<8_000).map { index in
                stamped(file * 8_000 + index, index % 2 == 0 ? .err : .out, "line \(file * 8_000 + index) padding-padding")
            }
        }
        let current = try writeFamily(files)
        defer { try? FileManager.default.removeItem(at: current.deletingLastPathComponent()) }
        let familyBytes = try LogQuery.familyFiles(current: current)
            .map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int ?? 0 }
            .reduce(0, +)
        let read = OSAllocatedUnfairLock<Int>(initialState: 0)
        let summary = LogQuery.summarizeMeasured(
            current: current, streams: [.err], since: nil, onDiskRead: { count in read.withLock { $0 += count } })
        #expect(summary == ErrorSummary(count: 8_000, firstAt: stamped(0, .err, "").at, lastAt: stamped(15_998, .err, "").at))
        #expect(read.withLock { $0 } < familyBytes + 64 * 1024)
    }

    /** After a large backward clock step every record lands in one
        millisecond (the store clamps each append to the last one). A poller
        attached there must read only what arrived since its last poll, not
        the whole millisecond again. */
    @Test func aPollPastAClockStepMillisecondReadsOnlyWhatArrived() throws {
        let before = (0..<100).map { stamped($0, .out, "before \($0)") }
        let stuck = (0..<30_000).map { stamped(5_000, $0 % 50 == 0 ? .err : .out, "stuck \($0) padding-padding") }
        let current = try writeFamily([before + stuck])
        defer { try? FileManager.default.removeItem(at: current.deletingLastPathComponent()) }
        let groupBytes = stuck.map { $0.formatted().utf8.count + 1 }.reduce(0, +)
        #expect(groupBytes > 1024 * 1024)
        let inode = try #require(LogFileReader(url: current, onDiskRead: nil)).inode

        let attach = LogQuery.window(current: current, options: LogQueryOptions(tail: 0))
        let attachedSize = try #require(LogFileReader(url: current, onDiskRead: nil)).size
        #expect(
            attach.cursor
                == LogCursor(
                    at: stamped(5_000, .out, "").at, count: 30_000,
                    position: LogFilePosition(file: inode, offset: attachedSize - 1)))

        try append((0..<10).map { stamped(5_000, .out, "new \($0)") }, to: current)
        let newSize = try #require(LogFileReader(url: current, onDiskRead: nil)).size
        let pollOptions = { (cursor: LogCursor) in
            LogQueryOptions(after: cursor, tailByStream: LogStreamCounts(err: 300, out: 300))
        }
        let read = OSAllocatedUnfairLock<Int>(initialState: 0)
        let poll = LogQuery.windowMeasured(
            current: current, options: pollOptions(attach.cursor),
            onDiskRead: { count in read.withLock { $0 += count } })
        #expect(poll.lines.map(\.text) == (0..<10).map { "new \($0)" })
        #expect(poll.totals == LogStreamCounts(err: 0, mark: 0, out: 10, sys: 0))
        #expect(
            poll.cursor
                == LogCursor(
                    at: stamped(5_000, .out, "").at, count: 30_010,
                    position: LogFilePosition(file: inode, offset: newSize - 1)))
        /** A backward chunk, the scan chunk, and the position check: a small
            fraction of the millisecond it no longer rereads. */
        #expect(read.withLock { $0 } < 512 * 1024)

        let idleRead = OSAllocatedUnfairLock<Int>(initialState: 0)
        let idle = LogQuery.windowMeasured(
            current: current, options: pollOptions(poll.cursor),
            onDiskRead: { count in idleRead.withLock { $0 += count } })
        #expect(idle.lines.isEmpty)
        #expect(idle.cursor == poll.cursor)
        #expect(idleRead.withLock { $0 } < 512 * 1024)
    }

    /** A position names a file by inode, so it still resumes after the
        store renames current.log to current.log.1 and the millisecond goes
        on in a fresh current.log. */
    @Test func aPositionResumesAcrossARotation() throws {
        let current = try writeFamily([(0..<40).map { stamped(7, .out, "old \($0)") }])
        defer { try? FileManager.default.removeItem(at: current.deletingLastPathComponent()) }
        let attach = LogQuery.windowMeasured(
            current: current, options: LogQueryOptions(tail: 0), positionThreshold: 4, onDiskRead: nil)
        let rotatedInode = try #require(attach.cursor.position?.file)
        try FileManager.default.moveItem(at: current, to: current.appendingPathExtension("1"))
        try Data(([stamped(7, .sys, "rotated")] + (0..<3).map { stamped(7, .out, "new \($0)") })
            .map { $0.formatted() + "\n" }.joined().utf8).write(to: current)
        let poll = LogQuery.windowMeasured(
            current: current, options: LogQueryOptions(after: attach.cursor), positionThreshold: 4, onDiskRead: nil)
        #expect(poll.lines.map(\.text) == ["rotated", "new 0", "new 1", "new 2"])
        #expect(poll.cursor.count == 44)
        let newInode = try #require(LogFileReader(url: current, onDiskRead: nil)).inode
        #expect(newInode != rotatedInode)
        #expect(poll.cursor.position?.file == newInode)
    }

    /** A position that does not name a record ending there in this family,
        stamped with the cursor's millisecond, is ignored and the count
        applies: the answer is exactly the count-only cursor's. */
    @Test func anUnusablePositionFallsBackToTheCount() throws {
        let lines = [stamped(1, .out, "a"), stamped(5, .out, "b"), stamped(5, .err, "c"), stamped(5, .sys, "d"), stamped(6, .out, "e")]
        let current = try writeFamily([lines])
        defer { try? FileManager.default.removeItem(at: current.deletingLastPathComponent()) }
        let reader = try #require(LogFileReader(url: current, onDiskRead: nil))
        let lineEnds = lines.map { $0.formatted().utf8.count + 1 }.reduce(into: [Int]()) { ends, length in
            ends.append((ends.last ?? 0) + length)
        }.map { $0 - 1 }
        let plain = LogCursor(at: stamped(5, .out, "").at, count: 2)
        let expected = LogQuery.window(current: current, options: LogQueryOptions(after: plain))
        #expect(expected.lines.map(\.text) == ["d", "e"])
        let unusable = [
            LogFilePosition(file: reader.inode &+ 1, offset: lineEnds[2]),
            LogFilePosition(file: reader.inode, offset: lineEnds[2] - 1),
            LogFilePosition(file: reader.inode, offset: reader.size + 10),
            LogFilePosition(file: reader.inode, offset: lineEnds[0]),
            LogFilePosition(file: reader.inode, offset: 0),
            LogFilePosition(file: reader.inode, offset: -5),
        ]
        for position in unusable {
            let got = LogQuery.window(
                current: current, options: LogQueryOptions(after: LogCursor(at: plain.at, count: 2, position: position)))
            #expect(got == expected, "position \(position)")
        }
        /** The usable one resumes right after "c" regardless of the count. */
        let usable = LogQuery.window(
            current: current,
            options: LogQueryOptions(
                after: LogCursor(at: plain.at, count: 2, position: LogFilePosition(file: reader.inode, offset: lineEnds[2]))))
        #expect(usable.lines.map(\.text) == ["d", "e"])
    }

    /** Polling with every cursor positioned (a threshold of one) while
        records land in long same-millisecond runs and the family rotates:
        each poll returns exactly what arrived since the last, and each
        cursor's millisecond and count are what counting the family says. */
    @Test func positionedPollsAcrossAppendsAndRotationsLoseAndRepeatNothing() throws {
        var random = SplitMix64(seed: 0xC10C)
        let current = try writeFamily([[stamped(0, .sys, "started")]])
        defer { try? FileManager.default.removeItem(at: current.deletingLastPathComponent()) }
        var family: [[LogRecord]] = [[stamped(0, .sys, "started")]]
        var ms = 0
        var sequence = 0
        var cursor = LogQuery.windowMeasured(
            current: current, options: LogQueryOptions(tail: 0), positionThreshold: 1, onDiskRead: nil).cursor
        var seen: [String] = []
        var appended: [String] = []
        for round in 0..<60 {
            if random.next() % 7 == 0 {
                for index in stride(from: family.count - 1, through: 1, by: -1) {
                    let from = current.appendingPathExtension("\(index)")
                    try FileManager.default.moveItem(at: from, to: current.appendingPathExtension("\(index + 1)"))
                }
                try FileManager.default.moveItem(at: current, to: current.appendingPathExtension("1"))
                FileManager.default.createFile(atPath: current.path, contents: nil)
                family.append([])
            }
            let batch = (0..<Int(random.next() % 30)).map { _ in
                if random.next() % 10 == 0 { ms += 1 }
                sequence += 1
                return stamped(ms, LogStream.allCases[Int(random.next() % 4)], "r\(sequence)")
            }
            try append(batch, to: current)
            family[family.count - 1] += batch
            appended += batch.map(\.text)
            let poll = LogQuery.windowMeasured(
                current: current, options: LogQueryOptions(after: cursor), positionThreshold: 1, onDiskRead: nil)
            seen += poll.lines.map(\.text)
            let all = family.flatMap { $0 }
            let last = try #require(all.last)
            #expect(poll.cursor.at == last.at, "round \(round)")
            #expect(poll.cursor.count == all.reversed().prefix { $0.at == last.at }.count, "round \(round)")
            #expect(poll.cursor.position != nil, "round \(round)")
            cursor = poll.cursor
        }
        #expect(seen == appended)
    }

    private func naiveWindow(_ records: [LogRecord], _ options: LogQueryOptions) -> LogWindow {
        var matched = records
        if let after = options.after {
            matched.removeAll { $0.at < after.at }
            var skip = after.count
            matched = Array(matched.drop { record in
                guard skip > 0, record.at == after.at else { return false }
                skip -= 1
                return true
            })
        } else if let since = options.since {
            matched.removeAll { $0.at < since }
        }
        if let streams = options.streams { matched.removeAll { !streams.contains($0.stream) } }
        if options.grep != nil { matched.removeAll { !$0.text.contains("needle") } }
        var totals = LogStreamCounts(err: 0, mark: 0, out: 0, sys: 0)
        for record in matched { totals[record.stream] = (totals[record.stream] ?? 0) + 1 }
        if let head = options.head {
            matched = Array(matched.prefix(head))
        } else if let byStream = options.tailByStream {
            var keep: [Int] = []
            for stream in LogStream.allCases {
                let indices = matched.indices.filter { matched[$0].stream == stream }
                keep += byStream[stream].map { Array(indices.suffix($0)) } ?? indices
            }
            matched = keep.sorted().map { matched[$0] }
        } else if let tail = options.tail {
            matched = Array(matched.suffix(tail))
        }
        if let limit = options.maxLineCharacters {
            matched = matched.map { record in
                guard record.text.count > limit else { return record }
                return LogRecord(at: record.at, stream: record.stream, text: String(record.text.prefix(limit - 1)) + "…")
            }
        }
        let cursor = records.last.map { last in
            LogCursor(at: last.at, count: records.reversed().prefix { $0.at == last.at }.count)
        } ?? .origin
        let reportsTotals = options.after != nil || options.tailByStream != nil
        return LogWindow(cursor: cursor, lines: matched, totals: reportsTotals ? totals : nil)
    }
}

/** A seeded generator so a randomized test replays the same inputs. */
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
