import Testing

@testable import DirectaKit

/** The app logs every reason it unregisters and registers the daemon's agent
    again at error level (macOS keeps error level and drops info), with the last
    hello poll's error and whether launchd had the job loaded, so the next
    unexplained restart can be traced. */
@Suite struct AgentEscalationTests {
    typealias Case = (reason: AgentEscalation, line: String)

    private static let preface = "re-registering the daemon's background agent: "

    @Test func eachReasonReadsInPlainWordsWithThePollErrorAndLoadedState() {
        let cases: [Case] = [
            (
                .notLoaded,
                "the agent is enabled but launchd has not loaded its job"
            ),
            (
                .silentAfterReplace,
                "the agent is still silent after the app was replaced"
            ),
            (
                .silentAfterThrottle,
                "the agent is still silent after launchd's throttle window"
            ),
            (
                .spawnMissedAfterReplace,
                "the first start after the app was replaced did not answer"
            ),
            (
                .staleDaemon(running: "0.8.0", app: "0.9.0"),
                "the running daemon is v0.8.0 and this app is v0.9.0"
            ),
            (
                .upgradeInstall,
                "the installer is upgrading the agent's helper"
            ),
        ]
        for (reason, expected) in cases {
            #expect(
                reason.logLine(loaded: true, pollError: "daemon never answered")
                    == "\(Self.preface)\(expected). Last hello poll: daemon never answered. launchd job loaded: yes."
            )
        }
    }

    @Test func aMissingPollOrLoadedStateIsSaidPlainly() {
        #expect(
            AgentEscalation.notLoaded.logLine(loaded: false, pollError: nil)
                == "\(Self.preface)the agent is enabled but launchd has not loaded its job. Last hello poll: none was made. launchd job loaded: no."
        )
        #expect(
            AgentEscalation.upgradeInstall.logLine(loaded: nil, pollError: nil)
                == "\(Self.preface)the installer is upgrading the agent's helper. Last hello poll: none was made. launchd job loaded: unknown."
        )
    }
}
