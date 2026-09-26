import ArgumentParser
import DirectaKit
import Foundation
import Testing

@testable import directa

/** Every `--timeout`/`--acquire-timeout` option used to accept anything
    `Double.init?(String)` would parse, including `inf` and `nan`, and hand it
    straight to the daemon, which clamps a non-finite or absurd value silently
    (`ServerSupervisor.boundedTimeoutSeconds`; `Duration.seconds` itself traps
    on a non-finite value). Screening at the argument-parser boundary tells the
    caller their input was nonsense instead of quietly doing something else. */
@Suite struct TimeoutOptionTests {
    @Test func aFiniteInRangeValueParses() throws {
        #expect(try TimeoutOption.parse("60") == 60)
        #expect(try TimeoutOption.parse("0") == 0)
        #expect(try TimeoutOption.parse("86400") == 86400)
    }

    @Test func infinityIsRejected() {
        #expect(throws: ValidationError.self) { try TimeoutOption.parse("inf") }
    }

    @Test func nanIsRejected() {
        #expect(throws: ValidationError.self) { try TimeoutOption.parse("nan") }
    }

    @Test func negativeIsRejected() {
        let error = #expect(throws: ValidationError.self) { try TimeoutOption.parse("-1") }
        #expect(error?.message.contains("-1") == true)
        #expect(error?.message.contains("between 0 and 86400") == true)
    }

    @Test func aboveTheDayLongCapIsRejected() {
        #expect(throws: ValidationError.self) { try TimeoutOption.parse("86401") }
    }

    @Test func garbageTextIsRejected() {
        #expect(throws: ValidationError.self) { try TimeoutOption.parse("soon") }
    }

    /** Every command that takes a timeout routes its option through the shared
        validator, so a bad value fails at parse time with the same message
        rather than reaching the daemon. */
    @Test func everyTimeoutOptionRejectsANonFiniteValueAtTheParserBoundary() {
        #expect(throws: (any Error).self) { try Ensure.parse(["web", "--timeout", "inf"]) }
        #expect(throws: (any Error).self) { try Wait.parse(["web", "--timeout", "nan"]) }
        #expect(throws: (any Error).self) { try Restart.parse(["web", "--timeout", "-1"]) }
        #expect(throws: (any Error).self) { try Up.parse(["--timeout", "86401"]) }
        #expect(throws: (any Error).self) { try Switch.parse(["main", "--timeout", "inf"]) }
        #expect(throws: (any Error).self) { try Lock.parse(["d1", "--timeout", "nan", "--", "cmd"]) }
        #expect(
            throws: (any Error).self
        ) { try Lock.parse(["d1", "--acquire-timeout", "inf", "--", "cmd"]) }
    }

    @Test func everyTimeoutOptionAcceptsAValidValue() throws {
        #expect(try Ensure.parse(["web", "--timeout", "30"]).timeout == 30)
        #expect(try Wait.parse(["web", "--timeout", "30"]).timeout == 30)
        #expect(try Restart.parse(["web", "--timeout", "30"]).timeout == 30)
        #expect(try Up.parse(["--timeout", "30"]).timeout == 30)
        #expect(try Switch.parse(["main", "--timeout", "30"]).timeout == 30)
        let lock = try Lock.parse(["d1", "--timeout", "30", "--acquire-timeout", "45", "--", "cmd"])
        #expect(lock.timeout == 30)
        #expect(lock.acquireTimeout == 45)
    }
}
