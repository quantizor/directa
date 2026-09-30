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

    /** A deliberate `directa daemon stop` must survive the app's poll loop. */
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
