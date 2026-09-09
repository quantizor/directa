import Darwin
import Foundation

/** Inventory of the SMAppService agent and the one-shot child jobs
    `LaunchdJobLauncher` registers. Doctor reads this; recover reaps stale
    children. Parse is pure so tests do not mutate the gui domain. */
public enum LaunchdJobs {
    /** Prefix `LaunchdJobLauncher` gives every one-shot child. The agent label
        is `LaunchdAdmin.label` and is not in this set. */
    public static let childLabelPrefix = "dev.quantizor.directa.job."
    public static var guiDomain: String { "gui/\(getuid())" }

    public struct AgentStatus: Equatable, Sendable {
        public var lastExitReason: String?
        public var pid: pid_t?
        public var runs: Int?
        public var state: String?

        public init(
            lastExitReason: String? = nil, pid: pid_t? = nil, runs: Int? = nil, state: String? = nil
        ) {
            self.lastExitReason = lastExitReason
            self.pid = pid
            self.runs = runs
            self.state = state
        }

        public var jetsammed: Bool {
            lastExitReason == "OS_REASON_JETSAM"
        }
    }

    public struct ChildJob: Equatable, Sendable {
        public var label: String
        public var lastExitStatus: Int32?
        public var pid: pid_t?

        public init(label: String, lastExitStatus: Int32? = nil, pid: pid_t? = nil) {
            self.label = label
            self.lastExitStatus = lastExitStatus
            self.pid = pid
        }
    }

    /** `launchctl print gui/$UID/dev.quantizor.directa`. First `state` / `pid`
        at the job level; later coalition blocks repeat `state = active`. */
    public static func parseAgentPrint(_ output: String) -> AgentStatus {
        var status = AgentStatus()
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if status.state == nil, trimmed.hasPrefix("state =") {
                status.state = String(trimmed.dropFirst("state =".count)).trimmingCharacters(
                    in: .whitespaces)
            } else if status.pid == nil, trimmed.hasPrefix("pid =") {
                let number = trimmed.dropFirst("pid =".count).trimmingCharacters(in: .whitespaces)
                if let parsed = pid_t(number), parsed > 0 { status.pid = parsed }
            } else if status.runs == nil, trimmed.hasPrefix("runs =") {
                let number = trimmed.dropFirst("runs =".count).trimmingCharacters(in: .whitespaces)
                status.runs = Int(number)
            } else if status.lastExitReason == nil, trimmed.hasPrefix("last exit reason =") {
                status.lastExitReason = String(trimmed.dropFirst("last exit reason =".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return status
    }

    /** `launchctl list` is PID, Status, Label, tab-separated. Only child-job
        labels; the agent row is a different prefix. */
    public static func parseChildJobs(fromList output: String) -> [ChildJob] {
        var jobs: [ChildJob] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let label = parts[2]
            guard label.hasPrefix(childLabelPrefix) else { continue }
            let pid: pid_t? = {
                let raw = parts[0]
                guard raw != "-", let parsed = pid_t(raw), parsed > 0 else { return nil }
                return parsed
            }()
            let lastExitStatus: Int32? = {
                let raw = parts[1]
                guard raw != "-" else { return nil }
                return Int32(raw)
            }()
            jobs.append(ChildJob(label: label, lastExitStatus: lastExitStatus, pid: pid))
        }
        return jobs
    }

    /** A job is leftover when it has no live pid, or its pid is not one of the
        servers this daemon currently supervises. A jetsammed daemon's `defer
        bootout` never ran, so those labels stay registered with PID `-`. */
    public static func stale(_ jobs: [ChildJob], keepingPids: Set<pid_t>) -> [ChildJob] {
        jobs.filter { job in
            guard let pid = job.pid else { return true }
            return !keepingPids.contains(pid)
        }
    }

    public static func loadAgentStatus() -> AgentStatus? {
        let printed = LaunchdAdmin.shell(
            "/bin/launchctl", ["print", "\(guiDomain)/\(LaunchdAdmin.label)"])
        guard printed.status == 0 else { return nil }
        return parseAgentPrint(printed.output)
    }

    public static func loadChildJobs() -> [ChildJob] {
        let listed = LaunchdAdmin.shell("/bin/launchctl", ["list"])
        guard listed.status == 0 else { return [] }
        return parseChildJobs(fromList: listed.output)
    }

    /** Boot out leftover child jobs. Returns how many bootouts ran. Never
        touches the agent label. Caller must pass the live supervisor pids so a
        running server is not torn down. */
    @discardableResult
    public static func reapStaleChildJobs(keepingPids: Set<pid_t>) -> Int {
        let staleJobs = stale(loadChildJobs(), keepingPids: keepingPids)
        guard !staleJobs.isEmpty else { return 0 }
        let domain = guiDomain
        var reaped = 0
        for job in staleJobs {
            _ = LaunchdAdmin.shell("/bin/launchctl", ["bootout", "\(domain)/\(job.label)"])
            reaped += 1
        }
        return reaped
    }
}
