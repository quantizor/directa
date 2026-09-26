import Testing

@testable import DirectaKit

@Suite struct AppAgentPolicyTests {
    typealias Action = AppAgentPolicy.LaunchAction
    typealias Status = AppAgentPolicy.AgentStatus

    struct Case: CustomTestStringConvertible, Sendable {
        var agentStatus: Status = .notRegistered
        var bundleHasPlist = true
        var expected: Action
        var legacyLoginItemEnabled = false
        var markerPresent = false
        var name: String
        var runningOutsideApplications = false

        var testDescription: String { name }

        var actual: Action {
            AppAgentPolicy.launchAction(
                agentStatus: agentStatus,
                bundleHasPlist: bundleHasPlist,
                legacyLoginItemEnabled: legacyLoginItemEnabled,
                markerPresent: markerPresent,
                runningOutsideApplications: runningOutsideApplications)
        }
    }

    static let cases: [Case] = [
        Case(expected: .recordOff, name: "never turned on: agent not registered"),
        Case(agentStatus: .notFound, expected: .recordOff, name: "never turned on: agent not found"),
        Case(expected: .register, legacyLoginItemEnabled: true, name: "legacy on migrates"),
        Case(
            agentStatus: .enabled, expected: .register, legacyLoginItemEnabled: true,
            name: "legacy on beside an enabled agent still migrates"),
        Case(
            agentStatus: .requiresApproval, expected: .register, legacyLoginItemEnabled: true,
            name: "legacy on wins over requires approval"),
        Case(
            agentStatus: .requiresApproval, expected: .leaveAlone,
            name: "requires approval records nothing"),
        Case(agentStatus: .enabled, expected: .leaveAlone, name: "agent already on"),
        Case(agentStatus: .unknown, expected: .leaveAlone, name: "unknown status touches nothing"),
        Case(
            agentStatus: .unknown, expected: .leaveAlone, legacyLoginItemEnabled: true,
            name: "unknown status touches nothing even with legacy on"),
        Case(expected: .leaveAlone, markerPresent: true, name: "user turned it off"),
        Case(
            expected: .leaveAlone, legacyLoginItemEnabled: true, markerPresent: true,
            name: "marker wins over legacy on"),
        Case(
            expected: .leaveAlone, legacyLoginItemEnabled: true, name: "volume copy with legacy on",
            runningOutsideApplications: true),
        Case(expected: .leaveAlone, name: "volume copy never turned on", runningOutsideApplications: true),
        Case(
            bundleHasPlist: false, expected: .leaveAlone, legacyLoginItemEnabled: true,
            name: "no plist with legacy on"),
        Case(bundleHasPlist: false, expected: .leaveAlone, name: "no plist never turned on"),
    ]

    @Test(arguments: cases) func launchAction(_ c: Case) {
        #expect(c.actual == c.expected)
    }

    static let allStatuses: [Status] = [.enabled, .notFound, .notRegistered, .requiresApproval, .unknown]

    /** The legacy login item is retired only once the agent holds the
        user's choice; a registration that did not take leaves it for the
        next launch to carry forward again. */
    @Test func legacyLoginItemRetiresOnlyWhenTheAgentCarriesTheChoice() {
        let retired = Self.allStatuses.filter {
            AppAgentPolicy.retiresLegacyLoginItem(agentStatusAfterRegister: $0)
        }
        #expect(retired == [.enabled, .requiresApproval])
    }

    /** A kept legacy item plus an unregistered agent must read as `.register`
        on the next launch, never `.recordOff`, or a failed registration would
        turn Start at login off for good. */
    @Test func aFailedRegistrationRetriesOnTheNextLaunch() {
        for status: Status in [.notFound, .notRegistered] {
            #expect(!AppAgentPolicy.retiresLegacyLoginItem(agentStatusAfterRegister: status), "\(status)")
            let next = AppAgentPolicy.launchAction(
                agentStatus: status, bundleHasPlist: true, legacyLoginItemEnabled: true,
                markerPresent: false, runningOutsideApplications: false)
            #expect(next == .register, "\(status)")
        }
    }

    /** Every input combination: registering happens only to carry forward a
        legacy login item that was on, the off marker is never written for
        someone whose legacy item was on, and the volume copy, a copy without
        the plist, or an existing marker never changes anything. */
    @Test func startAtLoginStaysOptInAcrossEveryInput() {
        for agentStatus in Self.allStatuses {
            for bundleHasPlist in [false, true] {
                for legacyLoginItemEnabled in [false, true] {
                    for markerPresent in [false, true] {
                        for runningOutsideApplications in [false, true] {
                            let action = AppAgentPolicy.launchAction(
                                agentStatus: agentStatus,
                                bundleHasPlist: bundleHasPlist,
                                legacyLoginItemEnabled: legacyLoginItemEnabled,
                                markerPresent: markerPresent,
                                runningOutsideApplications: runningOutsideApplications)
                            if action == .register { #expect(legacyLoginItemEnabled) }
                            if action == .recordOff { #expect(!legacyLoginItemEnabled) }
                            if !bundleHasPlist || runningOutsideApplications || markerPresent {
                                #expect(action == .leaveAlone)
                            }
                        }
                    }
                }
            }
        }
    }
}
