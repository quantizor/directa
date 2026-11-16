import Testing

@testable import DirectaKit

@Suite struct StatusFollowPolicyTests {
    typealias Policy = StatusFollowPolicy

    private func step(_ request: Policy.Request, delay: Double = 0) -> Policy.Step {
        Policy.Step(delaySeconds: delay, request: request)
    }

    @Test func sessionStartsByTakingAToken() {
        #expect(Policy.start == step(.takeToken))
    }

    @Test func tokenThenRefreshThenParkWithNoDelay() {
        #expect(Policy.next(after: .takeToken, outcome: .answered) == step(.refresh))
        #expect(Policy.next(after: .refresh, outcome: .answered) == step(.park))
    }

    @Test func parkedWaitThatChangedRefreshesThenParksAgain() {
        #expect(Policy.next(after: .park, outcome: .answered) == step(.refresh))
        #expect(Policy.next(after: .refresh, outcome: .answered) == step(.park))
    }

    @Test func parkedWaitThatTimedOutParksAgainWithoutRefreshing() {
        #expect(Policy.next(after: .park, outcome: .deadline) == step(.park))
    }

    @Test(arguments: [Policy.Outcome.daemonStarting, .unreachable])
    func failureAnywhereInTheLoopWaitsThenRecovers(outcome: Policy.Outcome) {
        for request in [Policy.Request.takeToken, .refresh, .park] {
            #expect(Policy.next(after: request, outcome: outcome) == step(.recover, delay: 2))
        }
    }

    @Test func recoveryRefreshAlwaysLeadsBackToTakingAToken() {
        for outcome in [Policy.Outcome.answered, .deadline, .daemonStarting, .unreachable] {
            #expect(Policy.next(after: .recover, outcome: outcome) == step(.takeToken))
        }
    }

    @Test func unknownMethodStartsPollingAtOnceFromAnyLoopStep() {
        for request in [Policy.Request.takeToken, .refresh, .park, .recover] {
            #expect(Policy.next(after: request, outcome: .unknownMethod) == step(.poll))
        }
    }

    @Test func pollingRefreshesEveryIntervalWhileRequestsSucceed() {
        #expect(Policy.next(after: .poll, outcome: .answered) == step(.poll, delay: 2))
    }

    @Test func aDeadlineWhilePollingIsJustASuccessfulRefresh() {
        #expect(Policy.next(after: .poll, outcome: .deadline) == step(.poll, delay: 2))
    }

    @Test(arguments: [Policy.Outcome.daemonStarting, .unreachable])
    func anyFailureWhilePollingReturnsToTakingAToken(outcome: Policy.Outcome) {
        #expect(Policy.next(after: .poll, outcome: outcome) == step(.takeToken))
    }

    @Test func unknownMethodWhileAlreadyPollingReturnsToTakingAToken() {
        #expect(Policy.next(after: .poll, outcome: .unknownMethod) == step(.takeToken))
    }

    @Test func daemonRestartDuringAParkRecoversThenFollowsAgain() {
        var current = Policy.next(after: .park, outcome: .unreachable)
        #expect(current == step(.recover, delay: 2))
        current = Policy.next(after: current.request, outcome: .answered)
        #expect(current == Policy.start)
    }

    @Test func olderDaemonPollsUntilItRestartsThenFollowsAgain() {
        var current = Policy.next(after: .takeToken, outcome: .unknownMethod)
        #expect(current == step(.poll))
        current = Policy.next(after: current.request, outcome: .answered)
        current = Policy.next(after: current.request, outcome: .answered)
        #expect(current == step(.poll, delay: 2))
        current = Policy.next(after: current.request, outcome: .unreachable)
        #expect(current == Policy.start)
    }

    private static let unknownMethod = WireError(
        code: .usage, message: WireError.unknownMethodMessage(WireMethod.serverAwaitChange.rawValue))

    @Test(arguments: [
        (unknownMethod, Policy.Request.takeToken, Policy.Outcome.unknownMethod),
        (unknownMethod, .park, .unknownMethod),
        (unknownMethod, .poll, .unreachable),
        (WireError(code: .daemonStarting, message: "restoring"), .park, .daemonStarting),
        (WireError(code: .daemonStarting, message: "restoring"), .refresh, .daemonStarting),
        (WireError(code: .usage, message: "bad params"), .park, .unreachable),
        (WireError(code: .daemonUnreachable, message: "closed"), .takeToken, .unreachable),
    ])
    func failureMapsToTheOutcomeThePolicyDrives(
        error: WireError, request: Policy.Request, expected: Policy.Outcome
    ) {
        #expect(Policy.outcome(failure: error, request: request) == expected)
    }

    @Test func nonWireFailureIsUnreachable() {
        #expect(Policy.outcome(failure: CancellationError(), request: .refresh) == .unreachable)
    }
}
