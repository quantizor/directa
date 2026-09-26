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
        guard let pid = await Self.waitUntilPidPublished(domain: domain, label: label) else {
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
                    this reports the unrecoverable exit directly, the same
                    treatment `.died` below gives it, rather than a
                    manufactured spawnFailed. `onSpawn` still runs so the
                    tailers drain whatever the child already wrote to its
                    spool files before dying. */
                guard error.errno == Int(ESRCH) else { return .spawnFailed(error) }
                await onSpawn(pid)
                return .exitedStatusUnknown
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
                died; this reports the unrecoverable exit directly rather than
                risk watching the wrong process. `onSpawn` still runs so the
                tailers drain whatever the child already wrote to its spool
                files before dying: skipping it, as every other early-return
                branch in this method does, would silence that output from
                the structured log entirely. */
            await onSpawn(pid)
            return .exitedStatusUnknown
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

    /** Re-watches a launchd child job this process did not spawn: the surviving
        half of a jetsam SIGKILL, where `run`'s defer bootout never ran. `label`
        is the job's existing registration, discovered by the caller through
        `LaunchdJobs.loadChildJobs()` matching on pid; nothing is bootstrapped
        here. Arms the same exit watch `run` does, so an adopted child that
        later dies reaches `recordOutcome` exactly like a spawned one, then
        replicates `run`'s defer cleanup once the process exits: `launchctl
        bootout` the label and best-effort remove its temp plist (already gone
        in the common case, since the daemon that spawned it wrote and removed
        that file itself; the removal here only covers a plist a crashed prior
        daemon left behind). Returns nil only when the watch could not be armed,
        which the caller reads as "adopt failed, bounce it instead". */
    public func adopt(pid: pid_t, label: String) async -> ProcessOutcome? {
        switch ExitWatcher.shared.arm(pid: pid) {
        case .armed: break
        case .failed: return nil
        }
        defer {
            let domain = LaunchdJobs.guiDomain
            _ = LaunchdAdmin.shell("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
            let plistURL = FileManager.default.temporaryDirectory.appending(path: "\(label).plist")
            try? FileManager.default.removeItem(at: plistURL)
        }
        return await ExitWatcher.shared.wait(pid: pid)
    }

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
        /** launchd places the job in process group 1. Group teardown needs
            `pgid == pid`. `/usr/bin/perl` is on every Mac; it calls setsid and
            execs without a fourth product. */
        let wrapped = [
            "/usr/bin/perl", "-e", "use POSIX qw(setsid); setsid(); exec { $ARGV[0] } @ARGV", "--",
        ] + argv
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

    private static func waitUntilPidPublished(domain: String, label: String) async -> pid_t? {
        for _ in 0..<40 {
            if let pid = publishedPid(domain: domain, label: label) { return pid }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
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

    private static func publishedPid(domain: String, label: String) -> pid_t? {
        let printed = LaunchdAdmin.shell("/bin/launchctl", ["print", "\(domain)/\(label)"])
        guard printed.status == 0 else { return nil }
        return LaunchdJobs.parseAgentPrint(printed.output).pid
    }
}
