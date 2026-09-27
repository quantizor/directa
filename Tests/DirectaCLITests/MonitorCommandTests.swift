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
    private var logsQueue: [Result<LogsQueryResult, any Error>] = []
    private var lastLogs: Result<LogsQueryResult, any Error>?
    private(set) var statusCallCount = 0
    private var statusQueue: [Result<ServerListResult, any Error>] = []
    private var lastStatus: Result<ServerListResult, any Error>?

    func enqueueLogs(_ result: Result<LogsQueryResult, any Error>) {
        logsQueue.append(result)
    }

    func enqueueStatus(_ result: Result<ServerListResult, any Error>) {
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
        LogsQueryResult(cursor: cursor, lines: [], totals: LogStreamTotals(err: 0, mark: 0, out: 0, sys: 0))
    }

    private func tickLogsResult(
        cursor: LogCursor, lines: [LogRecord] = [], totals: LogStreamTotals = LogStreamTotals(err: 0, mark: 0, out: 0, sys: 0)
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

    @Test func featureGateExitsWhenAttachLacksTheCursor() async {
        let requester = FakeMonitorRequester()
        await requester.enqueueLogs(.success(LogsQueryResult(cursor: nil, lines: [], totals: nil)))
        var session = MonitorSession(
            client: requester, clock: FakeMonitorClock(start: Self.epoch), config: config())
        guard case .exit(let error) = await session.step() else {
            Issue.record("expected .exit for a daemon missing cursor")
            return
        }
        #expect(error == Logs.olderDaemon)
    }

    /** Attach asks for the tail fast path (`tail: 0`: the end cursor, no
        scan of the log's history), never a per-stream trim of zero, which
        the daemon answers by reading the whole family forward to count
        totals. */
    @Test func attachQueriesAZeroTailAndNothingElse() async {
        let requester = FakeMonitorRequester()
        await requester.enqueueLogs(.success(LogsQueryResult(cursor: LogCursor(at: Self.epoch, count: 0), lines: [])))
        await requester.enqueueStatus(.success(ServerListResult(servers: [serverStatus(name: "web", phase: .running, pid: 812)])))
        var session = MonitorSession(
            client: requester, clock: FakeMonitorClock(start: Self.epoch), config: config())
        guard case .events = await session.step() else {
            Issue.record("expected the attach marker from a cursor-only answer")
            return
        }
        #expect(await requester.logsParamsSeen == [LogsQueryParams(name: "web", project: "/tmp/proj", tail: 0)])
    }

    /** `totals` is gated on the first tick, the first query shaped to carry
        it: a daemon that answers without it ends the run with the same
        version-mismatch message and exit status the attach gate uses. */
    @Test func aFirstTickWithoutTotalsEndsTheRunAsAVersionMismatch() async {
        let requester = FakeMonitorRequester()
        let clock = FakeMonitorClock(start: Self.epoch)
        let cursor = LogCursor(at: Self.epoch, count: 0)
        await requester.enqueueLogs(.success(LogsQueryResult(cursor: cursor, lines: [])))
        await requester.enqueueStatus(.success(ServerListResult(servers: [serverStatus(name: "web", phase: .running, pid: 812)])))
        var session = MonitorSession(client: requester, clock: clock, config: config())
        _ = await session.step()

        await clock.advance(by: 2)
        await requester.enqueueLogs(.success(LogsQueryResult(cursor: cursor, lines: [], totals: nil)))
        guard case .endedWithError(let events, let error) = await session.step() else {
            Issue.record("expected the run to end on a tick without totals")
            return
        }
        #expect(error == Logs.olderDaemon)
        #expect(events.map(\.humanLine) == [
            "directa web: ended (the daemon is older than this CLI and cannot answer this command; run: directa daemon restart)"
        ])
        #expect(CLIRunner.exitStatus(for: error.code) == 3)
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

    // MARK: - Errors that are not transient

    private let refusal = WireError(
        code: .notTrusted, hint: "run: directa trust", message: "this project's config is not trusted")

    private func attachedSession(
        _ requester: FakeMonitorRequester, clock: FakeMonitorClock, cursor: LogCursor = LogCursor(at: epoch, count: 0)
    ) async -> MonitorSession {
        await requester.enqueueLogs(.success(attachLogsResult(cursor: cursor)))
        await requester.enqueueStatus(.success(ServerListResult(servers: [serverStatus(name: "web", phase: .running, pid: 812)])))
        var session = MonitorSession(client: requester, clock: clock, config: config())
        guard case .events = await session.step() else {
            Issue.record("expected the attach marker")
            return session
        }
        return session
    }

    /** Only an unreachable, starting, or config-invalid daemon is a state
        to wait out; any other refusal before attaching exits through
        `CLIRunner.fail` with the daemon's own error. */
    @Test func aRefusalBeforeAttachingExitsWithTheDaemonsError() async {
        let requester = FakeMonitorRequester()
        await requester.enqueueLogs(.failure(refusal))
        var session = MonitorSession(
            client: requester, clock: FakeMonitorClock(start: Self.epoch), config: config())
        guard case .exit(let error) = await session.step() else {
            Issue.record("expected .exit for a refusal that is not transient")
            return
        }
        #expect(error == refusal)
    }

    /** After attaching, the same refusal ends the stream with a line naming
        the message and its fix, and the process exits with the status
        `CLIRunner` maps the code to. */
    @Test func aRefusalAfterAttachingEndsTheRunNamingTheMessage() async {
        let requester = FakeMonitorRequester()
        let clock = FakeMonitorClock(start: Self.epoch)
        var session = await attachedSession(requester, clock: clock)
        await clock.advance(by: 2)
        await requester.enqueueLogs(.failure(refusal))
        guard case .endedWithError(let events, let error) = await session.step() else {
            Issue.record("expected the run to end on a refusal")
            return
        }
        #expect(error == refusal)
        #expect(events.map(\.humanLine) == ["directa web: ended (this project's config is not trusted; run: directa trust)"])
        #expect(CLIRunner.exitStatus(for: error.code) == 1)
    }

    private struct GarbledFrame: Error, CustomStringConvertible {
        var description: String { "unexpected end of frame" }
    }

    /** An answer that does not decode is reported once, then shares the
        unreachable clock: 60 s of it ends the run. */
    @Test func anUnreadableAnswerIsReportedOnceAndCountsTowardTheGiveUp() async {
        let requester = FakeMonitorRequester()
        let clock = FakeMonitorClock(start: Self.epoch)
        var session = await attachedSession(requester, clock: clock)

        await requester.enqueueLogs(.failure(GarbledFrame()))
        guard case .events(let first, _) = await session.step() else {
            Issue.record("expected a transient tick")
            return
        }
        #expect(first.map(\.humanLine) == [
            "directa web: the daemon's answer could not be read (unexpected end of frame), retrying"
        ])

        await clock.advance(by: 30)
        guard case .events(let second, _) = await session.step() else {
            Issue.record("expected a second transient tick")
            return
        }
        #expect(second.isEmpty)

        await clock.advance(by: 30)
        guard case .ended(let events) = await session.step() else {
            Issue.record("expected 60 s of unreadable answers to end the stream")
            return
        }
        #expect(events.map(\.humanLine) == ["directa web: ended (daemon answers unreadable for 60s)"])
    }

    @Test func anUnreadableAnswerBeforeAttachingGivesUpAfterSixtySeconds() async {
        let requester = FakeMonitorRequester()
        let clock = FakeMonitorClock(start: Self.epoch)
        var session = MonitorSession(client: requester, clock: clock, config: config())
        await requester.enqueueLogs(.failure(GarbledFrame()))
        guard case .events(let first, _) = await session.step() else {
            Issue.record("expected the first unreadable answer to retry attaching")
            return
        }
        #expect(first.map(\.humanLine) == [
            "directa web: the daemon's answer could not be read (unexpected end of frame), retrying"
        ])
        await clock.advance(by: 60)
        guard case .exit(let error) = await session.step() else {
            Issue.record("expected 60 s of unreadable answers to give up on attaching")
            return
        }
        #expect(
            error
                == WireError(
                    code: .internalError, hint: "run: directa daemon restart",
                    message: "the daemon's answers could not be read for 60s: unexpected end of frame"))
    }

    // MARK: - The 29-minute cap

    /** The cap reads past the cursor once more and shows what arrived since
        the last tick before its end marker, whose command starts at the
        final cursor. */
    @Test func theHardCapDrainsOnceMoreAndNamesTheFinalCursor() async {
        let requester = FakeMonitorRequester()
        let clock = FakeMonitorClock(start: Self.epoch)
        let attachCursor = LogCursor(at: Self.epoch, count: 0)
        var session = await attachedSession(requester, clock: clock, cursor: attachCursor)

        await clock.advance(by: MonitorLimits.hardCapSeconds)
        let lineAt = Self.epoch.addingTimeInterval(1_739.5)
        await requester.enqueueLogs(
            .success(
                tickLogsResult(
                    cursor: LogCursor(at: lineAt, count: 1), lines: [LogRecord(at: lineAt, stream: .out, text: "last words")],
                    totals: LogStreamTotals(err: 0, mark: 0, out: 1, sys: 0))))
        guard case .ended(let events) = await session.step() else {
            Issue.record("expected the hard cap to end the run")
            return
        }
        #expect(events.map(\.humanLine) == [
            "web out| last words",
            "directa web: ended after 29 minutes; run the same command again to keep watching; "
                + "anything after this: directa logs web --since \(JSONCoding.formatISO8601(lineAt)) --head 200",
        ])
        #expect(await requester.logsParamsSeen.last?.after == attachCursor)
    }

    /** A drain that fails still ends the run, naming the cursor it held. */
    @Test func theHardCapEndsOnTheHeldCursorWhenTheDrainFails() async {
        let requester = FakeMonitorRequester()
        let clock = FakeMonitorClock(start: Self.epoch)
        let attachCursor = LogCursor(at: Self.epoch.addingTimeInterval(0.25), count: 3)
        var session = await attachedSession(requester, clock: clock, cursor: attachCursor)

        await clock.advance(by: MonitorLimits.hardCapSeconds)
        await requester.enqueueLogs(.failure(WireError(code: .daemonUnreachable, message: "cannot connect")))
        guard case .ended(let events) = await session.step() else {
            Issue.record("expected the hard cap to end the run")
            return
        }
        #expect(events.map(\.humanLine) == [
            "directa web: ended after 29 minutes; run the same command again to keep watching; "
                + "anything after this: directa logs web --since \(JSONCoding.formatISO8601(attachCursor.at)) --head 200"
        ])
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
            .success(tickLogsResult(cursor: nextCursor, lines: [line], totals: LogStreamTotals(err: 0, mark: 0, out: 301, sys: 0))))
        guard case .events(let events, _) = await session.step() else {
            Issue.record("expected a normal tick")
            return
        }
        /** The daemon matched 301 out records and returned 1: the other 300
            were trimmed by the daemon's own per-tick cap, which reaches this
            stream's shaper as `trimmed`, not silently. */
        #expect(events.map(\.humanLine).contains { $0.contains("300 out lines skipped") })
        #expect(events.map(\.humanLine).contains("web out| hello"))
        #expect(await requester.logsParamsSeen.last?.tailByStream == LogStreamCounts(err: 300, mark: 50, out: 300, sys: 50))

        /** The next tick's `after` is this tick's returned cursor, not the
            attach cursor: nothing already seen is re-fetched. */
        await clock.advance(by: 2)
        await requester.enqueueLogs(.success(tickLogsResult(cursor: nextCursor)))
        _ = await session.step()
        let paramsSeen = await requester.logsParamsSeen
        #expect(paramsSeen.last?.after == nextCursor)
        #expect(await requester.logsCallCount == 3)
    }

    /** Lifecycle lines past the per-tick sys cap are counted from `totals`
        like out and err, and reach the stream as a named skip, never a
        silent loss. */
    @Test func aSysTrimReachesTheStreamAsASkippedMarker() async {
        let requester = FakeMonitorRequester()
        let clock = FakeMonitorClock(start: Self.epoch)
        var session = await attachedSession(requester, clock: clock)

        await clock.advance(by: 2)
        let lines = (0..<50).map { LogRecord(at: Self.epoch.addingTimeInterval(1), stream: .sys, text: "started pid=\($0)") }
        await requester.enqueueLogs(
            .success(
                tickLogsResult(
                    cursor: LogCursor(at: Self.epoch.addingTimeInterval(1), count: 50), lines: lines,
                    totals: LogStreamTotals(err: 0, mark: 0, out: 0, sys: 53))))
        guard case .events(let events, _) = await session.step() else {
            Issue.record("expected a normal tick")
            return
        }
        #expect(
            events.first?.humanLine
                == "directa web: 3 sys lines skipped (more than 50 in one tick); read them: "
                + "directa logs web --since \(JSONCoding.formatISO8601(Self.epoch)) --stream sys --head 200")
        #expect(events.count == 51)
    }
}

/** Every `directa monitor` budget flag validated at the parser boundary. */
@Suite struct MonitorFlagOptionTests {
    /** Direct calls to the transform functions: a value `Monitor.parse`
        hands one of these throws the raw `ValidationError`, with a message
        naming the offending value and the accepted range. */
    private static let lineRanges = [
        MonitorLimits.errorsPerArmRange, MonitorLimits.errorsPerMinuteRange, MonitorLimits.linesPerArmRange,
        MonitorLimits.linesPerMinuteRange,
    ]

    @Test func everyFlagRejectsBelowItsRange() {
        let low = #expect(throws: ValidationError.self) {
            try MonitorFlagOption.lines(in: MonitorLimits.linesPerMinuteRange)("0")
        }
        #expect(low?.message == "must be between 1 and 1200, got 0")
        for range in Self.lineRanges {
            #expect(throws: ValidationError.self) { try MonitorFlagOption.lines(in: range)(String(range.lowerBound - 1)) }
        }
        let tickLow = #expect(throws: ValidationError.self) { try MonitorFlagOption.tick("0.1") }
        #expect(tickLow?.message == "must be between 0.5 and 60 seconds, got 0.1")
    }

    @Test func everyFlagRejectsAboveItsRange() {
        for range in Self.lineRanges {
            #expect(throws: ValidationError.self) { try MonitorFlagOption.lines(in: range)(String(range.upperBound + 1)) }
        }
        #expect(throws: ValidationError.self) { try MonitorFlagOption.tick("61") }
    }

    @Test func garbageTextIsRejectedForEveryFlag() {
        for range in Self.lineRanges {
            #expect(throws: ValidationError.self) { try MonitorFlagOption.lines(in: range)("soon") }
        }
        #expect(throws: ValidationError.self) { try MonitorFlagOption.tick("soon") }
        #expect(throws: ValidationError.self) { try MonitorFlagOption.tick("nan") }
    }

    @Test func rangeTextReadsLikeTheHelp() {
        #expect(MonitorFlagOption.rangeText(MonitorLimits.linesPerArmRange) == "1-20000")
        #expect(MonitorFlagOption.rangeText(MonitorLimits.tickRange) == "0.5-60")
    }

    /** Every flag actually routes through its validator at the CLI's own
        parser boundary (not just when called directly): a bad value fails
        `Monitor.parse` itself. `ArgumentParser` wraps the transform's thrown
        `ValidationError` in its own `CommandError`, so this asserts
        `(any Error).self` rather than `ValidationError.self`. */
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
            .success(LogsQueryResult(cursor: attachCursor, lines: [], totals: LogStreamTotals(err: 0, mark: 0, out: 0, sys: 0))))
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
                    totals: LogStreamTotals(err: 0, mark: 0, out: 1, sys: 0))))
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

/** Which signal ends a monitor run, and the fallback when the preferred
    signal's registration fails. */
@Suite struct MonitorLifetimeTests {
    @Test func aStreamStdoutIsWatchedForItsReaderLeaving() {
        #expect(
            MonitorLifetime.choose(
                claudePID: 4242, parentPID: 500, registerProcessExit: { _ in 7 }, registerStdoutEOF: { 9 },
                stdoutIsStream: true)
                == .stdoutEOF(kqueue: 9))
    }

    @Test func aFileOrTerminalStdoutWatchesClaudePID() {
        #expect(
            MonitorLifetime.choose(
                claudePID: 4242, parentPID: 500, registerProcessExit: { $0 == 4242 ? 7 : 8 },
                registerStdoutEOF: { 9 }, stdoutIsStream: false)
                == .processExit(kqueue: 7))
    }

    /** With no `CLAUDE_PID`, or one the kernel refuses (the process is
        already gone), the parent's own exit is the signal, and a stdout
        watch that will not register falls through the same way. */
    @Test func withoutAUsableClaudePIDTheParentsExitIsWatched() {
        let parentOnly: (pid_t) -> Int32? = { $0 == 500 ? 11 : nil }
        #expect(
            MonitorLifetime.choose(
                claudePID: nil, parentPID: 500, registerProcessExit: parentOnly, registerStdoutEOF: { 9 },
                stdoutIsStream: false)
                == .parentExit(kqueue: 11, parent: 500))
        #expect(
            MonitorLifetime.choose(
                claudePID: 4242, parentPID: 500, registerProcessExit: parentOnly, registerStdoutEOF: { 9 },
                stdoutIsStream: false)
                == .parentExit(kqueue: 11, parent: 500))
        #expect(
            MonitorLifetime.choose(
                claudePID: nil, parentPID: 500, registerProcessExit: parentOnly, registerStdoutEOF: { nil },
                stdoutIsStream: true)
                == .parentExit(kqueue: 11, parent: 500))
        #expect(
            MonitorLifetime.choose(
                claudePID: 4242, parentPID: 500, registerProcessExit: { _ in 7 }, registerStdoutEOF: { nil },
                stdoutIsStream: true)
                == .processExit(kqueue: 7))
    }

    /** The poll is the last resort: every registration refused, or a
        parent that is launchd itself (already orphaned), whose exit would
        never come. */
    @Test func thePollIsTheLastResort() {
        #expect(
            MonitorLifetime.choose(
                claudePID: 4242, parentPID: 500, registerProcessExit: { _ in nil }, registerStdoutEOF: { nil },
                stdoutIsStream: true)
                == .parentChange(from: 500))
        #expect(
            MonitorLifetime.choose(
                claudePID: nil, parentPID: 1, registerProcessExit: { _ in 11 }, registerStdoutEOF: { 9 },
                stdoutIsStream: false)
                == .parentChange(from: 1))
    }

    @Test func registeringAnExitedProcessFailsAndALiveOneSucceeds() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        #expect(MonitorLifetime.registerProcessExit(process.processIdentifier) == nil)

        let live = try #require(MonitorLifetime.registerProcessExit(getpid()))
        close(live)

        let parent = try #require(MonitorLifetime.registerProcessExit(getppid()))
        close(parent)
    }
}
