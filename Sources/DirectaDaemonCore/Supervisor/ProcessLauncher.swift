import DirectaKit
import Foundation
import Subprocess
import System

/** Outcome of a completed (or never-started) child process. */
public enum ProcessOutcome: Sendable {
    case exited(code: Int)
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
        capture. Reports the pid via `onSpawn` as soon as it exists, then returns
        only when the process has terminated. */
    func run(
        argv: [String],
        capture: SpawnCapture,
        cwd: String?,
        environment: [String: String],
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome
}

public struct SubprocessLauncher: ProcessLauncher {
    public init() {}

    public func run(
        argv: [String],
        capture: SpawnCapture,
        cwd: String?,
        environment: [String: String],
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
