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

    /** One job's `launchctl print` fields: the agent's own, or a child job's. */
    public struct JobStatus: Equatable, Sendable {
        /** `last exit code`, the leading number of `64: EX_USAGE` and the like;
            nil while the job has never exited (launchd prints `(never
            exited)`) and for a death launchd reports only as a terminating
            signal. */
        public var lastExitCode: Int?
        public var lastExitReason: String?
        /** The signal number of `last terminating signal = Killed: 9`, which
            launchd prints in place of an exit code for a job a signal ended. */
        public var lastTerminatingSignal: Int?
        public var pid: pid_t?
        public var runs: Int?
        public var state: String?

        public init(
            lastExitCode: Int? = nil, lastExitReason: String? = nil,
            lastTerminatingSignal: Int? = nil, pid: pid_t? = nil, runs: Int? = nil,
            state: String? = nil
        ) {
            self.lastExitCode = lastExitCode
            self.lastExitReason = lastExitReason
            self.lastTerminatingSignal = lastTerminatingSignal
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
        public var pid: pid_t?

        public init(label: String, pid: pid_t? = nil) {
            self.label = label
            self.pid = pid
        }
    }

    /** `launchctl print gui/$UID/<label>`. First `state` / `pid` at the job
        level; later coalition blocks repeat `state = active`. */
    public static func parseJobPrint(_ output: String) -> JobStatus {
        var status = JobStatus()
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
            } else if status.lastExitCode == nil, trimmed.hasPrefix("last exit code =") {
                let value = trimmed.dropFirst("last exit code =".count).trimmingCharacters(
                    in: .whitespaces)
                status.lastExitCode = Int(value.prefix { $0 == "-" || $0.isASCII && $0.isNumber })
            } else if status.lastTerminatingSignal == nil,
                trimmed.hasPrefix("last terminating signal =")
            {
                let value = trimmed.dropFirst("last terminating signal =".count)
                let number = value.split(separator: ":").last.map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                status.lastTerminatingSignal = number.flatMap { Int($0) }
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
            jobs.append(ChildJob(label: label, pid: pid))
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

    public static func loadAgentStatus() -> JobStatus? {
        printJob(label: LaunchdAdmin.label)
    }

    /** `launchctl print` of one gui-domain job, nil when launchd has no such
        job (or the print failed). */
    public static func printJob(label: String) -> JobStatus? {
        parsedPrint(LaunchdAdmin.shell("/bin/launchctl", printArguments(label: label)))
    }

    /** `printJob` on `BlockingLane.system`, the overload an async caller gets. */
    public static func printJob(label: String) async -> JobStatus? {
        parsedPrint(await LaunchdAdmin.shell("/bin/launchctl", printArguments(label: label)))
    }

    private static func printArguments(label: String) -> [String] {
        ["print", "\(guiDomain)/\(label)"]
    }

    private static func parsedPrint(_ printed: (status: Int32, output: String)) -> JobStatus? {
        printed.status == 0 ? parseJobPrint(printed.output) : nil
    }

    /** What one `launchctl list` read found. */
    public enum ChildJobListing: Equatable, Sendable {
        case listed([ChildJob])
        /** launchctl gave no usable answer (it timed out, could not start,
            or exited nonzero): nothing is known about which jobs exist,
            which is not the same as knowing there are none. */
        case unavailable(reason: String)
    }

    /** `launchctl list` filtered to directa's child jobs, under launchctl's
        default deadline. */
    public static func listChildJobs() -> ChildJobListing {
        switch LaunchdAdmin.shellOutcome("/bin/launchctl", ["list"]) {
        case .exited(status: 0, let output):
            .listed(parseChildJobs(fromList: output))
        case .exited(let status, let output):
            .unavailable(reason: "launchctl list exited \(status): \(output.prefix(200))")
        case .failedToRun(let reason):
            .unavailable(reason: "launchctl list did not start: \(reason.prefix(200))")
        case .timedOut:
            .unavailable(reason: "launchctl list timed out")
        }
    }

    /** `listChildJobs` for a report that reads an unavailable listing as no
        jobs (doctor's leftover-job finding). */
    public static func loadChildJobs() -> [ChildJob] {
        guard case .listed(let jobs) = listChildJobs() else { return [] }
        return jobs
    }

    /** Boot out one child job. Never called for the agent label itself: the
        daemon's own teardown boots out each job it launched or adopted once
        that job exits, and the leftover-job reap reaches this only through
        `AgentJobs`, whose optionality on `Router` is what keeps a non-agent
        process (every unit test, `ddirecta --foreground`) from ever running a
        real `launchctl bootout` there. */
    public static func bootOut(label: String) {
        _ = LaunchdAdmin.shell("/bin/launchctl", bootOutArguments(label: label))
    }

    /** `bootOut` on `BlockingLane.system`, the overload an async caller gets. */
    public static func bootOut(label: String) async {
        _ = await LaunchdAdmin.shell("/bin/launchctl", bootOutArguments(label: label))
    }

    private static func bootOutArguments(label: String) -> [String] {
        ["bootout", "\(guiDomain)/\(label)"]
    }
}
