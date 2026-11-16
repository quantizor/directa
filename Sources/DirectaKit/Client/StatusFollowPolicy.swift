import Foundation

/** How the app follows daemon status: a change token first, a status read,
    then a daemon-held wait on that token (`server.awaitChange`), reading again
    only when the wait reports a change. Pure: the caller performs each
    request, reports its outcome, and sleeps the returned delay.

    ```
    takeToken -> refresh -> park -> (changed) refresh -> park
                                       park -> (deadline) park
    any failure -> recover (delay, refresh) -> takeToken
    unknown method -> poll (refresh every interval) -> (any failure) takeToken
    ```
    */
public enum StatusFollowPolicy {
    /** The request the caller performs next. */
    public enum Request: Equatable, Sendable {
        /** `server.awaitChange` with no token: answers at once with the current one. */
        case takeToken
        /** `server.status` plus events, after a token was taken or a park reported a change. */
        case refresh
        /** `server.awaitChange` with the held token and `parkTimeoutSeconds`. */
        case park
        /** A refresh whose answer is ignored: its failure path drives
            `DaemonRecoveryPolicy`, its success proves the daemon is back. */
        case recover
        /** A refresh on an older daemon that cannot park. */
        case poll
    }

    /** What happened to the request. */
    public enum Outcome: Equatable, Sendable {
        /** The request succeeded: a token, a status read, or a park that reported a change. */
        case answered
        /** A park timed out with no change (`changed: false`). */
        case deadline
        /** Refused `daemon-starting` while the daemon restores. */
        case daemonStarting
        /** Any transport error or other failure. */
        case unreachable
        /** The daemon refused `server.awaitChange` as unknown (`WireError.isUnknownMethod`). */
        case unknownMethod
    }

    public struct Step: Equatable, Sendable {
        /** Seconds to sleep before sending `request`. */
        public let delaySeconds: Double
        public let request: Request

        public init(delaySeconds: Double = 0, request: Request) {
            self.delaySeconds = delaySeconds
            self.request = request
        }
    }

    public static let parkTimeoutSeconds = 25.0
    public static let pollIntervalSeconds = 2.0
    public static let retryDelaySeconds = 2.0
    private static let responseSlackSeconds = 15.0
    /** The park's own deadline plus slack, so a healthy park is never cut off by the socket's receive timeout. */
    public static let responseTimeoutSeconds = parkTimeoutSeconds + responseSlackSeconds

    /** The first step of every follow session, and of every restart of one. */
    public static let start = Step(request: .takeToken)

    /** The outcome a failed request reports: `server.awaitChange` refused as an unknown method
        is `unknownMethod`, a `daemon-starting` refusal is `daemonStarting`, anything else `unreachable`. */
    public static func outcome(failure error: Error, request: Request) -> Outcome {
        guard let wire = error as? WireError else { return .unreachable }
        if wire.code == .daemonStarting { return .daemonStarting }
        let followsToken = request == .takeToken || request == .park
        return followsToken && wire.isUnknownMethod(.serverAwaitChange) ? .unknownMethod : .unreachable
    }

    public static func next(after request: Request, outcome: Outcome) -> Step {
        switch outcome {
        case .daemonStarting, .unreachable:
            return failed(request)
        case .unknownMethod:
            /** A daemon gains the method only by restarting, which fails a
                request first, so polling needs no retry counter. */
            return request == .poll ? Step(request: .takeToken) : Step(request: .poll)
        case .answered, .deadline:
            return answered(request, outcome: outcome)
        }
    }

    /** Polling ends on any failure; everything else waits out the retry delay, then recovers. */
    private static func failed(_ request: Request) -> Step {
        switch request {
        case .poll, .recover:
            return Step(request: .takeToken)
        case .takeToken, .refresh, .park:
            return Step(delaySeconds: retryDelaySeconds, request: .recover)
        }
    }

    /** Only a park distinguishes a deadline from a change; any other request that answers has simply succeeded. */
    private static func answered(_ request: Request, outcome: Outcome) -> Step {
        switch request {
        case .takeToken:
            return Step(request: .refresh)
        case .refresh:
            return Step(request: .park)
        case .park:
            return Step(request: outcome == .deadline ? .park : .refresh)
        case .recover:
            return Step(request: .takeToken)
        case .poll:
            return Step(delaySeconds: pollIntervalSeconds, request: .poll)
        }
    }
}
