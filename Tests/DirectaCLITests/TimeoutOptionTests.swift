import ArgumentParser
import DirectaKit
import Foundation
import Testing

@testable import directa

/** Every `--timeout`/`--acquire-timeout` value is screened before it reaches
    the daemon, which would otherwise clamp a non-finite or absurd value
    silently (`ServerSupervisor.boundedTimeoutSeconds`; `Duration.seconds`
    itself traps on a non-finite value). A bad value is a `usage` failure
    naming the flag, the value, and the accepted range, delivered through the
    same path as every other usage error so `--json` gets the envelope. */
@Suite struct TimeoutOptionTests {
    private func seconds(_ raw: String, flag: String = "--timeout") -> Result<Double, WireError> {
        TimeoutOption(argument: raw).seconds(flag: flag)
    }

    @Test func aFiniteInRangeValueParses() {
        #expect(seconds("60") == .success(60))
        #expect(seconds("0") == .success(0))
        #expect(seconds("86400") == .success(86400))
        #expect(seconds("0.5") == .success(0.5))
    }

    @Test func infinityIsRejected() {
        #expect(
            seconds("inf")
                == .failure(
                    WireError(code: .usage, message: "--timeout must be a finite number of seconds, got 'inf'")))
    }

    @Test func nanIsRejected() {
        #expect(
            seconds("nan", flag: "--acquire-timeout")
                == .failure(
                    WireError(
                        code: .usage, message: "--acquire-timeout must be a finite number of seconds, got 'nan'")))
    }

    @Test func negativeIsRejected() {
        #expect(
            seconds("-1")
                == .failure(
                    WireError(code: .usage, message: "--timeout must be between 0 and 86400 seconds, got -1")))
    }

    @Test func aboveTheDayLongCapIsRejected() {
        #expect(
            seconds("86401")
                == .failure(
                    WireError(code: .usage, message: "--timeout must be between 0 and 86400 seconds, got 86401")))
    }

    @Test func garbageTextIsRejected() {
        #expect(
            seconds("soon")
                == .failure(WireError(code: .usage, message: "--timeout takes a number of seconds, got 'soon'")))
    }

    /** A bad value must reach the command's own usage failure, which `--json`
        renders as the error envelope on stdout (exit 2), so the parser itself
        accepts it rather than printing its own error and exiting 64. */
    @Test func aBadValueGetsPastTheParserToTheUsageEnvelope() throws {
        _ = try Ensure.parse(["web", "--timeout", "inf", "--json"])
        _ = try Lock.parse(["d1", "--acquire-timeout", "nan", "--", "cmd"])
    }

    /** Every command that takes a timeout carries the raw text to the shared
        screen, so a bad value fails the same way everywhere. */
    @Test func everyTimeoutOptionCarriesABadValueToTheScreen() throws {
        #expect(try Ensure.parse(["web", "--timeout", "inf"]).timeout == TimeoutOption(argument: "inf"))
        #expect(try Wait.parse(["web", "--timeout", "nan"]).timeout == TimeoutOption(argument: "nan"))
        #expect(try Restart.parse(["web", "--timeout", "-1"]).timeout == TimeoutOption(argument: "-1"))
        #expect(try Up.parse(["--timeout", "86401"]).timeout == TimeoutOption(argument: "86401"))
        #expect(try Switch.parse(["main", "--timeout", "inf"]).timeout == TimeoutOption(argument: "inf"))
        let lock = try Lock.parse(["d1", "--timeout", "nan", "--acquire-timeout", "inf", "--", "cmd"])
        #expect(lock.timeout == TimeoutOption(argument: "nan"))
        #expect(lock.acquireTimeout == TimeoutOption(argument: "inf"))
    }

    @Test func everyTimeoutOptionAcceptsAValidValueAndKeepsItsDefault() throws {
        #expect(try Ensure.parse(["web", "--timeout", "30"]).timeout.seconds(flag: "--timeout") == .success(30))
        #expect(try Wait.parse(["web"]).timeout == TimeoutOption(seconds: 60))
        #expect(try Restart.parse(["web"]).timeout == TimeoutOption(seconds: 60))
        #expect(try Up.parse([]).timeout == TimeoutOption(seconds: 60))
        #expect(try Switch.parse(["main"]).timeout == TimeoutOption(seconds: 120))
        let lock = try Lock.parse(["d1", "--", "cmd"])
        #expect(lock.timeout == TimeoutOption(seconds: 120))
        #expect(lock.acquireTimeout == TimeoutOption(seconds: 300))
    }
}
