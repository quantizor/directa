import DirectaKit
import Foundation

/** Live launchd job control for one running agent process, bundling the two
    things `Router.recoverAtStartup` needs from it: listing directa's child
    jobs and booting one out. Its presence on `Router` is the agent-mode flag,
    so agent mode cannot be switched on without also supplying the job control
    it acts through: nil means "not the agent", and every launchd side effect
    recovery takes (adoption's job match, the leftover-job reap) goes through
    closures a test controls, never the user's real gui domain. */
public struct AgentJobs: Sendable {
    /** `launchctl bootout` for one child-job label. */
    public var bootOut: @Sendable (LaunchdJobs.ChildJob) -> Void
    /** `launchctl list`, filtered to directa's child-job labels. */
    public var listChildJobs: @Sendable () -> [LaunchdJobs.ChildJob]

    public init(
        bootOut: @escaping @Sendable (LaunchdJobs.ChildJob) -> Void,
        listChildJobs: @escaping @Sendable () -> [LaunchdJobs.ChildJob]
    ) {
        self.bootOut = bootOut
        self.listChildJobs = listChildJobs
    }

    /** The real seam: `launchctl list` and `launchctl bootout` against the gui
        domain. `Router`'s default builds this only when
        `LaunchdJobLauncher.runningAsAgent` is true, so a directly constructed
        Router (every test, any embedder) never touches real launchd state
        unless it opts in explicitly. */
    public static let live = AgentJobs(
        bootOut: LaunchdJobs.bootOut,
        listChildJobs: LaunchdJobs.loadChildJobs)
}
