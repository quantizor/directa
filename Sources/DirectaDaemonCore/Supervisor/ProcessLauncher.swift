import DirectaKit
import Foundation
import Subprocess
import System

/** Outcome of a completed (or never-started) child process. */
public enum ProcessOutcome: Sendable {
    case exited(code: Int)
    /** The process exited, but its wait(2) status could not be read: the
        kernel refused `NOTE_EXITSTATUS` (EACCES) because the daemon may not
        signal it, the permission `EVFILT_PROC` gates the note on. Neither a
        code nor a signal is known. */
    case exitedStatusUnknown
    case signaled(signal: Int)
    case spawnFailed(SpawnError)
}

/** Spool destinations for a spawn. SubprocessLauncher dups stdoutFD/stderrFD;
    LaunchdJobLauncher reopens stdoutPath/stderrPath (it cannot inherit the
    daemon's fds). */
public struct SpawnCapture: Sendable {
    public let stderrFD: Int32
    public let stderrPath: String
    public let stdoutFD: Int32
    public let stdoutPath: String

    public init(stderrFD: Int32, stderrPath: String, stdoutFD: Int32, stdoutPath: String) {
        self.stderrFD = stderrFD
        self.stderrPath = stderrPath
        self.stdoutFD = stdoutFD
        self.stdoutPath = stdoutPath
    }
}

/** Seam isolating swift-subprocess (pre-1.0) from the supervisor. The fallback
    implementation, if the API churns, is ~200 lines of posix_spawn +
    POSIX_SPAWN_SETSID + kqueue EVFILT_PROC; the protocol is shaped so that swap
    stays invisible to callers. */
public protocol ProcessLauncher: Sendable {
    /** Spawns `argv` in a fresh session with stdout and stderr on the spool
        capture, then returns only when the process has terminated. Exactly one
        callback runs before that return unless the spawn itself failed.
        `onSpawn` reports a pid whose exit is being watched and that leads its
        own session (its session id is the pid): the run is supervised from
        that moment on, and teardown keys its session sweep on that pid
        without asking a process that may already have exited. An
        implementation that can learn of
        the process only after it already exited (the launchd path, when the
        job dies before its exit watch is armed, or before launchd ever
        showed its pid, which is then nil) calls `onExitedBeforeWatch`
        instead, so the caller drains the spool without treating the run as
        one that ever started. */
    func run(
        argv: [String],
        capture: SpawnCapture,
        cwd: String?,
        environment: [String: String],
        onExitedBeforeWatch: @escaping @Sendable (pid_t?) async -> Void,
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome

    /** Arms the exit watch for a process this launcher did not spawn, before
        the caller records anything about it. False means the pid cannot be
        watched (an implementation with no way to watch a non-child, or a pid
        already gone), and the caller bounces the process instead of adopting
        it. The only arm on the adopt path: arming again would replace the
        watch and could drop an exit that already arrived. */
    func prepareAdopt(pid: pid_t) -> Bool

    /** Waits on a process a successful `prepareAdopt` armed: a launchd child
        job (`label`) that survived a jetsam SIGKILL of the daemon. Returns only
        when the process terminates, exactly like `run`, with no callback since
        the pid is already known. Never arms, so an exit that landed between
        `prepareAdopt` and this call is still reported. */
    func adopt(pid: pid_t, label: String) async -> ProcessOutcome
}

public struct SubprocessLauncher: ProcessLauncher {
    public init() {}

    public func run(
        argv: [String],
        capture: SpawnCapture,
        cwd: String?,
        environment: [String: String],
        onExitedBeforeWatch: @escaping @Sendable (pid_t?) async -> Void,
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome {
        guard let first = argv.first, !first.isEmpty else {
            return .spawnFailed(SpawnError(errno: Int(EINVAL), message: "empty command"))
        }
        let executable: Executable = first.contains("/")
            ? .path(FilePath(first))
            : .name(first)
        var options = PlatformOptions()
        /** New session ⇒ new process group whose pgid == child pid, which is what
            group-directed SIGTERM/SIGKILL teardown relies on. */
        options.createSession = true
        let outFD = FileDescriptor(rawValue: capture.stdoutFD)
        let errFD = FileDescriptor(rawValue: capture.stderrFD)
        do {
            var inherited: [Subprocess.Environment.Key: String?] = [:]
            for (key, value) in environment {
                inherited[Subprocess.Environment.Key(stringLiteral: key)] = value
            }
            let result = try await Subprocess.run(
                executable,
                arguments: Arguments(Array(argv.dropFirst())),
                environment: .inherit.updating(inherited),
                workingDirectory: cwd.map { FilePath($0) },
                platformOptions: options,
                input: .none,
                output: .fileDescriptor(outFD, closeAfterSpawningProcess: false),
                error: .fileDescriptor(errFD, closeAfterSpawningProcess: false)
            ) { execution in
                await onSpawn(execution.processIdentifier.value)
            }
            switch result.terminationStatus {
            case .exited(let code):
                return .exited(code: Int(code))
            case .signaled(let signal):
                return .signaled(signal: Int(signal))
            }
        } catch {
            return .spawnFailed(Self.spawnError(from: error))
        }
    }

    /** Never adopts: a foreground/test run has no launchd job to re-watch, so
        the caller falls back to bouncing the orphan. */
    public func prepareAdopt(pid: pid_t) -> Bool {
        false
    }

    /** Unreachable while `prepareAdopt` refuses every pid; reports a spawn
        failure rather than an exit that never happened. */
    public func adopt(pid: pid_t, label: String) async -> ProcessOutcome {
        .spawnFailed(SpawnError(message: "adopting a running process needs launchd agent mode"))
    }

    /** Best-effort errno extraction from SubprocessError; the message always
        carries the full description so nothing is lost when extraction fails. */
    static func spawnError(from error: any Error) -> SpawnError {
        let message = String(describing: error)
        if let subprocessError = error as? SubprocessError,
            let underlying = subprocessError.underlyingError {
            return SpawnError(errno: Int(underlying.rawValue), message: message)
        }
        return SpawnError(errno: nil, message: message)
    }
}
