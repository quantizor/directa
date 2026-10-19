import DirectaKit
import Foundation

/** Live launchd job control for one running agent process, bundling the two
    things `Router.recoverAtStartup` needs from it: listing directa's child
    jobs and booting one out. Its presence on `Router` is the agent-mode flag,
    so agent mode cannot be switched on without also supplying the job control
    it acts through: nil means "not the agent". Recovery's own launchd side
    effects, adoption's job match and the leftover-job reap, go through these
    closures, which a test controls and never touches the user's real gui
    domain; an adopted job's own bootout, once its watch eventually fires, is a
    separate real `launchctl` call inside `LaunchdJobLauncher.adopt`, outside
    this seam entirely. */
public struct AgentJobs: Sendable {
    /** `launchctl bootout` for one child-job label. */
    public var bootOut: @Sendable (LaunchdJobs.ChildJob) async -> Void
    /** `launchctl list`, filtered to directa's child-job labels, or why it
        gave no answer. */
    public var listChildJobs: @Sendable () async -> LaunchdJobs.ChildJobListing

    public init(
        bootOut: @escaping @Sendable (LaunchdJobs.ChildJob) async -> Void,
        listChildJobs: @escaping @Sendable () async -> LaunchdJobs.ChildJobListing
    ) {
        self.bootOut = bootOut
        self.listChildJobs = listChildJobs
    }

    /** The real seam: `launchctl list` and `launchctl bootout` against the gui
        domain, each on `BlockingLane.system`. `Router`'s default builds this
        only when `LaunchdJobLauncher.runningAsAgent` is true, so a directly
        constructed Router (every test, any embedder) never touches real
        launchd state unless it opts in explicitly. */
    public static let live = AgentJobs(
        bootOut: { job in await LaunchdJobs.bootOut(label: job.label) },
        listChildJobs: { await BlockingLane.system.run(LaunchdJobs.listChildJobs) })
}

/** How long and how often the daemon re-reads launchd's job list after boot
    restore left a live survivor undecided because the list gave no answer.
    The delay before the first re-read doubles after each unanswered read up
    to `longestDelay`, and the reads stop once `window` has passed since the
    first one was scheduled. */
public struct DeferredSurvivorRetry: Sendable {
    public var firstDelay: Duration
    public var longestDelay: Duration
    public var window: Duration

    public init(firstDelay: Duration, longestDelay: Duration, window: Duration) {
        self.firstDelay = firstDelay
        self.longestDelay = longestDelay
        self.window = window
    }

    /** `launchctl list` stalls while launchd is busy at login, which clears
        within seconds to a minute or two, so the first re-read comes quickly
        and later ones back off to a shared ceiling rather than hammering a
        busy launchd. Five minutes bounds the daemon's patience: a launchd
        that stays silent that long is broken in a way another read will not
        fix, and the next boot is the better judge. */
    public static let standard = DeferredSurvivorRetry(
        firstDelay: .seconds(2), longestDelay: .seconds(30), window: .seconds(300))
}
