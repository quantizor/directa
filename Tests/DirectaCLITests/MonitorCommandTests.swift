import ArgumentParser
import DirectaKit
import Foundation
import Testing

@testable import directa

/** A fake `MonitorRequesting`: each of the two daemon calls draws from its
    own queue in call order. Once a queue runs dry it repeats its last
    response instead of crashing the whole suite: `server.status` fires on
    its own 10 s schedule inside a tick a test is really scripting for a
    different reason (an unreachable stretch spanning tens of seconds, say),
    so every test would otherwise have to pre-count those incidental polls.
    A queue that has never received anything crashes loudly, since that is
    always a genuine test-setup mistake. */
private actor FakeMonitorRequester: MonitorRequesting {
    private(set) var logsCallCount = 0
    private(set) var logsParamsSeen: [LogsQueryParams] = []
    private var logsQueue: [Result<LogsQueryResult, WireError>] = []
    private var lastLogs: Result<LogsQueryResult, WireError>?
    private(set) var statusCallCount = 0
    private var statusQueue: [Result<ServerListResult, WireError>] = []
    private var lastStatus: Result<ServerListResult, WireError>?

    func enqueueLogs(_ result: Result<LogsQueryResult, WireError>) {
        logsQueue.append(result)
    }

    func enqueueStatus(_ result: Result<ServerListResult, WireError>) {
        statusQueue.append(result)
    }

    func fetchStatus(_ params: ProjectParams) async throws -> ServerListResult {
        statusCallCount += 1
        let popped = statusQueue.isEmpty ? nil : statusQueue.removeFirst()
        guard let result = popped ?? lastStatus else {
            fatalError("FakeMonitorRequester: no queued server.status response for call #\(statusCallCount)")
        }
        lastStatus = result
        return try result.get()
    }

    func queryLogs(_ params: LogsQueryParams) async throws -> LogsQueryResult {
        logsCallCount += 1
        logsParamsSeen.append(params)
        let popped = logsQueue.isEmpty ? nil : logsQueue.removeFirst()
        guard let result = popped ?? lastLogs else {
            fatalError("FakeMonitorRequester: no queued logs.query response for call #\(logsCallCount)")
        }
        lastLogs = result
        return try result.get()
    }
}

/** A fake `MonitorClock`: `now()` reads whatever the test last set, and
    never advances on its own, so every backoff and poll-interval decision is
    driven by the test rather than the wall clock. */
private actor FakeMonitorClock: MonitorClock {
    private var current: Date

    init(start: Date) {
        current = start
    }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }

    func now() async -> Date {
        current
    }
}

@Suite struct MonitorSessionTests {
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func config(
        name: String = "web", project: String = "/tmp/proj", tickSeconds: Double = 2
    ) -> MonitorRunConfig {
        MonitorRunConfig(budgets: .defaults, name: name, project: project, tickSeconds: tickSeconds)
    }

    private func attachLogsResult(cursor: LogCursor = LogCursor(at: Self.epoch, count: 0)) -> LogsQueryResult {
        LogsQueryResult(cursor: cursor, lines: [], totals: LogStreamCounts(err: 0, mark: 0, out: 0, sys: 0))
    }

    private func tickLogsResult(
        cursor: LogCursor, lines: [LogRecord] = [], totals: LogStreamCounts = LogStreamCounts(err: 0, mark: 0, out: 0, sys: 0)
    ) -> LogsQueryResult {
        LogsQueryResult(cursor: cursor, lines: lines, totals: totals)
    }

    private func serverStatus(
        lastExit: LastExit? = nil, name: String, phase: ServerPhase, pid: Int? = nil, worktree: String? = nil
    ) -> ServerStatus {
        ServerStatus(
            lastExit: lastExit, logPath: "/logs/\(name)/current.log", phase: phase, pid: pid, project: "/tmp/proj",
            server: name, worktree: worktree)
    }

    // MARK: - Feature gate

    @Test func featureGateExitsWhenAttachLacksCursorOrTotals() async {
        let requester = FakeMonitorRequester()
        await requester.enqueueLogs(.success(LogsQueryResult(cursor: nil, lines: [], totals: nil)))
        var session = MonitorSession(
            client: requester, clock: FakeMonitorClock(start: Self.epoch), config: config())
        guard case .exit(let error) = await session.step() else {
            Issue.record("expected .exit for a daemon missing cursor/totals")
            return
        }
        #expect(error == Logs.olderDaemon)
    }

    @Test func featureGatePassesWhenBothFieldsArePresentEvenWithNoLines() async {
        let requester = FakeMonitorRequester()
        await requester.enqueueLogs(.success(attachLogsResult()))
        await requester.enqueueStatus(.success(ServerListResult(servers: [serverStatus(name: "web", phase: .running, pid: 812)])))
        var session = MonitorSession(
            client: requester, clock: FakeMonitorClock(start: Self.epoch), config: config())
        guard case .events(let events, let delay) = await session.step() else {
            Issue.record("expected the attach marker, not an exit")
            return
        }
        #expect(events.count == 1)
        #expect(delay == 2)
    }

    // MARK: - Not-found

    @Test func notFoundAtAttachExitsBeforeStreaming() async {
        let requester = FakeMonitorRequester()
        await requester.enqueueLogs(.failure(WireError(code: .notFound, message: "no server named 'web' in /tmp/proj")))
        var session = MonitorSession(
            client: requester, clock: FakeMonitorClock(start: Self.epoch), config: config())
        guard case .exit(let error) = await session.step() else {
            Issue.record("expected .exit for an unknown server name")
            return
        }
        #expect(error.code == .notFound)
    }

    @Test func notFoundAfterAttachEndsTheStreamGracefully() async {
        let requester = FakeMonitorRequester()
        let clock = FakeMonitorClock(start: Self.epoch)
        await requester.enqueueLogs(.success(attachLogsResult()))
        await requester.enqueueStatus(.success(ServerListResult(servers: [serverStatus(name: "web", phase: .running, pid: 812)])))
        var session = MonitorSession(client: requester, clock: clock, config: config())
        guard case .events = await session.step() else {
            Issue.record("expected the attach marker")
            return
        }

        await requester.enqueueLogs(.failure(WireError(code: .notFound, message: "no server named 'web' in /tmp/proj")))
        guard case .ended(let events) = await session.step() else {
            Issue.record("expected .ended once the server disappears mid-stream")
            return
        }
        #expect(events.map(\.humanLine) == ["directa web: ended (server unregistered)"])
    }

    // MARK: - A stopped server

    @Test func stoppedServerAttachesNamesItsPhaseAndWaitsQuietly() async {
        let requester = FakeMonitorRequester()
        let clock = FakeMonitorClock(start: Self.epoch)
        let cursor = LogCursor(at: Self.epoch, count: 0)
        await requester.enqueueLogs(.success(attachLogsResult(cursor: cursor)))
        await requester.enqueueStatus(.success(ServerListResult(servers: [serverStatus(name: "web", phase: .stopped)])))
        var session = MonitorSession(client: requester, clock: clock, config: config())
        guard case .events(let attachEvents, _) = await session.step() else {
            Issue.record("expected the attach marker")
            return
        }
        #expect(attachEvents.first?.humanLine.contains("stopped") == true)

        await clock.advance(by: 2)
        await requester.enqueueLogs(.success(tickLogsResult(cursor: cursor)))
        guard case .events(let tickEvents, let delay) = await session.step() else {
            Issue.record("expected a quiet tick, not an ending")
            return
        }
        #expect(tickEvents.isEmpty)
        #expect(delay == 2)
    }

    // MARK: - Transient sequence and recovery

    @Test func transientSequenceReportsOncePerTransitionBacksOffAndRecovers() async {
        let requester = FakeMonitorRequester()
        let clock = FakeMonitorClock(start: Self.epoch)
        let cursor = LogCursor(at: Self.epoch, count: 0)
        await requester.enqueueLogs(.success(attachLogsResult(cursor: cursor)))
        await requester.enqueueStatus(.success(ServerListResult(servers: [serverStatus(name: "web", phase: .running, pid: 812)])))
        var session = MonitorSession(client: requester, clock: clock, config: config(tickSeconds: 2))
        _ = await session.step()

        /** First config-invalid failure: one transient line, delay at the
            plain tick interval. */
        await requester.enqueueLogs(.failure(WireError(code: .configInvalid, message: "bad config")))
        guard case .events(let first, let firstDelay) = await session.step() else {
            Issue.record("expected a transient tick")
            return
        }
        #expect(first.map(\.humanLine) == ["directa web: config is invalid, waiting (directa config check)"])
        #expect(firstDelay == 2)
        await clock.advance(by: firstDelay)

        /** Second consecutive config-invalid: same kind, so no repeated
            line, and the backoff has doubled. */
        await requester.enqueueLogs(.failure(WireError(code: .configInvalid, message: "bad config")))
        guard case .events(let second, let secondDelay) = await session.step() else {
            Issue.record("expected a transient tick")
            return
        }
        #expect(second.isEmpty)
        #expect(secondDelay == 4)
        await clock.advance(by: secondDelay)

        /** A different transient kind (the daemon restoring) gets its own
            line even though the loop was already in a transient state. */
        await requester.enqueueLogs(.failure(WireError(code: .daemonStarting, message: "restoring")))
        guard case .events(let third, let thirdDelay) = await session.step() else {
            Issue.record("expected a transient tick")
            return
        }
        #expect(third.map(\.humanLine) == ["directa web: the daemon is restoring supervised servers, waiting"])
        await clock.advance(by: thirdDelay)

        /** Recovery: a normal tick reports no transient line, and the
            backoff has reset to the plain tick interval. */
        await requester.enqueueLogs(.success(tickLogsResult(cursor: cursor)))
        guard case .events(let fourth, let fourthDelay) = await session.step() else {
            Issue.record("expected a normal tick")
            return
        }
        #expect(fourth.isEmpty)
        #expect(fourthDelay == 2)
    }

    // MARK: - 60 s of continuous unreachable

    @Test func sixtySecondsOfContinuousUnreachableEndsAStream() async {
        let requester = FakeMonitorRequester()
        let clock = FakeMonitorClock(start: Self.epoch)
        let cursor = LogCursor(at: Self.epoch, count: 0)
        await requester.enqueueLogs(.success(attachLogsResult(cursor: cursor)))
        await requester.enqueueStatus(.success(ServerListResult(servers: [serverStatus(name: "web", phase: .running, pid: 812)])))
        var session = MonitorSession(client: requester, clock: clock, config: config())
        _ = await session.step()

        await requester.enqueueLogs(.failure(WireError(code: .daemonUnreachable, message: "cannot connect")))
        guard case .events = await session.step() else {
            Issue.record("expected the first unreachable failure to retry, not end")
            return
        }

        await clock.advance(by: 60)
        await requester.enqueueLogs(.failure(WireError(code: .daemonUnreachable, message: "cannot connect")))
        guard case .ended(let events) = await session.step() else {
            Issue.record("expected 60 s of continuous unreachable to end the stream")
            return
        }
        #expect(events.map(\.humanLine) == ["directa web: ended (daemon unreachable for 60s)"])
    }

    @Test func sixtySecondsOfContinuousUnreachableExitsBeforeAttaching() async {
        let requester = FakeMonitorRequester()
        let clock = FakeMonitorClock(start: Self.epoch)
        var session = MonitorSession(client: requester, clock: clock, config: config())

        await requester.enqueueLogs(.failure(WireError(code: .daemonUnreachable, message: "cannot connect")))
        guard case .events = await session.step() else {
            Issue.record("expected the first unreachable failure to retry attaching, not exit")
            return
        }

        await clock.advance(by: 60)
        await requester.enqueueLogs(.failure(WireError(code: .daemonUnreachable, message: "cannot connect")))
        guard case .exit(let error) = await session.step() else {
            Issue.record("expected 60 s of continuous unreachable to give up on attaching")
            return
        }
        #expect(error.code == .daemonUnreachable)
    }

    /** A recovery in between resets the unreachable clock: two 40 s
        stretches of unreachable separated by one success never reach the
        60 s cumulative threshold. */
    @Test func aRecoveryBetweenUnreachableStretchesResetsTheClock() async {
        let requester = FakeMonitorRequester()
        let clock = FakeMonitorClock(start: Self.epoch)
        let cursor = LogCursor(at: Self.epoch, count: 0)
        await requester.enqueueLogs(.success(attachLogsResult(cursor: cursor)))
        await requester.enqueueStatus(.success(ServerListResult(servers: [serverStatus(name: "web", phase: .running, pid: 812)])))
        var session = MonitorSession(client: requester, clock: clock, config: config())
        _ = await session.step()

        await requester.enqueueLogs(.failure(WireError(code: .daemonUnreachable, message: "cannot connect")))
        _ = await session.step()
        await clock.advance(by: 40)

        await requester.enqueueLogs(.success(tickLogsResult(cursor: cursor)))
        guard case .events = await session.step() else {
            Issue.record("expected recovery")
            return
        }
        await clock.advance(by: 1)

        await requester.enqueueLogs(.failure(WireError(code: .daemonUnreachable, message: "cannot connect")))
        _ = await session.step()
        await clock.advance(by: 40)

        await requester.enqueueLogs(.failure(WireError(code: .daemonUnreachable, message: "cannot connect")))
        guard case .events = await session.step() else {
            Issue.record("80 s split across two stretches with a recovery between them must not end the stream")
            return
        }
    }

    // MARK: - Cursor advance and trimmed accounting

    @Test func trimmedIsExactlyTotalsMinusWhatWasReturned() async {
        let requester = FakeMonitorRequester()
        let clock = FakeMonitorClock(start: Self.epoch)
        let attachCursor = LogCursor(at: Self.epoch, count: 0)
        await requester.enqueueLogs(.success(attachLogsResult(cursor: attachCursor)))
        await requester.enqueueStatus(.success(ServerListResult(servers: [serverStatus(name: "web", phase: .running, pid: 812)])))
        var session = MonitorSession(client: requester, clock: clock, config: config())
        _ = await session.step()

        await clock.advance(by: 2)
        let nextCursor = LogCursor(at: Self.epoch.addingTimeInterval(2), count: 1)
        let line = LogRecord(at: Self.epoch.addingTimeInterval(2), stream: .out, text: "hello")
        await requester.enqueueLogs(
            .success(tickLogsResult(cursor: nextCursor, lines: [line], totals: LogStreamCounts(err: 0, mark: 0, out: 301, sys: 0))))
        guard case .events(let events, _) = await session.step() else {
            Issue.record("expected a normal tick")
            return
        }
        /** The daemon matched 301 out records and returned 1: the other 300
            were trimmed by the daemon's own per-tick cap, which reaches this
            stream's shaper as `trimmed`, not silently. */
        #expect(events.map(\.humanLine).contains { $0.contains("300 out lines skipped") })
        #expect(events.map(\.humanLine).contains("web out| hello"))

        /** The next tick's `after` is this tick's returned cursor, not the
            attach cursor: nothing already seen is re-fetched. */
        await clock.advance(by: 2)
        await requester.enqueueLogs(.success(tickLogsResult(cursor: nextCursor)))
        _ = await session.step()
        let paramsSeen = await requester.logsParamsSeen
        #expect(paramsSeen.last?.after == nextCursor)
        #expect(await requester.logsCallCount == 3)
    }
}

/** Every `directa monitor` budget flag validated at the parser boundary,
    the same boundary `TimeoutOption` screens `--timeout` at
    (`TimeoutOptionTests`). */
@Suite struct MonitorFlagOptionTests {
    /** Direct calls to the transform functions, mirroring how
        `TimeoutOptionTests` tests `TimeoutOption.parse` itself: a value
        `Monitor.parse` hands one of these throws the raw `ValidationError`,
        with a message naming the offending value and the accepted range. */
    @Test func everyFlagRejectsBelowItsRange() {
        let low = #expect(throws: ValidationError.self) { try MonitorFlagOption.linesPerMinute("0") }
        #expect(low?.message.contains("between 1 and 1200") == true)
        #expect(throws: ValidationError.self) { try MonitorFlagOption.linesPerArm("0") }
        #expect(throws: ValidationError.self) { try MonitorFlagOption.errorsPerMinute("0") }
        #expect(throws: ValidationError.self) { try MonitorFlagOption.errorsPerArm("0") }
        let tickLow = #expect(throws: ValidationError.self) { try MonitorFlagOption.tick("0.1") }
        #expect(tickLow?.message.contains("between 0.5 and 60") == true)
    }

    @Test func everyFlagRejectsAboveItsRange() {
        #expect(throws: ValidationError.self) { try MonitorFlagOption.linesPerMinute("1201") }
        #expect(throws: ValidationError.self) { try MonitorFlagOption.linesPerArm("20001") }
        #expect(throws: ValidationError.self) { try MonitorFlagOption.errorsPerMinute("601") }
        #expect(throws: ValidationError.self) { try MonitorFlagOption.errorsPerArm("5001") }
        #expect(throws: ValidationError.self) { try MonitorFlagOption.tick("61") }
    }

    @Test func garbageTextIsRejectedForEveryFlag() {
        #expect(throws: ValidationError.self) { try MonitorFlagOption.linesPerMinute("soon") }
        #expect(throws: ValidationError.self) { try MonitorFlagOption.linesPerArm("soon") }
        #expect(throws: ValidationError.self) { try MonitorFlagOption.errorsPerMinute("soon") }
        #expect(throws: ValidationError.self) { try MonitorFlagOption.errorsPerArm("soon") }
        #expect(throws: ValidationError.self) { try MonitorFlagOption.tick("soon") }
        #expect(throws: ValidationError.self) { try MonitorFlagOption.tick("nan") }
    }

    /** Every flag actually routes through its validator at the CLI's own
        parser boundary (not just when called directly): a bad value fails
        `Monitor.parse` itself. `ArgumentParser` wraps the transform's thrown
        `ValidationError` in its own `CommandError`, the same reason
        `TimeoutOptionTests.everyTimeoutOptionRejectsANonFiniteValueAtTheParserBoundary`
        asserts `(any Error).self` rather than `ValidationError.self` here. */
    @Test func everyFlagIsWiredThroughItsValidatorAtTheParserBoundary() {
        #expect(throws: (any Error).self) { try Monitor.parse(["web", "--lines-per-minute", "0"]) }
        #expect(throws: (any Error).self) { try Monitor.parse(["web", "--lines-per-arm", "0"]) }
        #expect(throws: (any Error).self) { try Monitor.parse(["web", "--errors-per-minute", "0"]) }
        #expect(throws: (any Error).self) { try Monitor.parse(["web", "--errors-per-arm", "0"]) }
        #expect(throws: (any Error).self) { try Monitor.parse(["web", "--tick", "0.1"]) }
    }

    @Test func aBoundaryValueOnEachEndOfEveryRangeParses() throws {
        let low = try Monitor.parse([
            "web", "--lines-per-minute", "1", "--lines-per-arm", "1", "--errors-per-minute", "1",
            "--errors-per-arm", "1", "--tick", "0.5",
        ])
        #expect(low.linesPerMinute == 1)
        #expect(low.linesPerArm == 1)
        #expect(low.errorsPerMinute == 1)
        #expect(low.errorsPerArm == 1)
        #expect(low.tick == 0.5)

        let high = try Monitor.parse([
            "web", "--lines-per-minute", "1200", "--lines-per-arm", "20000", "--errors-per-minute", "600",
            "--errors-per-arm", "5000", "--tick", "60",
        ])
        #expect(high.linesPerMinute == 1200)
        #expect(high.linesPerArm == 20000)
        #expect(high.errorsPerMinute == 600)
        #expect(high.errorsPerArm == 5000)
        #expect(high.tick == 60)
    }

    @Test func defaultsMatchMonitorLimits() throws {
        let parsed = try Monitor.parse(["web"])
        #expect(parsed.linesPerMinute == MonitorLimits.linesPerMinuteDefault)
        #expect(parsed.linesPerArm == MonitorLimits.linesPerArmDefault)
        #expect(parsed.errorsPerMinute == MonitorLimits.errorsPerMinuteDefault)
        #expect(parsed.errorsPerArm == MonitorLimits.errorsPerArmDefault)
        #expect(parsed.tick == MonitorLimits.tickDefault)
    }
}

/** Pins the exact NDJSON shape a realistic session emits (attach, a line, a
    graceful end), the same golden discipline `MonitorStreamTests` applies to
    a single event: every new field is caught here as a diff, not silently
    absorbed into a looser assertion. */
@Suite struct MonitorSessionJSONGoldenTests {
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func encodeAsNDJSON(_ events: [MonitorEvent]) throws -> String {
        try events.map { event in
            let data = try JSONCoding.encoder().encode(event)
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n")
    }

    @Test func aRealisticSessionEncodesToStableNDJSON() async throws {
        let requester = FakeMonitorRequester()
        let clock = FakeMonitorClock(start: Self.epoch)
        let attachCursor = LogCursor(at: Self.epoch, count: 0)
        await requester.enqueueLogs(
            .success(LogsQueryResult(cursor: attachCursor, lines: [], totals: LogStreamCounts(err: 0, mark: 0, out: 0, sys: 0))))
        await requester.enqueueStatus(
            .success(
                ServerListResult(servers: [
                    ServerStatus(logPath: "/logs/web/current.log", phase: .running, pid: 812, project: "/tmp/proj", server: "web")
                ])))
        var session = MonitorSession(
            client: requester, clock: clock,
            config: MonitorRunConfig(budgets: .defaults, name: "web", project: "/tmp/proj", tickSeconds: 2))

        guard case .events(let attachEvents, _) = await session.step() else {
            Issue.record("expected the attach marker")
            return
        }

        await clock.advance(by: 2)
        let lineAt = Self.epoch.addingTimeInterval(2)
        await requester.enqueueLogs(
            .success(
                LogsQueryResult(
                    cursor: LogCursor(at: lineAt, count: 1), lines: [LogRecord(at: lineAt, stream: .out, text: "hello")],
                    totals: LogStreamCounts(err: 0, mark: 0, out: 1, sys: 0))))
        guard case .events(let tickEvents, _) = await session.step() else {
            Issue.record("expected a normal tick")
            return
        }

        await clock.advance(by: 2)
        await requester.enqueueLogs(.failure(WireError(code: .notFound, message: "gone")))
        guard case .ended(let endedEvents) = await session.step() else {
            Issue.record("expected a graceful end")
            return
        }

        let ndjson = try encodeAsNDJSON(attachEvents + tickEvents + endedEvents)
        let attachedAtISO = JSONCoding.formatISO8601(Self.epoch)
        let lineAtISO = JSONCoding.formatISO8601(lineAt)
        let endedAtISO = JSONCoding.formatISO8601(Self.epoch.addingTimeInterval(2))
        #expect(
            ndjson == """
                {"at":"\(attachedAtISO)","kind":"attached","label":"web","text":"monitoring /tmp/proj (running, pid=812; budget 120/min and 600/arm, errors 30/min and 300/arm); earlier output: directa logs web --tail 200"}
                {"at":"\(lineAtISO)","kind":"line","label":"web","stream":"out","text":"hello"}
                {"at":"\(endedAtISO)","kind":"ended","label":"web","text":"ended (server unregistered)"}
                """)
    }
}
