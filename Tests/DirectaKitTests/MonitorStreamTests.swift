import Foundation
import Testing

@testable import DirectaKit

@Suite struct MonitorSanitizerTests {
    @Test func stripsAnsiEscapes() {
        #expect(MonitorSanitizer.sanitize("\u{1B}[31mred\u{1B}[0m plain") == "red plain")
    }

    @Test func removesEveryTargetedUnicodeCategory() {
        /** Cc (U+0001, and U+0085 NEXT LINE, a line break a reader would
            otherwise see as a new directa line), Cf (U+200B ZERO WIDTH SPACE, and U+202A
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

    /** A run of a-f letters alone is a word (decade, facade, defaced), not
        an id: only a run mixing digits and letters is hex, so two
        different sentences never share a repeat key. */
    @Test func wordsSpelledOnlyWithHexLettersStayWords() {
        #expect(
            LineNormalizer.normalize("a decade ago the facade was defaced") == "a decade ago the facade was defaced")
        #expect(LineNormalizer.normalize("id 1234abcd seen") == "id <hex> seen")
        #expect(LineNormalizer.normalize("sha abcdef012345 ok") == "sha <hex> ok")
    }

    /** No digit and no dash leaves nothing any pass could match; a dash
        with no digit still reaches the UUID pass (a UUID may be all
        letters). */
    @Test func linesWithoutDigitsOrDashesPassThrough() {
        #expect(LineNormalizer.normalize("GET /health ok") == "GET /health ok")
        #expect(
            LineNormalizer.normalize("session aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee opened") == "session <uuid> opened")
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
        trimmed: [LogStream: Int] = [:], windowStart: Date? = nil
    ) -> MonitorTick {
        MonitorTick(
            at: date(offset), health: health, records: records, trimmed: trimmed,
            windowStart: windowStart ?? date(offset))
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
        let event = MonitorEvent.budget(at: date(1.5), count: 3, label: "web", stream: .out, text: "out over budget")
        let data = try JSONCoding.encoder().encode(event)
        #expect(
            String(data: data, encoding: .utf8)
                == "{\"at\":\"\(JSONCoding.formatISO8601(date(1.5)))\",\"count\":3,\"kind\":\"budget\","
                    + "\"label\":\"web\",\"stream\":\"out\",\"text\":\"out over budget\"}")
        let decoded = try JSONCoding.decoder().decode(MonitorEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test func eventWithNoStreamOmitsItFromTheEncodedObject() throws {
        let event = MonitorEvent.ended(at: date(0), label: "web", text: "ended (done)")
        let data = try JSONCoding.encoder().encode(event)
        #expect(
            String(data: data, encoding: .utf8)
                == "{\"at\":\"\(JSONCoding.formatISO8601(date(0)))\",\"kind\":\"ended\",\"label\":\"web\","
                    + "\"text\":\"ended (done)\"}")
    }

    // MARK: - Attached / ended

    @Test func attachedRendersTheStartMarker() {
        let stream = makeStream()
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

    /** The 29-minute hard cap reads as a next step, not a parenthetical
        status, names the command that reads whatever lands after the final
        cursor, and flushes exactly what `ended(reason:)` flushes: a pending
        lifecycle run and a live repeated-lines summary. */
    @Test func endedAtHardCapWordsItsLineAsANextStepAndStillFlushesPending() {
        var stream = makeStream()
        _ = stream.ingest(tick(0, records: [record(0, .err, "boom")]))
        let repeats = (0..<14).map { record(0.1 + Double($0) * 0.1, LogStream.err, "boom") }
        _ = stream.ingest(tick(1.5, records: repeats))
        let events = stream.endedAtHardCap(resumeFrom: date(1.4))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "web err| boom (repeated x14)",
            "directa web: ended after 29 minutes; run the same command again to keep watching; "
                + "anything after this: directa logs web --since \(JSONCoding.formatISO8601(date(1.4))) --head 200",
        ])
    }

    @Test func emptyTicksEmitNothing() {
        var stream = makeStream()
        #expect(stream.ingest(tick(0)).isEmpty)
        #expect(stream.ingest(tick(500)).isEmpty)
    }

    @Test func theLabelIsSanitizedOnceAndExposed() {
        var stream = makeStream(label: "web|x: y")
        #expect(stream.label == "web_x__y")
        #expect(stream.ended(reason: "done").map(\.label) == ["web_x__y"])
    }

    /** Records arrive already cut to the limit by the daemon (the ellipsis
        counts toward it) and show unchanged; health text is composed on the
        client, so the stream cuts that itself. */
    @Test func aDaemonCutLineShowsUnchangedAndLongHealthIsCut() {
        var stream = makeStream()
        let cut = String(repeating: "x", count: MonitorLimits.truncationCharacterLimit - 1) + "…"
        let events = stream.ingest(
            tick(1, health: String(repeating: "h", count: 500), records: [record(0, .out, cut)]))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "web out| \(cut)",
            "directa web: \(String(repeating: "h", count: MonitorLimits.truncationCharacterLimit - 1))…",
        ])
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

    /** A server name only appears inside a `directa logs <name> ...`
        command the reader may run, so a name that is not shell-inert
        (`ShellWord.isInert`) is never pasted there, in any hint: the reader
        gets `<name>` to fill from the server list. Sanitizing it instead
        would name a different server (an escape stripped from `we\e[31mb`
        leaves `web`). */
    @Test(arguments: ["web; rm -rf ~", "we\u{1B}[31mb\u{0007}", "$(id)", "my server"])
    func aHostileServerNameBecomesAPlaceholderInEveryHint(hostileName: String) {
        var stream = makeStream(
            budgets: MonitorBudgets(errorsPerArm: 1_000, errorsPerMinute: 1, linesPerArm: 1),
            serverName: hostileName)
        let attached = stream.attached(
            MonitorAttachSummary(checkoutPath: "/tmp/app", statusDescription: "running, pid=1"))
        let armCrossing = stream.ingest(tick(0.02, records: [record(0, .out, "o1"), record(0.01, .out, "o2")]))
        let trimmed = stream.ingest(tick(0.5, trimmed: [.err: 400], windowStart: date(0.4)))
        _ = stream.ingest(tick(1, records: [record(1, .err, "boom")]))
        _ = stream.ingest(tick(2, records: [record(2, .err, "boom")]))
        let summary = stream.ingest(tick(8))
        let minuteCrossing = stream.ingest(
            tick(9, records: (0..<11).map { record(9 + Double($0) * 0.01, LogStream.err, "distinct \($0)") }))
        let ended = stream.endedAtHardCap(resumeFrom: date(9.5))
        let lines = (attached + armCrossing + trimmed + summary + minuteCrossing + ended).map(\.humanLine)
            .filter { $0.hasPrefix("directa web: ") }
        let iso = { (offset: TimeInterval) in JSONCoding.formatISO8601(self.date(offset)) }
        #expect(lines == [
            "directa web: monitoring /tmp/app (running, pid=1; budget 120/min and 1/arm, "
                + "errors 1/min and 1000/arm); earlier output: directa logs <name> --tail 200",
            "directa web: out over budget (1 line for the rest of this monitor; re-arm to reset); "
                + "read what was skipped: directa logs <name> --since \(iso(0.01)) --stream out --head 200",
            "directa web: 400 err lines skipped (more than 300 in one tick); read them: "
                + "directa logs <name> --since \(iso(0.4)) --stream err --head 200",
            "directa web: 1 repeated line suppressed (1 distinct); directa logs <name> --since \(iso(2)) --head 200",
            "directa web: err over budget (more than 1 line a minute); read what was skipped: "
                + "directa logs <name> --since \(iso(9.09)) --stream err --head 200",
            "directa web: ended after 29 minutes; run the same command again to keep watching; "
                + "anything after this: directa logs <name> --since \(iso(9.5)) --head 200",
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

    @Test func differentLinesWhoseWordsUseOnlyHexLettersBothShow() {
        var stream = makeStream()
        let events = stream.ingest(
            tick(1, records: [record(0, .err, "the facade failed"), record(0.5, .err, "the decade failed")]))
        #expect(events.map(\MonitorEvent.humanLine) == ["web err| the facade failed", "web err| the decade failed"])
    }

    @Test func recurrenceAfterTheWindowReprintsWithAnAgainAnnotation() {
        var stream = makeStream()
        _ = stream.ingest(tick(0, records: [record(0, .err, "TypeError: X")]))
        _ = stream.ingest(tick(1, records: [record(1, .err, "TypeError: X")]))
        let events = stream.ingest(tick(15, records: [record(15, .err, "TypeError: X")]))
        #expect(events.map(\MonitorEvent.humanLine) == ["web err| TypeError: X (again, 2nd in 15s; +1 line seen before)"])
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
        #expect(thirdPrint.map(\MonitorEvent.humanLine) == ["web err| trace line 0 (again, 2nd in 20s; +1 line seen before)"])
    }

    /** Only a line seen before continues a reprinted block: a line that
        was never printed, arriving right after a recurrence, is new output
        and shows normally, and it ends the block, so a known line after it
        is judged on its own timer again. */
    @Test func aNewDistinctLineDuringABlockShowsNormally() {
        var stream = makeStream(budgets: MonitorBudgets(errorsPerArm: 10_000, errorsPerMinute: 10_000))
        _ = stream.ingest(tick(0.1, records: [record(0, .err, "trace 0"), record(0.01, .err, "trace 1")]))
        let events = stream.ingest(
            tick(
                20.1,
                records: [
                    record(20, .err, "trace 0"), record(20.01, .err, "trace 1"), record(20.02, .err, "brand new"),
                    record(20.03, .err, "trace 1"),
                ]))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "web err| trace 0 (again, 2nd in 20s)",
            "web err| brand new",
        ])
    }

    /** A flood of never-seen lines after a recurrence is ordinary output
        under the ordinary budget: the per-minute burst (10 for stderr's
        default 30/min) shows, including the recurrence line itself, then one
        over-budget marker, and nothing else reaches the reader later as
        `(repeated x1)` collapses of lines it never saw once. */
    @Test func aFloodOfDistinctLinesAfterARecurrenceStaysWithinTheBudget() {
        var stream = makeStream()
        _ = stream.ingest(tick(0, records: [record(0, .err, "boom")]))
        let flood = (0..<100).map { record(20.001 + Double($0) * 0.001, LogStream.err, "flood \($0)") }
        let events = stream.ingest(tick(20.2, records: [record(20, .err, "boom")] + flood))
        var expected = ["web err| boom (again, 2nd in 20s)"]
        expected += (0..<9).map { "web err| flood \($0)" }
        expected.append(
            "directa web: err over budget (more than 30 lines a minute); read what was skipped: "
                + "directa logs web --since \(JSONCoding.formatISO8601(flood[9].at)) --stream err --head 200")
        #expect(events.map(\MonitorEvent.humanLine) == expected)
        #expect(stream.ingest(tick(40)).isEmpty)
    }

    /** A flushed `(repeated xN)` spends one token like any shown line; with
        the bucket empty it is withheld, crosses the budget with the usual
        marker, and counts toward the resume total as one line. */
    @Test func aFlushedRepeatSpendsBudgetAndIsWithheldWhenOver() {
        var stream = makeStream(budgets: MonitorBudgets(errorsPerArm: 1_000, errorsPerMinute: 1))
        _ = stream.ingest(tick(0, records: [record(0, .err, "boom")]))
        _ = stream.ingest(tick(1, records: [record(1, .err, "boom"), record(1.5, .err, "boom")]))
        let fill = (0..<9).map { record(2 + Double($0) * 0.01, LogStream.err, "distinct \($0)") }
        #expect(stream.ingest(tick(2.1, records: fill)).count == 9)

        let flushed = stream.ingest(tick(12))
        #expect(flushed.map(\MonitorEvent.humanLine) == [
            "directa web: err over budget (more than 1 line a minute); read what was skipped: "
                + "directa logs web --since \(JSONCoding.formatISO8601(date(1.5))) --stream err --head 200"
        ])

        /** Ten minutes refill the ten-token burst; the one withheld flush is
            the whole suppressed count. */
        let resumed = stream.ingest(tick(620, records: [record(620, .err, "later")]))
        #expect(resumed.map(\MonitorEvent.humanLine) == [
            "directa web: err resumed (1 line suppressed while over budget)",
            "web err| later",
        ])
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

    /** Eviction follows when a line was last seen, never when its
        `(repeated xN)` was flushed: a flush reports old sightings, so it
        must not make the entry look recent. */
    @Test func aFlushDoesNotRefreshAnEntrysPlaceInTheLRU() {
        var stream = makeStream(budgets: MonitorBudgets(errorsPerArm: 10_000, errorsPerMinute: 10_000))
        _ = stream.ingest(tick(0.01, records: [record(0, .err, "early")]))
        _ = stream.ingest(tick(1, records: [record(1, .err, "early")]))
        let rest = (0..<(MonitorLimits.lruCapacity - 1)).map {
            record(2 + Double($0) * 0.001, LogStream.err, "distinct \($0)")
        }
        _ = stream.ingest(tick(3, records: rest))
        #expect(stream.ingest(tick(20)).map(\MonitorEvent.humanLine) == ["web err| early (repeated x1)"])

        /** One more distinct line evicts the entry seen longest ago:
            "early", last seen at 1 s, before every "distinct" line. */
        _ = stream.ingest(tick(30, records: [record(30, .err, "fresh")]))
        let events = stream.ingest(tick(40, records: [record(40, .err, "early")]))
        #expect(events.map(\MonitorEvent.humanLine) == ["web err| early"])
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
        /** The command starts at the oldest suppressed repeat (5 s), not the
            tick that printed the summary: every counted line is inside what
            it reads. */
        let events = stream.ingest(tick(30))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: 5 repeated lines suppressed (1 distinct); directa logs web --since "
                + "\(JSONCoding.formatISO8601(date(5))) --head 200"
        ])
    }

    /** Repeats a summary has reported are never reported again: once the
        burst goes stale there is nothing left to flush as `(repeated xN)`,
        and a later recurrence carries no `seen before` count for them. */
    @Test func noDoubleCountBetweenTheSummaryAndALaterFlushOrRecurrence() {
        var stream = makeStream()
        _ = stream.ingest(tick(0, records: [record(0, .err, "boom")]))
        for offset: TimeInterval in [5, 10, 15, 20, 25] {
            _ = stream.ingest(tick(offset, records: [record(offset, .err, "boom")]))
        }
        let summary = stream.ingest(tick(30))
        #expect(summary.map(\MonitorEvent.kind) == [.suppressed])
        /** 36 s: the burst window (last hit at 25 s) has closed. */
        #expect(stream.ingest(tick(36)).isEmpty)
        let recurrence = stream.ingest(tick(40, records: [record(40, .err, "boom")]))
        #expect(recurrence.map(\MonitorEvent.humanLine) == ["web err| boom (again, 2nd in 40s)"])
    }

    /** Each summary's command starts at the oldest repeat counted since the
        previous summary, never at an earlier one already reported. */
    @Test func aSecondSummaryStartsAtItsOwnOldestRepeat() {
        var stream = makeStream()
        _ = stream.ingest(tick(0, records: [record(0, .err, "boom")]))
        _ = stream.ingest(tick(1, records: [record(1, .err, "boom")]))
        _ = stream.ingest(tick(6))
        _ = stream.ingest(tick(8, records: [record(7, .err, "boom"), record(8, .err, "boom")]))
        let events = stream.ingest(tick(13))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: 2 repeated lines suppressed (1 distinct); directa logs web --since "
                + "\(JSONCoding.formatISO8601(date(7))) --head 200"
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
            "directa web: 1 repeated line suppressed (1 distinct); directa logs web --since "
                + "\(JSONCoding.formatISO8601(date(1))) --head 200"
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
            "directa web: out over budget (more than 60 lines a minute); read what was skipped: "
                + "directa logs web --since \(JSONCoding.formatISO8601(date(0.015))) --stream out --head 200")
        #expect(events.map(\MonitorEvent.humanLine) == expected)
    }

    @Test func stdoutPerMinuteExhaustionRefillsAndReportsWhatWasSkipped() {
        var stream = makeStream(budgets: MonitorBudgets(linesPerArm: 1_000, linesPerMinute: 60))
        _ = stream.ingest(tick(0.02, records: distinctOutTexts(20)))
        /** At 1 token/s the stream stays withheld until the bucket is back to
            its full burst of 15: a line at 14 s is still withheld, one at
            15.1 s resumes. */
        let held = stream.ingest(tick(14.02, records: [record(14.02, .out, "held line")]))
        #expect(held.isEmpty)
        let events = stream.ingest(tick(15.12, records: [record(15.12, .out, "resumed line")]))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: out resumed (6 lines suppressed while over budget)",
            "web out| resumed line",
        ])
    }

    /** A server steadily printing faster than its budget produces at most one
        over-budget marker per refill period, never one per tick. */
    @Test func aSteadilyChattyServerDoesNotFlapBetweenOverBudgetAndResumed() {
        var stream = makeStream(budgets: MonitorBudgets(linesPerArm: 20_000, linesPerMinute: 60))
        var markers = 0
        for step in 0..<300 {
            let at = Double(step) * 0.2
            let events = stream.ingest(tick(at + 0.01, records: [record(at, .out, "line \(step)")]))
            markers += events.filter { $0.kind == .budget }.count
        }
        /** 60 s at 5 lines/s against 1 line/s with a 15-line burst: one
            crossing, then each resume and re-crossing needs a 15 s refill, so
            at most 4 crossings and 3 resumes. */
        #expect(markers <= 7)
        #expect(markers >= 2)
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
            "directa web: out over budget (1 line for the rest of this monitor; re-arm to reset); "
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
        /** 15.1 s later the bucket is back to its full 15-line burst. */
        let events = stream.ingest(tick(15.116, records: [record(15.116, .out, "resumed")]))
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
        let events = stream.ingest(tick(0.5, trimmed: [.out: 400, .err: 12], windowStart: date(0.1)))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: 400 out lines skipped (more than 300 in one tick); read them: "
                + "directa logs web --since \(JSONCoding.formatISO8601(date(0.1))) --stream out --head 200",
            "directa web: 12 err lines skipped (more than 300 in one tick); read them: "
                + "directa logs web --since \(JSONCoding.formatISO8601(date(0.1))) --stream err --head 200",
        ])
    }

    /** Lifecycle and marks have no budget to fold a trim into, so a sys or
        mark trim always gets its own marker, naming that stream's smaller
        per-tick cap, even while out is over its budget. */
    @Test func aLifecycleOrMarkTrimAlwaysGetsItsOwnSkippedMarker() {
        var stream = makeStream(budgets: MonitorBudgets(linesPerArm: 1_000, linesPerMinute: 60))
        _ = stream.ingest(tick(0.016, records: distinctOutTexts(16)))
        let events = stream.ingest(tick(0.5, trimmed: [.mark: 2, .out: 7, .sys: 3], windowStart: date(0.2)))
        let since = JSONCoding.formatISO8601(date(0.2))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: 3 sys lines skipped (more than 50 in one tick); read them: "
                + "directa logs web --since \(since) --stream sys --head 200",
            "directa web: 2 mark lines skipped (more than 50 in one tick); read them: "
                + "directa logs web --since \(since) --stream mark --head 200",
        ])
        #expect(events.map(\.kind) == [.suppressed, .suppressed])
        #expect(events.map(\.count) == [3, 2])
    }

    /** The daemon keeps the newest lines of a trimmed window, so the skipped
        ones start at the cursor the query read past: the marker's command
        starts there, and the marker sorts ahead of the lines this tick did
        return, never after them. */
    @Test func aSkippedMarkerStartsAtTheWindowAndPrecedesTheReturnedLines() {
        var stream = makeStream()
        let events = stream.ingest(
            tick(
                2, records: [record(1.5, .out, "newest kept"), record(1.9, .out, "last kept")],
                trimmed: [.out: 350], windowStart: date(0.25)))
        #expect(events.map(\MonitorEvent.humanLine) == [
            "directa web: 350 out lines skipped (more than 300 in one tick); read them: "
                + "directa logs web --since \(JSONCoding.formatISO8601(date(0.25))) --stream out --head 200",
            "web out| newest kept",
            "web out| last kept",
        ])
        #expect(events.first?.at == date(0.25))
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
