import ArgumentParser
import DirectaKit
import Foundation
import Testing

@testable import directa

/** `directa logs <name>` with none of `--tail`/`--since`/`--since-mark`/
    `--follow` used to answer with the server's whole log history: every line
    since it was first supervised. `effectiveTail` is the one place that
    decides the bound actually sent to the daemon, so it is asserted directly
    rather than through a live request. */
@Suite struct LogsCommandParsingTests {
    @Test func noBoundFlagsDefaultToTheBoundedTail() {
        #expect(
            Logs.effectiveTail(all: false, follow: false, since: nil, sinceMark: nil, tail: nil)
                == Logs.defaultTailLines)
    }

    @Test func allProducesNoTail() {
        #expect(Logs.effectiveTail(all: true, follow: false, since: nil, sinceMark: nil, tail: nil) == nil)
    }

    /** `--all` still means the whole history even under `--follow`: the two
        default rules (`--follow`'s smaller backlog, `--all`'s "everything")
        would otherwise silently pick a winner with no flag telling you which. */
    @Test func allWinsOverFollowsOwnDefault() {
        #expect(Logs.effectiveTail(all: true, follow: true, since: nil, sinceMark: nil, tail: nil) == nil)
    }

    @Test func allWithTailIsAUsageError() throws {
        let error = try #require(Logs.usageError(all: true, tail: 5))
        #expect(error.code == .usage)
        #expect(error.message == "pass --tail or --all, not both")
    }

    @Test func tailAloneIsNotAUsageError() {
        #expect(Logs.usageError(all: false, tail: 5) == nil)
    }

    @Test func allAloneIsNotAUsageError() {
        #expect(Logs.usageError(all: true, tail: nil) == nil)
    }

    /** `--since` already scopes the answer to a time window, which is not the
        unbounded-by-default bug this tail bound fixes, so a bare `--since`
        keeps its historical no-tail behavior rather than gaining an implicit
        200-line cap on top of the time window. */
    @Test func sinceAloneStillHasNoImplicitTail() {
        #expect(
            Logs.effectiveTail(all: false, follow: false, since: Date(), sinceMark: nil, tail: nil) == nil)
    }

    @Test func sinceMarkAloneStillHasNoImplicitTail() {
        #expect(
            Logs.effectiveTail(all: false, follow: false, since: nil, sinceMark: "m1", tail: nil) == nil)
    }

    /** `--all` combined with `--since`/`--since-mark` is a no-op on the tail
        (both already produce nil on their own) but must not be rejected as a
        usage error the way `--all --tail` is. */
    @Test func allWithSinceIsNotAUsageError() {
        #expect(
            Logs.effectiveTail(all: true, follow: false, since: Date(), sinceMark: nil, tail: nil) == nil)
    }

    @Test func explicitTailIsUnchanged() {
        #expect(Logs.effectiveTail(all: false, follow: false, since: nil, sinceMark: nil, tail: 5) == 5)
    }

    /** `--follow` with no other bound keeps its own smaller pre-existing
        default rather than switching to `defaultTailLines`: it was already
        bounded before this change, so it is not the bug being fixed. */
    @Test func followAloneKeepsItsOwnSmallerDefault() {
        #expect(
            Logs.effectiveTail(all: false, follow: true, since: nil, sinceMark: nil, tail: nil)
                == Logs.followDefaultTailLines)
    }

    @Test func followWithExplicitTailKeepsTheExplicitValue() {
        #expect(Logs.effectiveTail(all: false, follow: true, since: nil, sinceMark: nil, tail: 5) == 5)
    }

    @Test func allFlagParsesFromArguments() throws {
        let logs = try Logs.parse(["web", "--all"])
        #expect(logs.all)
        #expect(logs.tail == nil)
    }

    @Test func tailFlagParsesUnchanged() throws {
        let logs = try Logs.parse(["web", "--tail", "5"])
        #expect(!logs.all)
        #expect(logs.tail == 5)
    }

    @Test func headParsesAndSuppressesTheImplicitTail() throws {
        let logs = try Logs.parse(["web", "--since", "2026-09-26T05:31:12.604Z", "--head", "200"])
        #expect(logs.head == 200)
        #expect(
            Logs.effectiveTail(all: false, follow: false, head: 200, since: Date(), sinceMark: nil, tail: nil)
                == nil)
        #expect(Logs.effectiveTail(all: false, follow: false, head: 5, since: nil, sinceMark: nil, tail: nil) == nil)
    }

    @Test func headConflictsWithEveryOtherAmountAndWithFollow() throws {
        #expect(
            Logs.usageError(all: false, follow: false, head: 5, tail: 5)?.message == "pass --head or --tail, not both")
        #expect(
            Logs.usageError(all: true, follow: false, head: 5, tail: nil)?.message == "pass --head or --all, not both")
        #expect(
            Logs.usageError(all: false, follow: true, head: 5, tail: nil)?.message
                == "pass --head or --follow, not both")
        #expect(
            Logs.usageError(all: false, follow: false, head: -1, tail: nil)?.message
                == "--head takes 0 or more lines, got -1")
        #expect(Logs.usageError(all: false, follow: false, head: 5, tail: nil) == nil)
        #expect(Logs.usageError(all: false, follow: true, head: nil, tail: 5) == nil)
        #expect(Logs.usageError(all: true, follow: false, head: nil, tail: 5)?.code == .usage)
    }

    /** An empty first answer still carries the daemon's cursor, and every
        later poll reads only past it: no `since` (which would re-read from
        the start when it is nil), no tail, no mark. */
    @Test func followPollsPastTheDaemonsCursorEvenAfterAnEmptyFirstQuery() {
        let first = LogsQueryParams(
            grep: "err", name: "web", project: "/p", since: Date(timeIntervalSince1970: 5), sinceMark: "m1",
            streams: [.err], tail: 50)
        let cursor = LogCursor(at: Date(timeIntervalSince1970: 9), count: 61)
        #expect(
            Logs.followParams(first, after: cursor)
                == LogsQueryParams(after: cursor, grep: "err", name: "web", project: "/p", streams: [.err]))
        #expect(Logs.followParams(first, after: cursor).refusal() == nil)
    }

    @Test func theMonitorHintAppearsOnlyInClaudeCodeWithAPipedStdout() {
        let hint =
            "directa: to stream a server's output into this session, run directa monitor <name> with the Monitor tool"
        #expect(Logs.monitorHint(environment: ["CLAUDECODE": "1"], stdoutIsTerminal: false) == hint)
        #expect(Logs.monitorHint(environment: ["CLAUDECODE": "1"], stdoutIsTerminal: true) == nil)
        #expect(Logs.monitorHint(environment: [:], stdoutIsTerminal: false) == nil)
        #expect(Logs.monitorHint(environment: ["CLAUDECODE": "0"], stdoutIsTerminal: false) == nil)
    }

    @Test func aCursorlessResultReadsAsAnOlderDaemon() {
        #expect(
            Logs.olderDaemon
                == WireError(
                    code: .versionMismatch, hint: "run: directa daemon restart",
                    message: "the daemon is older than this CLI and cannot answer this command"))
    }
}
