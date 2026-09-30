import Foundation

/** How one `HelperCommand.run` ended. */
public enum ShellOutcome: Equatable, Sendable {
    /** The child ran to the end; `output` is everything it wrote. */
    case exited(status: Int32, output: String)
    /** The child could not be started; the payload says why. */
    case failedToRun(String)
    /** The child, or a process holding its output open, outlived the
        timeout; `partialOutput` is what arrived before it. */
    case timedOut(partialOutput: String)
    /** The child wrote more than `HelperCommand.outputLimitBytes` and its
        process group was killed; `partialOutput` is the first
        `outputLimitBytes` of what it wrote. */
    case outputLimitExceeded(partialOutput: String)
}

/** The one home for running a short helper command (git, launchctl, lsof,
    ps, a shell profile) to the end on the calling thread alone: its output
    pipe is drained with poll(2) up to the deadline, so a child that fills the
    pipe buffer always has a reader and no second thread is needed, and a
    process that inherited the pipe (a grandchild the command backgrounded)
    cannot hold the caller past the deadline. At the deadline the command's
    process group is killed: Foundation's `Process` starts every child as the
    leader of a new group, so that reaches the command and anything it started
    that stayed in the group, and never the caller. */
public enum HelperCommand {
    /** How long `launchctl` gets when a caller names no timeout, for the verbs
        that answer from launchd's own state (`print`, `list`, `bootstrap`,
        `kickstart` without `-k`). They normally finish in a few milliseconds;
        this leaves room for a launchd that is itself slow under memory
        pressure without letting a hung one hold a lane thread for long. */
    public static let launchctlTimeoutSeconds: Double = 10

    /** How long `launchctl bootout` and `launchctl kickstart -k` get when a
        caller names no timeout. Both wait for the job's process to exit,
        which launchd allows up to the job's `ExitTimeOut` before it escalates
        to SIGKILL, and launchd refuses an `ExitTimeOut` past 60 seconds. */
    public static let launchctlJobExitTimeoutSeconds: Double = 75

    /** `lsof` normally finishes in tens of milliseconds. */
    public static let lsofTimeoutSeconds: Double = 10

    /** `ps` normally finishes in a few milliseconds. */
    public static let psTimeoutSeconds: Double = 5

    /** How much output a command may write before its process group is killed
        exactly as at a deadline. Every helper here answers with a few lines
        to a few hundred kilobytes; the cap keeps a runaway writer from
        growing the daemon's memory until its deadline, or for ever when it
        has none. */
    public static let outputLimitBytes = 4 * 1024 * 1024

    /** The deadline a command gets when its caller names none: one of the
        constants above for launchctl, lsof, and ps, and nil (wait for the
        command to finish) for everything else, which is either directa's own
        CLI run from the app or a command a person is waiting on (`git fetch`
        during `switch`, `open`). */
    public static func defaultTimeoutSeconds(executable path: String, arguments: [String]) -> Double? {
        switch (path as NSString).lastPathComponent {
        case "launchctl":
            let waitsForExit =
                arguments.first == "bootout" || (arguments.first == "kickstart" && arguments.contains("-k"))
            return waitsForExit ? launchctlJobExitTimeoutSeconds : launchctlTimeoutSeconds
        case "lsof":
            return lsofTimeoutSeconds
        case "ps":
            return psTimeoutSeconds
        default:
            return nil
        }
    }

    /** Runs `path` with `arguments` to the end, reported to `DaemonActivity`
        by executable name. `environment` nil inherits this process's, and
        `currentDirectory` nil keeps this process's. `includeStderr` merges
        stderr into the output, which is what a caller reporting a failure
        wants; pass false where the output is parsed as a value, and stderr is
        discarded. `timeoutSeconds` nil waits for the command and for every
        process holding its output. */
    public static func run(
        _ path: String, _ arguments: [String], currentDirectory: String? = nil,
        environment: [String: String]? = nil, includeStderr: Bool = true, timeoutSeconds: Double?
    ) -> ShellOutcome {
        var label = ([(path as NSString).lastPathComponent] + arguments).joined(separator: " ")
        if let currentDirectory { label += " in \(currentDirectory)" }
        let token = DaemonActivity.shared.begin(ActivityKind.forExecutable(path), label: label)
        let outcome = runUnmeasured(
            path, arguments, currentDirectory: currentDirectory, environment: environment,
            includeStderr: includeStderr, timeoutSeconds: timeoutSeconds)
        switch outcome {
        case .timedOut:
            DaemonActivity.shared.end(token, outcome: "timed out")
            DirectaLog.daemon.error(
                "helper command timed out after \(timeoutSeconds ?? 0)s and its process group was killed: \(label)")
        case .outputLimitExceeded:
            DaemonActivity.shared.end(token, outcome: "output limit exceeded")
            DirectaLog.daemon.error(
                "helper command wrote more than \(outputLimitBytes) bytes and its process group was killed: \(label)")
        case .exited, .failedToRun:
            DaemonActivity.shared.end(token)
        }
        return outcome
    }

    private static func runUnmeasured(
        _ path: String, _ arguments: [String], currentDirectory: String?,
        environment: [String: String]?, includeStderr: Bool, timeoutSeconds: Double?
    ) -> ShellOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = includeStderr ? pipe : FileHandle.nullDevice
        /** Installed before `run()`, not after: a child that exits in the window
            between `run()` returning and a later assignment is already terminated
            when the handler is set, and Foundation does not fire terminationHandler
            for an already-dead process. The wait below would then run out its
            full ceiling and treat a finished child as timed out. */
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failedToRun(String(describing: error))
        }
        let reader = pipe.fileHandleForReading.fileDescriptor
        var output = Data()
        guard let timeoutSeconds else {
            if drain(reader, into: &output, until: nil) == .overLimit {
                killGroup(of: process, exited: exited, pipeStillHeld: true)
                return .outputLimitExceeded(partialOutput: decodedCapped(output))
            }
            exited.wait()
            return .exited(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
        }
        /** Bounded before it becomes a Duration, which traps on a non-finite
            value. */
        let boundedSeconds = timeoutSeconds.isFinite ? min(max(timeoutSeconds, 0), 86_400) : 86_400
        let deadline = ContinuousClock.now.advanced(by: .seconds(boundedSeconds))
        let end = drain(reader, into: &output, until: deadline)
        if end == .endOfFile,
            exited.wait(timeout: .now() + max(ContinuousClock.now.duration(to: deadline) / .seconds(1), 0))
                == .success
        {
            return .exited(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
        }
        killGroup(of: process, exited: exited, pipeStillHeld: end != .endOfFile)
        if end == .overLimit {
            return .outputLimitExceeded(partialOutput: decodedCapped(output))
        }
        /** What the command wrote before it died is still in the pipe. */
        _ = drain(reader, into: &output, until: ContinuousClock.now.advanced(by: .milliseconds(200)))
        return .timedOut(partialOutput: decodedCapped(output))
    }

    /** SIGKILL rather than SIGTERM: this is already the path where the child
        ignored its chance to finish, and a profile blocked on a read will not
        act on a term either. The group is signaled only while something still
        belongs to it: the command itself still running, or the pipe still
        held open, whose holder inherited the group. A group id stays reserved
        while any member lives, and once the group is empty the id could only
        name a stranger after the pid space wrapped within this one deadline. */
    private static func killGroup(of process: Process, exited: DispatchSemaphore, pipeStillHeld: Bool) {
        guard process.isRunning || pipeStillHeld else { return }
        kill(-process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + 2)
    }

    /** `output` as text, cut to the output cap: the drain stops within one
        read of the cap, so a kill's last reads can leave a little more. */
    private static func decodedCapped(_ output: Data) -> String {
        String(decoding: output.prefix(outputLimitBytes), as: UTF8.self)
    }

    private enum DrainEnd {
        /** The deadline passed, or the pipe could not be read. */
        case deadline
        case endOfFile
        /** More than `outputLimitBytes` arrived. */
        case overLimit
    }

    /** Reads `fd` into `output` until end of file, `deadline` (nil never
        passes), or more than the output cap has arrived, polling so the wait
        needs no second thread. */
    private static func drain(
        _ fd: Int32, into output: inout Data, until deadline: ContinuousClock.Instant?
    ) -> DrainEnd {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var request = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = deadline.map { ContinuousClock.now.duration(to: $0) }
            /** -1 is poll's "no timeout". */
            let timeoutMilliseconds = remaining.map {
                Int32(clamping: Int(min(max($0 / .milliseconds(1), 0).rounded(.up), Double(Int32.max))))
            } ?? -1
            let ready = poll(&request, 1, timeoutMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                return .deadline
            }
            if ready == 0 {
                if let remaining, remaining <= .zero { return .deadline }
                continue
            }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer[0..<count])
                if output.count > outputLimitBytes { return .overLimit }
            } else if count == 0 {
                return .endOfFile
            } else if errno != EINTR, errno != EAGAIN {
                return .deadline
            }
        }
    }
}
