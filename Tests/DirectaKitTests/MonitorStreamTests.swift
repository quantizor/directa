import Foundation
import Testing

@testable import DirectaKit

@Suite struct MonitorSanitizerTests {
    @Test func stripsAnsiEscapes() {
        #expect(MonitorSanitizer.sanitize("\u{1B}[31mred\u{1B}[0m plain") == "red plain")
    }

    @Test func removesEveryTargetedUnicodeCategory() {
        /** Cc (U+0001, and U+0085 NEXT LINE specifically because the plan
            calls it out by name), Cf (U+200B ZERO WIDTH SPACE, and U+202A
            LEFT-TO-RIGHT EMBEDDING as a bidi override), Zl (U+2028 LINE
            SEPARATOR), Zp (U+2029 PARAGRAPH SEPARATOR): every character
            besides the visible letters must disappear, none replaced by a
            space. */
        let raw = "a\u{0001}b\u{0085}c\u{200B}d\u{202A}e\u{2028}f\u{2029}g"
        #expect(MonitorSanitizer.sanitize(raw) == "abcdefg")
    }

    @Test func foldsTabToSpaceBeforeTheCategorySweep() {
        #expect(MonitorSanitizer.sanitize("a\tb") == "a b")
    }

    @Test func labelAlsoFoldsPipeColonAndWhitespaceToUnderscore() {
        #expect(MonitorSanitizer.sanitizeLabel("my|app: review branch") == "my_app__review_branch")
    }

    @Test func labelSanitizationStripsAnsiAndControlTooBeforeFolding() {
        let hostile = "web\u{1B}[31m\u{0007}|evil name"
        #expect(MonitorSanitizer.sanitizeLabel(hostile) == "web_evil_name")
    }

    @Test func truncatesPastTheLimitWithEllipsis() {
        let long = String(repeating: "x", count: 401)
        let truncated = MonitorSanitizer.truncate(long, limit: MonitorLimits.truncationCharacterLimit)
        #expect(truncated == String(repeating: "x", count: 400) + "…")
        let exact = String(repeating: "x", count: 400)
        #expect(MonitorSanitizer.truncate(exact, limit: MonitorLimits.truncationCharacterLimit) == exact)
    }
}

@Suite struct LineNormalizerTests {
    @Test func keepsShortNumbersDistinct() {
        /** 3-digit HTTP status codes must never collapse into each other:
            that would make a 200 and a 500 look like the same repeating
            line. */
        #expect(LineNormalizer.normalize("GET /x 200") != LineNormalizer.normalize("GET /x 500"))
    }

    @Test func collapsesLongNumbersOfFiveDigitsOrMore() {
        #expect(LineNormalizer.normalize("request 12345 done") == "request <num> done")
        #expect(LineNormalizer.normalize("request 1234 done") == "request 1234 done")
    }

    @Test func collapsesUUIDs() {
        #expect(
            LineNormalizer.normalize("session 123e4567-e89b-12d3-a456-426614174000 opened")
                == "session <uuid> opened")
    }

    @Test func collapsesTimestamps() {
        #expect(
            LineNormalizer.normalize("at 2026-09-26T05:30:40.118Z failed")
                == "at <timestamp> failed")
    }

    @Test func collapsesHexRunsButNotPlainWords() {
        #expect(LineNormalizer.normalize("commit deadbeef1 pushed") == "commit <hex> pushed")
        /** No a-f letter present: a pure digit run this short stays untouched
            by the hex rule (it is still short of the 5-digit number rule). */
        #expect(LineNormalizer.normalize("port 30301") == "port <num>")
    }
}

@Suite struct MonitorStreamTests {
    private static let epoch: TimeInterval = 1_700_000_000

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: Self.epoch + offset)
    }

    private func record(_ offset: TimeInterval, _ stream: LogStream, _ text: String) -> LogRecord {
        LogRecord(at: date(offset), stream: stream, text: text)
    }

    private func tick(
        _ offset: TimeInterval, health: String? = nil, records: [LogRecord] = [],
        trimmed: [LogStream: Int] = [:]
    ) -> MonitorTick {
        MonitorTick(at: date(offset), health: health, records: records, trimmed: trimmed)
    }

    private func makeStream(
        budgets: MonitorBudgets = .defaults, label: String = "web", serverName: String = "web",
        startOffset: TimeInterval = 0
    ) -> MonitorStream {
        MonitorStream(
            config: MonitorConfig(
                budgets: budgets, clockStart: date(startOffset), label: label, serverName: serverName))
    }

    // MARK: - Codable

    @Test func eventEncodesThroughJSONCodingWithSortedKeysAndMillisecondTimestamps() throws {
        let event = MonitorEvent(
            at: date(1.5), count: 3, kind: .budget, label: "web", stream: .out, text: "out over budget")
        let data = try JSONCoding.encoder().encode(event)
        #expect(
            String(data: data, encoding: .utf8)
                == "{\"at\":\"\(JSONCoding.formatISO8601(date(1.5)))\",\"count\":3,\"kind\":\"budget\","
                    + "\"label\":\"web\",\"stream\":\"out\",\"text\":\"out over budget\"}")
        let decoded = try JSONCoding.decoder().decode(MonitorEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test func eventWithNoStreamOmitsItFromTheEncodedObject() throws {
        let event = MonitorEvent(at: date(0), kind: .ended, label: "web", text: "ended (done)")
        let data = try JSONCoding.encoder().encode(event)
        #expect(
            String(data: data, encoding: .utf8)
                == "{\"at\":\"\(JSONCoding.formatISO8601(date(0)))\",\"kind\":\"ended\",\"label\":\"web\","
                    + "\"text\":\"ended (done)\"}")
    }

    // MARK: - Attached / ended

    @Test func attachedRendersTheStartMarker() {
        var stream = makeStream()
        let events = stream.attached(
            MonitorAttachSummary(checkoutPath: "/Users/me/app", statusDescription: "running, pid=812"))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: monitoring /Users/me/app (running, pid=812; budget 120/min and 600/arm, "
                + "errors 30/min and 300/arm); earlier output: directa logs web --tail 200"
        ])
    }

    @Test func endedEmitsATerminalLineAndFlushesWhateverWasPending() {
        var stream = makeStream()
        _ = stream.ingest(tick(0, records: [record(0, .sys, "watch suspended: a keeps changing")]))
        _ = stream.ingest(tick(1, records: [record(1, .sys, "watch suspended: a keeps changing")]))
        let events = stream.ended(reason: "server unregistered")
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: watch suspended: a keeps changing (repeated x1)",
            "directa web: ended (server unregistered)",
        ])
    }

    @Test func emptyTicksEmitNothing() {
        var stream = makeStream()
        #expect(stream.ingest(tick(0)).isEmpty)
        #expect(stream.ingest(tick(500)).isEmpty)
    }

    // MARK: - Lifecycle classification

    @Test func classifiesEverySysProducerPrefixByExactText() {
        /** Every literal text ServerSupervisor.swift, LogStore.swift, and
            SpoolTailer.swift hand to `logStore.append(stream: .sys, ...)`,
            plus one hypothetical future producer to prove the fallback still
            shows rather than silently drops. */
        var stream = makeStream()
        let texts = [
            "started pid=840",
            "exited code=1",
            "exited signal=15",
            "exited unknown",
            "stopping: requested by restart",
            "spawn failed: posix_spawn failed",
            "adopted pid=99",
            "watch suspended: package.json keeps changing",
            "spool catch-up skipped 128 bytes",
            "stop did not complete within 10.0s; server may still be tearing down",
            "rotated",
            "a future sys line nobody classified yet",
        ]
        let records = texts.enumerated().map { index, text in record(Double(index), .sys, text) }
        let events = stream.ingest(tick(Double(texts.count), records: records))
        #expect(events.map(\MonitorEvent.humanLine) == texts.filter { $0 != "rotated" }.map { "directa web: \($0)" })
    }

    @Test func lifecycleBypassesTheRepeatFilterAcrossARestart() {
        /** Two `started pid=` lines carrying the identical text (a restart
            that happens to reuse the same pid) both show: lifecycle never
            enters the LRU that would treat identical out/err text as one
            recurring line. */
        var stream = makeStream()
        let records = [
            record(0, .sys, "started pid=12345"),
            record(5, .sys, "stopping: requested by restart"),
            record(6, .sys, "exited signal=15"),
            record(7, .sys, "started pid=12345"),
        ]
        let events = stream.ingest(tick(8, records: records))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: started pid=12345",
            "directa web: stopping: requested by restart",
            "directa web: exited signal=15",
            "directa web: started pid=12345",
        ])
    }

    @Test func identicalConsecutiveLifecycleLinesCollapse() {
        var stream = makeStream()
        let records = [
            record(0, .sys, "watch suspended: package.json keeps changing"),
            record(1, .sys, "watch suspended: package.json keeps changing"),
            record(2, .sys, "watch suspended: package.json keeps changing"),
            record(3, .sys, "started pid=1"),
        ]
        let events = stream.ingest(tick(4, records: records))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: watch suspended: package.json keeps changing",
            "directa web: watch suspended: package.json keeps changing (repeated x2)",
            "directa web: started pid=1",
        ])
    }

    @Test func markLinesRenderWithTheMarkPrefix() {
        var stream = makeStream()
        let events = stream.ingest(tick(0, records: [record(0, .mark, "checkout test begins")]))
        #expect(events.map(\MonitorEvent.humanLine) == ["directa web: mark checkout test begins"])
    }

    @Test func lifecyclePassesEveryBudgetRegardlessOfOutExhaustion() {
        var stream = makeStream(budgets: MonitorBudgets(linesPerArm: 1))
        /** Exhaust stdout's arm cap completely. */
        _ = stream.ingest(tick(0, records: [record(0, .out, "first line")]))
        _ = stream.ingest(tick(1, records: [record(1, .out, "second line")]))
        let texts = (0..<20).map { "started pid=\($0)" }
        let records = texts.enumerated().map { index, text in record(Double(2 + index), .sys, text) }
        let events = stream.ingest(tick(22, records: records))
        #expect(events.map(\MonitorEvent.humanLine) == texts.map { "directa web: \($0)" })
    }

    // MARK: - Namespace spoofing

    @Test func childContentCannotSpoofADirectaOrOppositeStreamNamespace() {
        var stream = makeStream()
        let records = [
            record(0, .out, "directa web: started pid=99999"),
            record(1, .err, "web out| fake injected line"),
            record(2, .out, "mark fake-mark-content"),
        ]
        let events = stream.ingest(tick(3, records: records))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "web out| directa web: started pid=99999",
            "web err| web out| fake injected line",
            "web out| mark fake-mark-content",
        ])
    }

    @Test func hostileServerNameIsSanitizedEverywhereItAppears() {
        /** ANSI red plus a BEL, the exact place a stray escape or control
            byte reaching the "earlier output" hint would land in a
            terminal. */
        let hostileName = "we\u{1B}[31mb\u{0007}"
        var stream = makeStream(serverName: hostileName)
        let events = stream.attached(
            MonitorAttachSummary(checkoutPath: "/tmp/app", statusDescription: "running, pid=1"))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: monitoring /tmp/app (running, pid=1; budget 120/min and 600/arm, "
                + "errors 30/min and 300/arm); earlier output: directa logs web --tail 200"
        ])
    }

    // MARK: - Repeat suppression

    @Test func burstRepeatWithinTheWindowIsSuppressedNotShown() {
        var stream = makeStream()
        let records = [
            record(0, .err, "TypeError: X"),
            record(2, .err, "TypeError: X"),
            record(4, .err, "TypeError: X"),
        ]
        let events = stream.ingest(tick(5, records: records))
        #expect(events.map(\MonitorEvent.humanLine) == ["web err| TypeError: X"])
    }

    @Test func recurrenceAfterTheWindowReprintsWithAnAgainAnnotation() {
        var stream = makeStream()
        _ = stream.ingest(tick(0, records: [record(0, .err, "TypeError: X")]))
        _ = stream.ingest(tick(1, records: [record(1, .err, "TypeError: X")]))
        let events = stream.ingest(tick(15, records: [record(15, .err, "TypeError: X")]))
        #expect(events.map(\MonitorEvent.humanLine) == ["web err| TypeError: X (again, 2nd in 15s; +1 lines seen before)"])
    }

    @Test func noDoubleCountBetweenARepeatedFlushAndTheSummary() {
        /** The 14 burst repeats collapse into one `(repeated x14)` marker
            when their window goes stale; that marker's count must not also
            show up moments later in the periodic suppressed-lines summary. */
        var stream = makeStream()
        _ = stream.ingest(tick(0, records: [record(0, .err, "boom")]))
        let repeats = (0..<14).map { record(0.1 + Double($0) * 0.1, LogStream.err, "boom") }
        _ = stream.ingest(tick(1.5, records: repeats))
        let flushEvents = stream.ingest(tick(20, records: [record(20, .out, "unrelated")]))
        #expect(flushEvents.map(\MonitorEvent.humanLine) == [
            "web err| boom (repeated x14)",
            "web out| unrelated",
        ])
        let quiet = stream.ingest(tick(40))
        #expect(quiet.isEmpty)
    }

    @Test func multiLineBlockReprintShowsOnlyItsFirstLineWithASeenBeforeCount() {
        /** A generously large budget: this test is about repeat suppression,
            not budgets, and 3 printings of a 40-line trace would otherwise
            exhaust stderr's default per-minute burst on the very first
            printing. */
        var stream = makeStream(budgets: MonitorBudgets(errorsPerArm: 10_000, errorsPerMinute: 10_000))
        let lineCount = 40
        func block(startingAt offset: TimeInterval) -> [LogRecord] {
            (0..<lineCount).map { record(offset + Double($0) * 0.01, LogStream.err, "trace line \($0)") }
        }

        let firstPrint = stream.ingest(tick(0.4, records: block(startingAt: 0)))
        #expect(firstPrint.map(\MonitorEvent.humanLine) == (0..<lineCount).map { "web err| trace line \($0)" })

        /** A reprint 5 s later is a burst repeat for every line: none show. */
        let secondPrint = stream.ingest(tick(5.4, records: block(startingAt: 5)))
        #expect(secondPrint.isEmpty)

        /** A third print 15 s after that: line 0's own window has gone
            stale, so it recurs individually with its own suppressed count;
            block continuation forces every other line into burst-repeat
            handling regardless of their own timers, so only line 0 shows. */
        let thirdPrint = stream.ingest(tick(20.4, records: block(startingAt: 20)))
        #expect(thirdPrint.map(\MonitorEvent.humanLine) == ["web err| trace line 0 (again, 2nd in 20s; +1 lines seen before)"])
    }

    @Test func lruCapacityEvictsTheOldestEntry() {
        var stream = makeStream()
        let capacity = MonitorLimits.lruCapacity
        let firstBatch = (0..<capacity).map { record(Double($0) * 0.001, LogStream.err, "distinct \($0)") }
        _ = stream.ingest(tick(Double(capacity) * 0.001, records: firstBatch))

        /** One more distinct line evicts "distinct 0" (the oldest, never
            touched again since its first showing). */
        _ = stream.ingest(
            tick(1_000, records: [record(1_000, .err, "distinct \(capacity)")]))

        /** Resending the evicted line's exact text shows it as brand new,
            with no "(again...)" annotation, proving its history is gone. */
        let events = stream.ingest(tick(2_000, records: [record(2_000, .err, "distinct 0")]))
        #expect(events.map(\MonitorEvent.humanLine) == ["web err| distinct 0"])
    }

    @Test func summaryFiresOnTheThirtySecondCadenceWhileRepeatsAreCounted() {
        var stream = makeStream()
        _ = stream.ingest(tick(0, records: [record(0, .err, "boom")]))
        /** A burst repeat every 5 s keeps this entry's own burst window from
            ever going stale (each hit is well inside the prior hit's 10 s
            window), so the individual `(repeated xN)` flush never fires and
            the 5 suppressed hits stay live for the periodic summary alone. */
        for offset: TimeInterval in [5, 10, 15, 20, 25] {
            _ = stream.ingest(tick(offset, records: [record(offset, .err, "boom")]))
        }
        /** 29 s since the last summary (clockStart): not due yet, and out/err
            were active 4 s ago (25 s), so the 5 s quiet trigger has not
            tripped either. */
        #expect(stream.ingest(tick(29)).isEmpty)
        let events = stream.ingest(tick(30))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: 5 repeated lines suppressed (1 distinct); directa logs web --since "
                + "\(JSONCoding.formatISO8601(date(30))) --head 200"
        ])
    }

    @Test func summaryFiresOnTheFiveSecondQuietTriggerBeforeTheCadenceIsDue() {
        var stream = makeStream()
        _ = stream.ingest(tick(0, records: [record(0, .err, "boom")]))
        _ = stream.ingest(tick(1, records: [record(1, .err, "boom")]))
        /** Only 5 s after the last out/err activity (at 1 s), well short of
            the 30 s cadence: the quiet trigger fires the summary early. */
        let events = stream.ingest(tick(6))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: 1 repeated lines suppressed (1 distinct); directa logs web --since "
                + "\(JSONCoding.formatISO8601(date(6))) --head 200"
        ])
    }

    // MARK: - Budgets

    private func distinctOutTexts(_ count: Int, offset: TimeInterval = 0) -> [LogRecord] {
        (0..<count).map { record(offset + Double($0) * 0.001, LogStream.out, "line \($0)") }
    }

    @Test func stdoutBurstAllowsAShortSpikeThenThrottles() {
        var stream = makeStream(budgets: MonitorBudgets(linesPerArm: 1_000, linesPerMinute: 60))
        let records = distinctOutTexts(20)
        let events = stream.ingest(tick(0.02, records: records))
        var expected = (0..<15).map { "web out| line \($0)" }
        expected.append(
            "directa web: out over budget (60 lines this minute); read what was skipped: "
                + "directa logs web --since \(JSONCoding.formatISO8601(date(0.015))) --stream out --head 200")
        #expect(events.map(\MonitorEvent.humanLine) == expected)
    }

    @Test func stdoutPerMinuteExhaustionRefillsAndReportsWhatWasSkipped() {
        var stream = makeStream(budgets: MonitorBudgets(linesPerArm: 1_000, linesPerMinute: 60))
        _ = stream.ingest(tick(0.02, records: distinctOutTexts(20)))
        /** 2 s later at 1 token/s the bucket has 2 tokens: enough for the
            next line to show, transitioning out of the over-budget state. */
        let events = stream.ingest(tick(2.02, records: [record(2.02, .out, "resumed line")]))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: out resumed (5 lines suppressed while over budget)",
            "web out| resumed line",
        ])
    }

    @Test func stdoutPerArmExhaustionIsPermanentAndNeverRefills() {
        var stream = makeStream(budgets: MonitorBudgets(linesPerArm: 5))
        let firstSix = distinctOutTexts(6)
        let events = stream.ingest(tick(0.01, records: firstSix))
        var expected = (0..<5).map { "web out| line \($0)" }
        expected.append(
            "directa web: out over budget (5 lines for the rest of this monitor; re-arm to reset); "
                + "read what was skipped: directa logs web --since \(JSONCoding.formatISO8601(date(0.005))) "
                + "--stream out --head 200")
        #expect(events.map(\MonitorEvent.humanLine) == expected)

        /** A later attempt, even after what would be a per-minute refill,
            stays silent: the arm cap never resets short of a new instance. */
        let later = stream.ingest(tick(120, records: [record(120, .out, "line 6")]))
        #expect(later.isEmpty)
    }

    @Test func stderrBudgetIsIndependentOfStdouts() {
        var stream = makeStream(budgets: MonitorBudgets(linesPerArm: 1))
        _ = stream.ingest(tick(0.01, records: [record(0, .out, "line 0")]))
        /** "line 1" is the transition past stdout's arm cap and fires the one
            permanent over-budget marker for out; stderr, an independent
            budget, keeps showing normally in the very same tick. */
        let events = stream.ingest(
            tick(
                0.02,
                records: [
                    record(0.01, .out, "line 1"), record(0.02, .err, "err 0"),
                    record(0.03, .err, "err 1"),
                ]))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: out over budget (1 lines for the rest of this monitor; re-arm to reset); "
                + "read what was skipped: directa logs web --since \(JSONCoding.formatISO8601(date(0.01))) "
                + "--stream out --head 200",
            "web err| err 0",
            "web err| err 1",
        ])
    }

    @Test func suppressedCountsCombineDaemonTrimmingAndClientBudgetWithholding() {
        var stream = makeStream(budgets: MonitorBudgets(linesPerArm: 1_000, linesPerMinute: 60))
        /** 16 lines: 15 shown, the 16th crosses the budget (1 withheld). */
        _ = stream.ingest(tick(0.016, records: distinctOutTexts(16)))
        /** The daemon separately trimmed 7 more out lines this tick while
            the stream is already over budget; no line arrives to show. */
        _ = stream.ingest(tick(0.5, trimmed: [.out: 7]))
        /** 2 s later, enough tokens refill for the next line to show. */
        let events = stream.ingest(tick(2.016, records: [record(2.016, .out, "resumed")]))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: out resumed (8 lines suppressed while over budget)",
            "web out| resumed",
        ])
    }

    @Test func daemonTrimmingOutsideAnOverBudgetWindowGetsItsOwnSkippedMarker() {
        /** Nothing here ever touches the client budget: a single tick just
            arrived with more out and err lines than the daemon's own
            per-tick fetch cap, so the daemon itself dropped the rest before
            this stream ever saw them. Neither stream is over its client
            budget, so this must not be silently folded away. */
        var stream = makeStream()
        let events = stream.ingest(tick(0.5, trimmed: [.out: 400, .err: 12]))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: 400 out lines skipped (more than 300 in one tick); read them: "
                + "directa logs web --since \(JSONCoding.formatISO8601(date(0.5))) --stream out --head 200",
            "directa web: 12 err lines skipped (more than 300 in one tick); read them: "
                + "directa logs web --since \(JSONCoding.formatISO8601(date(0.5))) --stream err --head 200",
        ])
    }

    @Test func daemonTrimmingInsideAnOverBudgetWindowNeverGetsTheSkippedMarker() {
        /** Once out is over its per-minute budget, further daemon trimming
            on out folds into the eventual resume count instead of also
            firing the standalone skipped marker: the user is already going
            to hear about this stream's suppressed lines exactly once. */
        var stream = makeStream(budgets: MonitorBudgets(linesPerArm: 1_000, linesPerMinute: 60))
        _ = stream.ingest(tick(0.016, records: distinctOutTexts(16)))
        let events = stream.ingest(tick(0.5, trimmed: [.out: 7]))
        #expect(events.isEmpty)
    }
}
