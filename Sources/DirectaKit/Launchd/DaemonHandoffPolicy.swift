import Foundation

/** What a bounce found when it asked the running daemon to hand off. */
public enum DaemonHandoffOutcome: Equatable, Sendable {
    /** The daemon was asked to hand its servers to the next one and exit. */
    case handedOff
    /** No daemon answered (or none came back after a kill): the bounce only starts one. */
    case nothingRunning
    /** A pre-handoff agent daemon was killed and launchd relaunched the same
        pre-handoff binary, which adopted the servers: the relaunch was the
        restart, so a bounce that would restart again skips it. */
    case restartedByRelaunch
}

/** Which way to ask a running daemon to leave without stopping its servers.

    Policy, not I/O: `daemon.shutdown {"handoff": true}` arrived in 3.1.0, and
    a daemon below it ignores the field and drains (stops every server), as it
    does on SIGTERM. The agent job is the one daemon whose servers survive a
    SIGKILL (they are launchd child jobs the relaunched daemon adopts), so a
    pre-handoff agent is killed rather than asked. */
public enum DaemonHandoffPolicy {
    /** The first daemon version that honors the `handoff` field. */
    public static let firstVersion = "3.1.0"

    /** What `daemon.info` said, reduced to what the decision reads. */
    public struct Answer: Equatable, Sendable {
        public var pid: Int
        /** True while the daemon is still in `recoverAtStartup`. */
        public var restoring: Bool
        public var version: String

        public init(pid: Int, restoring: Bool = false, version: String) {
            self.pid = pid
            self.restoring = restoring
            self.version = version
        }

        public init(_ info: DaemonInfo) {
            self.init(pid: info.pid, restoring: info.restoring == true, version: info.daemonVersion)
        }
    }

    public enum Step: Equatable, Sendable {
        /** SIGKILL the agent job running `pid`; its relaunch adopts the servers. */
        case killAgent(pid: Int)
        case nothingRunning
        /** Send `daemon.shutdown {"handoff": true}`. A daemon that is not the
            agent and predates the field drains here; that is documented, since
            only a launchd child job can be adopted. */
        case requestHandoff
    }

    /** What the daemon that answered after a kill means for the wait. */
    public enum Successor: Equatable, Sendable {
        /** Hand the new daemon off too: it honors the field, has finished
            restoring (a handoff mid-adoption would exit it before it adopted),
            and the unregister or `kickstart -k` that follows would SIGTERM it. */
        case handOff
        /** Nothing, or still the killed pid: keep waiting until the deadline. */
        case none
        /** A successor that honors the field but is still restoring: keep
            waiting; at the deadline `deadlineStep` decides. */
        case restoring
        /** A different pid at a pre-handoff version: the relaunch is the restart. */
        case sameBinaryRelaunched
    }

    /** Version strings that do not parse sort as older (`SetupPlanner.compareVersions`),
        so an unreadable version is treated as pre-handoff: a kill is recoverable
        (the servers survive it), a handoff request a pre-handoff daemon would
        drain is not. */
    public static func supportsHandoff(version: String) -> Bool {
        SetupPlanner.compareVersions(version, firstVersion) != .orderedAscending
    }

    /** `agentPid` is the pid launchd reports for the agent job. Nil (launchctl
        gave no answer) is not proof the daemon is the agent, and a kill aimed
        at the wrong job could stop something else, so it gets the plain request. */
    public static func step(answer: Answer?, agentPid: Int?) -> Step {
        guard let answer else { return .nothingRunning }
        if supportsHandoff(version: answer.version) { return .requestHandoff }
        if let agentPid, agentPid == answer.pid { return .killAgent(pid: answer.pid) }
        return .requestHandoff
    }

    public static func successor(killedPid: Int, answer: Answer?) -> Successor {
        guard let answer, answer.pid != killedPid else { return .none }
        guard supportsHandoff(version: answer.version) else { return .sameBinaryRelaunched }
        return answer.restoring ? .restoring : .handOff
    }

    /** What to do when the successor wait runs out with `last` the final
        reading. Still restoring: an early handoff costs at most a respawn,
        while the bounce that follows would drain every server. */
    public static func deadlineStep(last: Successor) -> Step {
        last == .restoring ? .requestHandoff : .nothingRunning
    }
}
