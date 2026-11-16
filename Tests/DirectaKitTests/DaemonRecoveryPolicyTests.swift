import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaKit

@Suite struct LegacyAgentPlistTests {
    /** launchd rejects an ExitTimeOut above 60, silently clamps it, and logs
        "ExitTimeOut is larger than the maximum allowed", so the rendered value
        has to stay inside the ceiling. Rendering runs the user's login shell
        to capture PATH, so it runs off the pool. */
    @Test(.temporaryTree) func exitTimeOutStaysUnderLaunchdCeiling() async throws {
        let dir = try TemporaryTree.path(named: "plist")
        let paths = DirectaPaths(dataDir: dir)
        let plist = await offPool { LaunchdAdmin.renderPlist(daemonPath: "/tmp/ddirecta", paths: paths) }
        let data = try #require(plist.data(using: .utf8))
        let parsed = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let exitTimeOut = try #require(parsed["ExitTimeOut"] as? Int)
        #expect(exitTimeOut <= 60)
    }
}

@Suite struct AgentRebindPolicyTests {
    @Test func deliberateStopSkipsRegisterUnlessRebind() {
        #expect(
            AgentRebindPolicy.shouldRegisterAtLaunch(
                deliberatelyStopped: true, rebindNeeded: false) == false)
        #expect(
            AgentRebindPolicy.shouldRegisterAtLaunch(
                deliberatelyStopped: true, rebindNeeded: true) == true)
    }

    @Test func runningInstallRegisters() {
        #expect(
            AgentRebindPolicy.shouldRegisterAtLaunch(
                deliberatelyStopped: false, rebindNeeded: false) == true)
        #expect(
            AgentRebindPolicy.shouldRegisterAtLaunch(
                deliberatelyStopped: false, rebindNeeded: true) == true)
    }

    @Test func forceReregisterOnlyWhenRebindMarked() {
        #expect(
            AgentRebindPolicy.shouldForceReregisterAfterHelloMiss(rebindNeeded: true))
        #expect(
            !AgentRebindPolicy.shouldForceReregisterAfterHelloMiss(rebindNeeded: false))
    }

    @Test(.temporaryTree) func rebindMarkerRoundTrip() throws {
        let dir = try TemporaryTree.path(named: "rebind")
        let paths = DirectaPaths(dataDir: dir)
        #expect(!LaunchdAdmin.agentRebindNeeded(paths: paths))
        try LaunchdAdmin.markAgentRebindNeeded(paths: paths)
        #expect(LaunchdAdmin.agentRebindNeeded(paths: paths))
        LaunchdAdmin.clearAgentRebindMarker(paths: paths)
        #expect(!LaunchdAdmin.agentRebindNeeded(paths: paths))
    }
}

@Suite struct DaemonRecoveryPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func reachableDaemonNeedsNothing() {
        #expect(
            DaemonRecoveryPolicy.decide(
                reachable: true, stoppedOnPurpose: false, recovering: false, lastAttempt: nil,
                now: now) == .healthy)
    }

    @Test func crashedDaemonRecoversImmediately() {
        #expect(
            DaemonRecoveryPolicy.decide(
                reachable: false, stoppedOnPurpose: false, recovering: false, lastAttempt: nil,
                now: now) == .recover)
    }

    /** A deliberate `directa daemon stop` must survive the app's follow loop. */
    @Test func deliberateStopWaitsForTheUser() {
        #expect(
            DaemonRecoveryPolicy.decide(
                reachable: false, stoppedOnPurpose: true, recovering: false, lastAttempt: nil,
                now: now) == .awaitUser)
        /** Intent wins even when a cooldown would otherwise allow a retry. */
        #expect(
            DaemonRecoveryPolicy.decide(
                reachable: false, stoppedOnPurpose: true, recovering: false,
                lastAttempt: now.addingTimeInterval(-3600), now: now) == .awaitUser)
    }

    @Test func attemptInFlightIsNotStacked() {
        #expect(
            DaemonRecoveryPolicy.decide(
                reachable: false, stoppedOnPurpose: false, recovering: true, lastAttempt: nil,
                now: now) == .inFlight)
    }

    @Test func failedAttemptCoolsDownThenRetries() {
        #expect(
            DaemonRecoveryPolicy.decide(
                reachable: false, stoppedOnPurpose: false, recovering: false,
                lastAttempt: now.addingTimeInterval(-1), now: now) == .cooling)
        /** Boundary: exactly at the cooldown is eligible again. */
        #expect(
            DaemonRecoveryPolicy.decide(
                reachable: false, stoppedOnPurpose: false, recovering: false,
                lastAttempt: now.addingTimeInterval(-DaemonRecoveryPolicy.cooldown), now: now)
                == .recover)
        #expect(
            DaemonRecoveryPolicy.decide(
                reachable: false, stoppedOnPurpose: false, recovering: false,
                lastAttempt: now.addingTimeInterval(-60), now: now) == .recover)
    }
}

@Suite struct DaemonHandoffPolicyTests {
    private typealias Answer = DaemonHandoffPolicy.Answer

    @Test func noDaemonMeansNothingToHandOff() {
        #expect(DaemonHandoffPolicy.step(answer: nil, agentPid: 7) == .nothingRunning)
        #expect(DaemonHandoffPolicy.step(answer: nil, agentPid: nil) == .nothingRunning)
    }

    @Test(arguments: ["3.1.0", "3.1.1", "3.2.0", "4.0.0", "3.1.0-beta.1", "3.1.0 (build 9)", "10.0.0"])
    func aDaemonThatHonorsTheFieldIsAskedNotKilled(version: String) {
        #expect(
            DaemonHandoffPolicy.step(answer: Answer(pid: 7, version: version), agentPid: 7) == .requestHandoff)
        #expect(
            DaemonHandoffPolicy.step(answer: Answer(pid: 7, version: version), agentPid: nil) == .requestHandoff)
    }

    @Test(arguments: ["3.0.9", "3.0.0", "2.9.9", "1", "0.0.1"])
    func aPreHandoffAgentIsKilled(version: String) {
        #expect(
            DaemonHandoffPolicy.step(answer: Answer(pid: 7, version: version), agentPid: 7) == .killAgent(pid: 7))
    }

    @Test func aPreHandoffDaemonThatIsNotTheAgentGetsTheRequest() {
        #expect(
            DaemonHandoffPolicy.step(answer: Answer(pid: 7, version: "3.0.0"), agentPid: 8) == .requestHandoff)
    }

    @Test func anUnknownAgentPidIsNotProofOfTheAgentSoNothingIsKilled() {
        #expect(
            DaemonHandoffPolicy.step(answer: Answer(pid: 7, version: "3.0.0"), agentPid: nil) == .requestHandoff)
    }

    /** Unparseable sorts as older, so the daemon is killed when it is the agent
        (recoverable) rather than sent a request it may drain on. */
    @Test(arguments: ["", "dev", "abc.def", " ", "v3.1.0"])
    func aMalformedVersionReadsAsPreHandoff(version: String) {
        #expect(!DaemonHandoffPolicy.supportsHandoff(version: version))
        #expect(
            DaemonHandoffPolicy.step(answer: Answer(pid: 7, version: version), agentPid: 7) == .killAgent(pid: 7))
    }

    @Test func nothingAnsweringYetKeepsWaiting() {
        #expect(DaemonHandoffPolicy.successor(killedPid: 7, answer: nil) == .none)
    }

    @Test(arguments: ["3.0.0", "3.1.0", "garbage"])
    func theKilledPidStillAnsweringKeepsWaiting(version: String) {
        #expect(
            DaemonHandoffPolicy.successor(killedPid: 7, answer: Answer(pid: 7, version: version)) == .none)
    }

    @Test func aNewerSuccessorIsHandedOff() {
        #expect(
            DaemonHandoffPolicy.successor(killedPid: 7, answer: Answer(pid: 8, version: "3.1.0")) == .handOff)
    }

    @Test func aSuccessorStillRestoringKeepsWaiting() {
        #expect(
            DaemonHandoffPolicy.successor(
                killedPid: 7, answer: Answer(pid: 8, restoring: true, version: "3.1.0")) == .restoring)
    }

    @Test func atTheDeadlineOnlyARestoringSuccessorIsHandedOff() {
        #expect(DaemonHandoffPolicy.deadlineStep(last: .restoring) == .requestHandoff)
        #expect(DaemonHandoffPolicy.deadlineStep(last: .none) == .nothingRunning)
    }

    @Test func aSuccessorOfTheSameOldBinaryIsTheRestartEvenWhileRestoring() {
        #expect(
            DaemonHandoffPolicy.successor(
                killedPid: 7, answer: Answer(pid: 8, restoring: true, version: "3.0.0"))
                == .sameBinaryRelaunched)
    }

    @Test func aSuccessorOfTheSameOldBinaryIsTheRestart() {
        #expect(
            DaemonHandoffPolicy.successor(killedPid: 7, answer: Answer(pid: 8, version: "3.0.0"))
                == .sameBinaryRelaunched)
        #expect(
            DaemonHandoffPolicy.successor(killedPid: 7, answer: Answer(pid: 8, version: "garbage"))
                == .sameBinaryRelaunched)
    }
}
