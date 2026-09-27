import ArgumentParser
import DirectaKit
import Foundation
import Testing

@testable import directa

/** `directa events --tail` with a negative count is refused client-side,
    before the request ever reaches the daemon, which refuses the same
    value as a wire-level `EventsQueryParams.refusal()`. */
@Suite struct EventsCommandParsingTests {
    @Test func negativeTailIsAUsageError() throws {
        let error = try #require(Events.usageError(tail: -1))
        #expect(error.code == .usage)
        #expect(error.message == "--tail takes 0 or more events, got -1")
    }

    @Test func nonNegativeTailIsNotAUsageError() {
        #expect(Events.usageError(tail: 0) == nil)
        #expect(Events.usageError(tail: 5) == nil)
        #expect(Events.usageError(tail: nil) == nil)
    }

    @Test func aBadValueGetsPastTheParserToTheUsageEnvelope() throws {
        #expect(try Events.parse(["--tail", "-1"]).tail == -1)
    }
}
