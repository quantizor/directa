import Darwin
import DirectaKit
import Foundation

/** Spawns a supervised server as a one-shot gui-domain launchd job so the child
    gets its own jetsam coalition. posix_spawn inherits the agent's coalition and
    `responsibility_spawnattrs_setdisclaim` does not split it; `launchctl
    bootstrap` of a `KeepAlive=false` job does. Used only when this process is
    the SMAppService agent (`XPC_SERVICE_NAME` matches the agent label). Tests
    and `ddirecta --foreground` keep `SubprocessLauncher`. */
public struct LaunchdJobLauncher: ProcessLauncher {
    public static let labelPrefix = LaunchdJobs.childLabelPrefix

    public init() {}

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
        let label = Self.labelPrefix + UUID().uuidString.lowercased()
        let domain = "gui/\(getuid())"
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
                    errno: Int(bootstrap.status),
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
        guard await Self.waitUntilSessionLeader(pid) else {
            return .spawnFailed(
                SpawnError(
                    errno: nil,
                    message: "launchd job \(label) pid \(pid) never became a session leader"))
        }
        /** Arm `NOTE_EXIT` before advertising the pid so a kqueue failure is
            `spawnFailed` rather than a fake `_exit(0)` after `onSpawn`. */
        let queue = kqueue()
        guard queue >= 0 else {
            return .spawnFailed(
                SpawnError(errno: Int(errno), message: "kqueue failed for launchd job \(label)"))
        }
        var change = kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        if kevent(queue, &change, 1, nil, 0, nil) == -1 {
            let err = errno
            close(queue)
            return .spawnFailed(
                SpawnError(
                    errno: Int(err),
                    message: "cannot watch launchd job \(label) pid \(pid)"))
        }
        await onSpawn(pid)
        return await Task.detached(priority: .userInitiated) {
            Self.waitForExit(pid: pid, queue: queue)
        }.value
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

    private static func waitUntilSessionLeader(_ pid: pid_t) async -> Bool {
        for _ in 0..<40 {
            if getpgid(pid) == pid { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private static func publishedPid(domain: String, label: String) -> pid_t? {
        let printed = LaunchdAdmin.shell("/bin/launchctl", ["print", "\(domain)/\(label)"])
        guard printed.status == 0 else { return nil }
        for line in printed.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid = ") else { continue }
            let number = trimmed.dropFirst("pid = ".count)
            if let parsed = pid_t(number), parsed > 0 { return parsed }
        }
        return nil
    }

    /** Non-child wait: kqueue `NOTE_EXIT` carries the wait(2) status in `data`.
        The queue is already armed; Darwin does not export the `WIFEXITED`
        macros as Swift functions, so the wait(2) layout is decoded here. */
    private static func waitForExit(pid: pid_t, queue: Int32) -> ProcessOutcome {
        defer { close(queue) }
        var event = kevent()
        let n = kevent(queue, nil, 0, &event, 1, nil)
        guard n > 0 else {
            return .spawnFailed(
                SpawnError(errno: Int(errno), message: "lost exit watch on pid \(pid)"))
        }
        guard let status = Int32(exactly: event.data) else {
            return .spawnFailed(
                SpawnError(
                    errno: nil, message: "exit status for pid \(pid) does not fit wait(2)"))
        }
        if (status & 0o177) == 0 {
            return .exited(code: Int((status >> 8) & 0xff))
        }
        let signal = status & 0o177
        if signal != 0, signal != 0o177 {
            return .signaled(signal: Int(signal))
        }
        return .exited(code: Int((status >> 8) & 0xff))
    }
}
