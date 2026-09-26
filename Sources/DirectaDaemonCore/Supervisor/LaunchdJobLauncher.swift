import Darwin
import DirectaKit
import Foundation

/** Spawns a supervised server as a one-shot gui-domain launchd job so the child
    gets its own jetsam coalition. posix_spawn inherits the agent's coalition and
    `responsibility_spawnattrs_setdisclaim` does not split it; `launchctl
    bootstrap` of a `KeepAlive=false` job does. Used only when this process is
    the SMAppService agent (`XPC_SERVICE_NAME` matches the agent label). Tests
    and `ddirecta --foreground` keep `SubprocessLauncher`. Exit tracking for
    every pid this launches or adopts goes through the shared `ExitWatcher`,
    never a launcher-owned kqueue. */
public struct LaunchdJobLauncher: ProcessLauncher {
    /** Prefix given to every one-shot job this launcher bootstraps, defaulting
        to the production namespace `LaunchdJobs.parseChildJobs` matches (and
        `doctor`/leftover-job reap read through that same parse). Tests pass a
        distinct prefix so a job bootstrapped under test is never mistaken for
        one the live daemon supervises, and never visible to that daemon's own
        leftover-job logic either. */
    public let labelPrefix: String

    public init(labelPrefix: String = LaunchdJobs.childLabelPrefix) {
        self.labelPrefix = labelPrefix
    }

    /** True when this process is the SMAppService agent, the only spawn that
        needs a coalition split. */
    public static var runningAsAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == LaunchdAdmin.label
    }

    public func run(
        argv: [String],
        capture: SpawnCapture,
        cwd: String?,
        environment: [String: String],
        onExitedBeforeWatch: @escaping @Sendable (pid_t?) async -> Void,
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome {
        guard argv.first?.isEmpty == false else {
            return .spawnFailed(SpawnError(errno: Int(EINVAL), message: "empty command"))
        }
        let stdoutPath = capture.stdoutPath
        let stderrPath = capture.stderrPath
        let label = labelPrefix + UUID().uuidString.lowercased()
        let domain = LaunchdJobs.guiDomain
        let plistURL = FileManager.default.temporaryDirectory.appending(
            path: "\(label).plist")
        do {
            try Self.writePlist(
                argv: argv, cwd: cwd, environment: environment, label: label,
                stderrPath: stderrPath, stdoutPath: stdoutPath, url: plistURL)
        } catch {
            return .spawnFailed(
                SpawnError(
                    errno: nil, message: "cannot write job plist: \(error.localizedDescription)"))
        }
        let bootstrap = LaunchdAdmin.shell(
            "/bin/launchctl", ["bootstrap", domain, plistURL.path])
        if bootstrap.status != 0 {
            try? FileManager.default.removeItem(at: plistURL)
            return .spawnFailed(
                SpawnError(
                    errno: nil,
                    message: "launchctl bootstrap failed: \(bootstrap.output)"))
        }
        defer {
            _ = LaunchdAdmin.shell("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
            try? FileManager.default.removeItem(at: plistURL)
        }
        let pid: pid_t
        switch await Self.waitUntilPidPublished(domain: domain, label: label) {
        case .published(let published):
            pid = published
        case .exitedUnseen(let outcome):
            /** launchd drops the pid from `launchctl print` the moment the job
                exits, so a command that finishes before the first poll never
                shows one no matter how long the poll runs; the job's run
                count and last exit code or terminating signal are what
                remain. */
            await onExitedBeforeWatch(nil)
            return outcome
        case .timedOut:
            return .spawnFailed(
                SpawnError(errno: nil, message: "launchd job \(label) never published a pid"))
        }
        switch await Self.waitUntilSessionLeader(pid) {
        case .leader:
            /** The proven-reliable order: arm only once session leadership
                (setsid, inside the perl wrapper) is confirmed. Arming any
                earlier, before that transition, measurably makes the kernel
                refuse NOTE_EXITSTATUS even for a process that is very much
                still alive, trading a rare lost exit code for a common one. */
            switch ExitWatcher.shared.arm(pid: pid) {
            case .armed:
                await onSpawn(pid)
                return await ExitWatcher.shared.wait(pid: pid)
            case .failed(let error):
                /** Measured on a real machine: a session leader that dies in
                    the gap between confirming leadership and this arm call is
                    already gone by the time the kernel processes the
                    registration, and kevent refuses ESRCH for both a
                    lingering zombie and an already-reaped pid, never
                    distinguishing the two. Arming again could only match a
                    *different*, recycled process reusing the pid number, so
                    this reads the exit from launchd's own record instead, the
                    same treatment `.died` below gives it, rather than a
                    manufactured spawnFailed. `onExitedBeforeWatch` runs so
                    the tailers drain whatever the child already wrote to
                    its spool files before dying, without recording a run
                    that was never watched. */
                guard error.errno == Int(ESRCH) else { return .spawnFailed(error) }
                await onExitedBeforeWatch(pid)
                return await Self.launchdExitRecord(domain: domain, label: label)
            }
        case .died:
            /** The process exited before it could confirm session leadership,
                the shape of a command that does nothing but exit
                (`/bin/sh -c "exit N"`) racing this daemon's own two
                `/bin/launchctl` round trips (bootstrap, then the poll that
                confirms the pid). Measured on a real machine: kevent
                registration (`ExitWatcher.arm`) refuses ESRCH for both a
                lingering zombie and an already-reaped pid, so arming here
                could only ever succeed by matching a *different*, recycled
                process that reused the pid number, never the one that just
                died. The job is still bootstrapped (the bootout is in the
                defer), so launchd's own record of the exit is read instead of
                risking a watch on the wrong process. `onExitedBeforeWatch`
                runs so the tailers drain whatever the child already wrote to its
                spool files before dying: skipping it, as every other
                early-return branch in this method does, would silence that
                output from the structured log entirely. */
            await onExitedBeforeWatch(pid)
            return await Self.launchdExitRecord(domain: domain, label: label)
        case .timedOut:
            return .spawnFailed(
                SpawnError(
                    errno: nil,
                    message: "launchd job \(label) pid \(pid) never became a session leader"))
        }
    }

    /** Outcome of polling for session leadership: `died` is detected as soon
        as `kill(pid, 0)` fails, rather than only after the full poll budget
        elapses, which is what lets `run` treat an instant exit as an exit to
        report instead of a slow, manufactured `spawnFailed`. */
    private enum SessionLeaderCheck {
        case died
        case leader
        case timedOut
    }

    /** Arms the same exit watch `run` does for a launchd child job this
        process did not spawn, so an adopted child that later dies reaches
        `recordOutcome` exactly like a spawned one. A refused arm boots
        nothing out: the caller bounces the process and its job label is
        reaped with the other leftovers. */
    public func prepareAdopt(pid: pid_t) -> Bool {
        switch ExitWatcher.shared.arm(pid: pid) {
        case .armed: return true
        case .failed: return false
        }
    }

    /** Waits on the surviving half of a jetsam SIGKILL, where `run`'s defer
        bootout never ran. `label` is the job's existing registration,
        discovered by the caller through `LaunchdJobs.loadChildJobs()` matching
        on pid; nothing is bootstrapped here. Once the process exits, replicates
        `run`'s defer cleanup: `launchctl bootout` the label and best-effort
        remove its temp plist (already gone in the common case, since the
        daemon that spawned it wrote and removed that file itself; the removal
        here only covers a plist a crashed prior daemon left behind). */
    public func adopt(pid: pid_t, label: String) async -> ProcessOutcome {
        defer {
            let domain = LaunchdJobs.guiDomain
            _ = LaunchdAdmin.shell("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
            let plistURL = FileManager.default.temporaryDirectory.appending(path: "\(label).plist")
            try? FileManager.default.removeItem(at: plistURL)
        }
        return await ExitWatcher.shared.wait(pid: pid)
    }

    /** launchd places the job in process group 1. Group teardown needs
        `pgid == pid`. `/usr/bin/perl` is on every Mac; it calls setsid and
        execs without a fourth product. A failed exec would otherwise fall off
        the end of the script and exit 0 with nothing on stderr, so it names
        the command and the reason on stderr (the spool `logs` and `why` read)
        and exits 127, the shell's command-not-found status. */
    static let sessionWrapperScript =
        #"use POSIX qw(setsid); setsid(); exec { $ARGV[0] } @ARGV or do { print STDERR "directa: cannot run $ARGV[0]: $!\n"; exit 127 }"#

    private static func writePlist(
        argv: [String], cwd: String?, environment: [String: String], label: String,
        stderrPath: String, stdoutPath: String, url: URL
    ) throws {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "XPC_SERVICE_NAME")
        for (key, value) in environment { env[key] = value }
        if env["PATH"] == nil {
            env["PATH"] = LaunchdAdmin.pathFloor
        }
        var nofile = rlimit()
        let files =
            getrlimit(RLIMIT_NOFILE, &nofile) == 0
            ? Int(nofile.rlim_cur) : 8192
        let wrapped = ["/usr/bin/perl", "-e", sessionWrapperScript, "--"] + argv
        var job: [String: Any] = [
            "EnvironmentVariables": env,
            "KeepAlive": false,
            "Label": label,
            "ProgramArguments": wrapped,
            "RunAtLoad": true,
            "SoftResourceLimits": ["NumberOfFiles": files],
            "StandardErrorPath": stderrPath,
            "StandardOutPath": stdoutPath,
        ]
        if let cwd, !cwd.isEmpty {
            job["WorkingDirectory"] = cwd
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: job, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /** Outcome of polling `launchctl print` for the job's pid. `exitedUnseen`
        is a job that already ran (`runs` above zero) and holds no pid:
        launchd's own record of how it ended is all that is left of it. */
    private enum PidPoll {
        case exitedUnseen(ProcessOutcome)
        case published(pid_t)
        case timedOut
    }

    /** How a job launchd already reaped ended, read from its `launchctl print`
        status: the terminating signal when launchd printed one, else the last
        exit code, else unknown. */
    static func unseenExitOutcome(_ status: LaunchdJobs.AgentStatus) -> ProcessOutcome {
        if let signal = status.lastTerminatingSignal { return .signaled(signal: signal) }
        if let code = status.lastExitCode { return .exited(code: code) }
        return .exitedStatusUnknown
    }

    /** How many `launchctl print` reads `launchdExitRecord` makes, and the
        pause between them: launchd reaps a dead job and writes its exit
        record within a few milliseconds, so this bound only matters when
        launchd is slow, and past it the exit stays status-unknown. */
    static let exitRecordAttempts = 10
    static let exitRecordInterval = Duration.milliseconds(50)

    /** The exit of a still-bootstrapped job whose process died before its
        watch was armed, read from `launchctl print` once launchd shows the
        job not running with an exit record. */
    private static func launchdExitRecord(domain: String, label: String) async -> ProcessOutcome {
        await exitRecord(attempts: exitRecordAttempts, interval: exitRecordInterval) {
            let printed = LaunchdAdmin.shell("/bin/launchctl", ["print", "\(domain)/\(label)"])
            return printed.status == 0 ? LaunchdJobs.parseAgentPrint(printed.output) : nil
        }
    }

    /** Polls `read` (nil when the print failed) until it shows a job with no
        pid and an exit code or terminating signal, then maps that record
        through `unseenExitOutcome`. Status-unknown once `attempts` reads pass
        without one. */
    static func exitRecord(
        attempts: Int, interval: Duration, read: () async -> LaunchdJobs.AgentStatus?
    ) async -> ProcessOutcome {
        for attempt in 0..<attempts {
            let status = await read()
            if let status, status.pid == nil,
                status.lastExitCode != nil || status.lastTerminatingSignal != nil
            {
                return unseenExitOutcome(status)
            }
            if attempt < attempts - 1 {
                try? await Task.sleep(for: interval)
            }
        }
        return .exitedStatusUnknown
    }

    private static func waitUntilPidPublished(domain: String, label: String) async -> PidPoll {
        for _ in 0..<40 {
            let printed = LaunchdAdmin.shell("/bin/launchctl", ["print", "\(domain)/\(label)"])
            if printed.status == 0 {
                let status = LaunchdJobs.parseAgentPrint(printed.output)
                if let pid = status.pid { return .published(pid) }
                if let runs = status.runs, runs > 0 { return .exitedUnseen(unseenExitOutcome(status)) }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return .timedOut
    }

    private static func waitUntilSessionLeader(_ pid: pid_t) async -> SessionLeaderCheck {
        for _ in 0..<40 {
            if getpgid(pid) == pid { return .leader }
            /** `errno == ESRCH` specifically, not merely a nonzero return: a
                launchd child freshly spawned by this same user can transiently
                answer `kill(pid, 0)` with EPERM ("operation not permitted")
                while very much alive, before its own credential setup has
                settled, mirroring the exact quirk that already gates
                NOTE_EXITSTATUS (see ExitWatcher.arm). Only ESRCH means the
                kernel has no such process left to check. */
            if kill(pid, 0) != 0, errno == ESRCH { return .died }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return .timedOut
    }
}
