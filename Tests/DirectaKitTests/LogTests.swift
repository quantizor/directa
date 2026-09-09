import Foundation
import Testing

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

@Suite struct LogQueryTests {
    private func writeFamily(_ linesPerFile: [[LogRecord]]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "directa-logq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
            literal grep all have to stay correct and return; a hang here is
            the log actor wedging on a real noisy server. */
        func stream(for offset: Int) -> LogStream { offset % 500 == 0 ? .err : .out }
        let rotated = (0..<10_000).map {
            record(Double($0), stream(for: $0), "old \($0)")
        }
        var recent = (10_000..<30_000).map {
            record(Double($0), stream(for: $0), "new \($0)")
        }
        recent[5_000] = record(15_000, .out, "NEEDLE-MID")
        let current = try writeFamily([rotated, recent])
        let started = ContinuousClock.now

        let tail = LogQuery.run(current: current, options: LogQueryOptions(tail: 5))
        #expect(tail.map(\.text) == ["new 29995", "new 29996", "new 29997", "new 29998", "new 29999"])

        let since = Date(timeIntervalSince1970: 1_700_000_000 + 25_000)
        let window = LogQuery.run(current: current, options: LogQueryOptions(since: since))
        #expect(window.count == 5_000)
        #expect(window.first?.text == "new 25000")
        #expect(window.last?.text == "new 29999")

        let hits = LogQuery.run(current: current, options: LogQueryOptions(grep: "NEEDLE-MID"))
        #expect(hits.map(\.text) == ["NEEDLE-MID"])

        let summary = LogQuery.summarize(current: current, streams: [.err], since: since)
        #expect(summary?.count == 10)

        #expect(ContinuousClock.now - started < Duration.seconds(2))
    }
}
