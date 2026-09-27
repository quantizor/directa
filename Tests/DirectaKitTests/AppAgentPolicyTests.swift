import Testing

@testable import DirectaKit

@Suite struct AppAgentPolicyTests {
    typealias Action = AppAgentPolicy.LaunchAction
    typealias Inputs = AppAgentPolicy.LaunchInputs
    typealias Status = AppAgentPolicy.RegistrationStatus

    struct Case: CustomTestStringConvertible, Sendable {
        var expected: Action
        var inputs: Inputs
        var name: String

        var testDescription: String { name }

        init(
            agentStatus: Status = .notRegistered, bundleHasPlist: Bool = true, expected: Action,
            legacyLoginItemEnabled: Bool = false, markerPresent: Bool = false, name: String,
            runningOutsideApplications: Bool = false
        ) {
            self.expected = expected
            self.inputs = Inputs(
                agentStatus: agentStatus,
                bundleHasPlist: bundleHasPlist,
                legacyLoginItemEnabled: legacyLoginItemEnabled,
                markerPresent: markerPresent,
                runningOutsideApplications: runningOutsideApplications)
            self.name = name
        }
    }

    /** The rows with the legacy item on and the agent not enabled are also
        the retry: a registration that did not end `enabled` keeps the legacy
        item, so the next launch reads these same inputs and registers again. */
    static let cases: [Case] = [
        Case(expected: .recordOff, name: "never turned on: agent not registered"),
        Case(agentStatus: .notFound, expected: .recordOff, name: "never turned on: agent not found"),
        Case(expected: .register, legacyLoginItemEnabled: true, name: "legacy on migrates"),
        Case(
            agentStatus: .notFound, expected: .register, legacyLoginItemEnabled: true,
            name: "legacy on beside a not-found agent registers"),
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
        #expect(AppAgentPolicy.launchAction(c.inputs) == c.expected)
    }

    static let allStatuses: [Status] = [.enabled, .notFound, .notRegistered, .requiresApproval, .unknown]

    /** The legacy login item is retired only once the agent is enabled. An
        agent waiting on approval does not start the app at login yet, so
        retiring the legacy item then would leave nothing starting it. */
    @Test func legacyLoginItemRetiresOnlyOnceTheAgentIsEnabled() {
        let retired = Self.allStatuses.filter {
            AppAgentPolicy.retiresLegacyLoginItem(agentStatusAfterRegister: $0)
        }
        #expect(retired == [.enabled])
    }

    /** Log lines name a status in words, never by raw value. */
    @Test func statusDescriptionsAreWords() {
        #expect(Self.allStatuses.map(\.description) == [
            "enabled", "not found", "not registered", "requires approval", "unknown",
        ])
    }

    /** The Settings toggle reads On whenever something starts the app at
        login: the enabled agent, or a legacy item kept while the agent is not
        enabled. An agent waiting on approval alone starts nothing. */
    @Test func startAtLoginReadsOnWhenTheAgentOrTheLegacyItemIsEnabled() {
        var on: [String] = []
        for agentStatus in Self.allStatuses {
            for legacyLoginItemEnabled in [false, true]
            where AppAgentPolicy.startsAtLogin(
                agentStatus: agentStatus, legacyLoginItemEnabled: legacyLoginItemEnabled)
            {
                on.append("\(agentStatus) legacy=\(legacyLoginItemEnabled)")
            }
        }
        #expect(on == [
            "enabled legacy=false",
            "enabled legacy=true",
            "not found legacy=true",
            "not registered legacy=true",
            "requires approval legacy=true",
            "unknown legacy=true",
        ])
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
                                Inputs(
                                    agentStatus: agentStatus,
                                    bundleHasPlist: bundleHasPlist,
                                    legacyLoginItemEnabled: legacyLoginItemEnabled,
                                    markerPresent: markerPresent,
                                    runningOutsideApplications: runningOutsideApplications))
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
