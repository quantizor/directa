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
        if case .timedOut = outcome {
            DaemonActivity.shared.end(token, outcome: "timed out")
            DirectaLog.daemon.error(
                "helper command timed out after \(timeoutSeconds ?? 0)s and its process group was killed: \(label)")
        } else {
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
            _ = drain(reader, into: &output, until: nil)
            exited.wait()
            return .exited(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
        }
        /** Bounded before it becomes a Duration, which traps on a non-finite
            value. */
        let boundedSeconds = timeoutSeconds.isFinite ? min(max(timeoutSeconds, 0), 86_400) : 86_400
        let deadline = ContinuousClock.now.advanced(by: .seconds(boundedSeconds))
        let reachedEndOfFile = drain(reader, into: &output, until: deadline)
        if reachedEndOfFile,
            exited.wait(timeout: .now() + max(ContinuousClock.now.duration(to: deadline) / .seconds(1), 0))
                == .success
        {
            return .exited(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
        }
        /** SIGKILL rather than SIGTERM: this is already the path where the
            child ignored its chance to finish, and a profile blocked on a read
            will not act on a term either. The group is signaled only while
            something still belongs to it: the command itself still running,
            or the pipe still held open, whose holder inherited the group. A
            group id stays reserved while any member lives, and once the group
            is empty the id could only name a stranger after the pid space
            wrapped within this one deadline. */
        let pid = process.processIdentifier
        if process.isRunning || !reachedEndOfFile {
            kill(-pid, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
        }
        /** What the command wrote before it died is still in the pipe. */
        _ = drain(reader, into: &output, until: ContinuousClock.now.advanced(by: .milliseconds(200)))
        return .timedOut(partialOutput: String(decoding: output, as: UTF8.self))
    }

    /** Reads `fd` into `output` until end of file (true) or `deadline`
        (false; nil never passes), polling so the wait needs no second
        thread. */
    private static func drain(
        _ fd: Int32, into output: inout Data, until deadline: ContinuousClock.Instant?
    ) -> Bool {
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
                return false
            }
            if ready == 0 {
                if let remaining, remaining <= .zero { return false }
                continue
            }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                return true
            } else if errno != EINTR, errno != EAGAIN {
                return false
            }
        }
    }
}
