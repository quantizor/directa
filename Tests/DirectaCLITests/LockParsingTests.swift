import ArgumentParser
import DirectaKit
import Foundation
import Testing

@testable import directa

/** `directa lock <resource> --timeout 300 -- cmd` ran `env --timeout 300 -- cmd`
    and died with `env: illegal option -- t`. In swift-argument-parser,
    `.captureForPassthrough` ends the option loop at the first positional value,
    so the resource itself stopped option parsing and everything after it joined
    the guarded command. Declaration order cannot fix that; `.postTerminator`
    can, because it lifts everything after `--` before any positional is filled. */
@Suite struct LockParsingTests {
    @Test func optionsBeforeTheTerminatorReachTheirProperties() throws {
        let lock = try Lock.parse([
            "d1", "--acquire-timeout", "5", "--timeout", "300", "--", "somecmd",
        ])
        #expect(lock.resource == "d1")
        #expect(lock.acquireTimeout == 5)
        #expect(lock.timeout == 300)
        #expect(lock.command == ["somecmd"])
    }

    @Test func pauseIsAFlagRatherThanAScrapedToken() throws {
        let after = try Lock.parse(["d1", "--pause", "--", "cmd"])
        #expect(after.pause)
        #expect(after.command == ["cmd"])
        let before = try Lock.parse(["--pause", "d1", "--", "cmd"])
        #expect(before.pause)
        #expect(before.command == ["cmd"])
    }

    /** The default leaves declaring servers running. */
    @Test func pauseDefaultsOff() throws {
        #expect(try Lock.parse(["d1", "--", "cmd"]).pause == false)
    }

    /** Everything after the terminator is a value, so a nested `--`, a dash
        option, and an empty string all survive untouched. */
    @Test func theGuardedCommandIsCapturedVerbatim() throws {
        let lock = try Lock.parse([
            "d1", "--", "git", "--", "path", "-x", "--json", "",
        ])
        #expect(lock.command == ["git", "--", "path", "-x", "--json", ""])
    }

    @Test func aMissingTerminatorIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try Lock.parse(["d1", "somecmd"])
        }
    }

    @Test func anUnknownOptionIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try Lock.parse(["d1", "--typo", "--", "cmd"])
        }
    }

    /** The contract documents the terminator, and the help had never shown it. */
    @Test func helpShowsTheTerminatorAndEveryOption() {
        let help = Lock.helpMessage()
        #expect(help.contains("--"))
        #expect(help.contains("--acquire-timeout"))
        #expect(help.contains("--pause"))
        #expect(help.contains("--timeout"))
    }

    @Test func anEmptyCommandProducesTheTypedUsageError() throws {
        let lock = try Lock.parse(["d1", "--"])
        #expect(lock.command.isEmpty)
        let error = try #require(Lock.usageError(command: lock.command, resource: lock.resource))
        #expect(error.code == .usage)
        #expect(error.hint == "directa lock d1 -- <command>")
        #expect(error.message.contains("needs a command after `--`"))
    }

    @Test func aPresentCommandProducesNoUsageError() {
        #expect(Lock.usageError(command: ["true"], resource: "d1") == nil)
    }
}
