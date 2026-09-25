import DirectaKit
import Foundation

/** Live launchd job control for one running agent process, bundling the two
    things `Router.recoverAtStartup` needs from it: listing directa's child
    jobs and booting one out. Its presence on `Router` IS the agent-mode flag:
    the two were previously separate seams (`childJobsProvider` for listing,
    `runningAsAgent` for the gate), so a test enabling one without the other
    left the reap path free to call the real `LaunchdJobs.reapStaleChildJobs`
    (a real `launchctl list` plus real `launchctl bootout` against the gui
    domain) instead of the fake it had injected for adoption. Folding both into
    one optional value makes that combination unrepresentable: nil means "not
    the agent", full stop, and every launchd side effect recovery can take
    (adoption's job match, the leftover-job reap) goes through the same
    closures a test controls. */
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
