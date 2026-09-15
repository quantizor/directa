import Testing

@testable import DirectaKit

@Suite struct AppAgentPolicyTests {
    @Test func registersWhenNotDisabledInApplicationsWithPlist() {
        #expect(
            AppAgentPolicy.shouldRegisterAtLaunch(
                deliberatelyDisabled: false, runningOutsideApplications: false, bundleHasPlist: true)
                == true)
    }

    @Test func skipsWhenDeliberatelyDisabled() {
        #expect(
            AppAgentPolicy.shouldRegisterAtLaunch(
                deliberatelyDisabled: true, runningOutsideApplications: false, bundleHasPlist: true)
                == false)
    }

    /** The volume/DMG copy: registering from there races the relocate handoff
        (SetupPerformer.quitIfTwinIsRunning, AppInstancePolicy), so this must
        refuse regardless of the disabled marker. */
    @Test func skipsWhenRunningOutsideApplications() {
        #expect(
            AppAgentPolicy.shouldRegisterAtLaunch(
                deliberatelyDisabled: false, runningOutsideApplications: true, bundleHasPlist: true)
                == false)
        #expect(
            AppAgentPolicy.shouldRegisterAtLaunch(
                deliberatelyDisabled: false, runningOutsideApplications: true, bundleHasPlist: false)
                == false)
    }

    /** A copy that predates the in-bundle app LaunchAgent has nothing to
        register, regardless of the other two inputs. */
    @Test func skipsWhenBundleHasNoPlist() {
        #expect(
            AppAgentPolicy.shouldRegisterAtLaunch(
                deliberatelyDisabled: false, runningOutsideApplications: false, bundleHasPlist: false)
                == false)
        #expect(
            AppAgentPolicy.shouldRegisterAtLaunch(
                deliberatelyDisabled: true, runningOutsideApplications: false, bundleHasPlist: false)
                == false)
    }

    /** Every guard failing at once still answers false, not a trap or a
        mismatched combination. */
    @Test func allGuardsFailingStillRefuses() {
        #expect(
            AppAgentPolicy.shouldRegisterAtLaunch(
                deliberatelyDisabled: true, runningOutsideApplications: true, bundleHasPlist: false)
                == false)
    }
}
