import Foundation
import Testing

@testable import DirectaKit

@Suite struct MissingProjectPolicyTests {
    private let interval = 30.0
    private let start = Date(timeIntervalSince1970: 1_752_868_000)

    @Test func aPresentPathIsNeverForgotten() {
        #expect(
            MissingProjectPolicy.decide(
                exists: true, firstMissedAt: nil, now: start, sweepIntervalSeconds: interval)
                == .present)
        /** Present clears an earlier miss too, regardless of how long ago it
            started: the caller reads `.present` as "drop the record". */
        #expect(
            MissingProjectPolicy.decide(
                exists: true, firstMissedAt: start.addingTimeInterval(-1000), now: start,
                sweepIntervalSeconds: interval) == .present)
    }

    @Test func aFirstMissWaitsRatherThanForgetting() {
        #expect(
            MissingProjectPolicy.decide(
                exists: false, firstMissedAt: nil, now: start, sweepIntervalSeconds: interval)
                == .waiting(since: start))
    }

    @Test func aSecondMissInsideTheIntervalStillWaits() {
        let firstMiss = start
        let secondCheck = start.addingTimeInterval(interval - 1)
        #expect(
            MissingProjectPolicy.decide(
                exists: false, firstMissedAt: firstMiss, now: secondCheck,
                sweepIntervalSeconds: interval) == .waiting(since: firstMiss))
    }

    @Test func missingForExactlyTheIntervalForgets() {
        let firstMiss = start
        let checkAtInterval = start.addingTimeInterval(interval)
        #expect(
            MissingProjectPolicy.decide(
                exists: false, firstMissedAt: firstMiss, now: checkAtInterval,
                sweepIntervalSeconds: interval) == .forget)
    }

    @Test func missingWellPastTheIntervalForgets() {
        let firstMiss = start
        let muchLater = start.addingTimeInterval(interval * 10)
        #expect(
            MissingProjectPolicy.decide(
                exists: false, firstMissedAt: firstMiss, now: muchLater,
                sweepIntervalSeconds: interval) == .forget)
    }
}
