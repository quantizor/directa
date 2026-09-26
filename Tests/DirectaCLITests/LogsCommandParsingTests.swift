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
}
