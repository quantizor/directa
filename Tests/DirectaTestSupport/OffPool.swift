import Foundation

/** The one home for a test's work that blocks its thread: a process wait, a
    semaphore, a `waitpid`, a polling loop that sleeps. A test body runs on
    Swift's cooperative pool, which has one thread per core (three on a CI
    runner), and every suite runs in parallel on that same pool alongside the
    code under test. A body that blocks there takes a thread from all of them,
    so a few such tests at once stall the supervisors, tailers, and lanes the
    other tests are waiting on, and a body that blocks until pool work runs can
    wait on itself forever. `offPool` runs `work` on a thread of its own and
    suspends the caller, which gives its pool thread back until `work` returns.

    The caller's `TemporaryTree` scope is carried onto that thread, so
    `TemporaryTree.directory(named:)` works inside `work`. */
public func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let scope = TemporaryTree.scope
    return try await withCheckedThrowingContinuation { continuation in
        let thread = Thread {
            continuation.resume(with: Result { try TemporaryTree.$scope.withValue(scope) { try work() } })
        }
        thread.name = "directa-test-off-pool"
        thread.start()
    }
}

/** `offPool` for work that cannot throw. */
public func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    let scope = TemporaryTree.scope
    return await withCheckedContinuation { continuation in
        let thread = Thread {
            continuation.resume(returning: TemporaryTree.$scope.withValue(scope) { work() })
        }
        thread.name = "directa-test-off-pool"
        thread.start()
    }
}

/** A setup process `TestProcess.succeed` ran exited nonzero. */
public struct TestProcessError: Error, CustomStringConvertible {
    public let arguments: [String]
    public let status: Int32

    public var description: String { "\(arguments.joined(separator: " ")) exited \(status)" }
}

/** How one `TestProcess.run` ended. */
public struct TestProcessResult: Sendable {
    public let output: String
    /** The exited process's pid, which a test uses as one that names no
        process until the system reuses it. */
    public let pid: pid_t
    public let status: Int32
}

/** The one process runner for test setup (git fixtures, `ps` evidence, a
    shell probe): runs the executable to the end off the cooperative pool and
    returns its status and standard output, standard error discarded. */
public enum TestProcess {
    public static func run(
        _ executable: String, _ arguments: [String], currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> TestProcessResult {
        try await offPool { try runBlocking(executable, arguments, currentDirectory: currentDirectory, environment: environment) }
    }

    /** `run`, throwing at the call that failed when the process exits
        nonzero, so a setup step that quietly fails (no git, no worktree
        support, a permissions problem) is named where it broke rather than
        surfacing as a confusing assertion several lines later. */
    public static func succeed(
        _ executable: String, _ arguments: [String], in currentDirectory: URL
    ) async throws {
        let result = try await run(executable, arguments, currentDirectory: currentDirectory)
        guard result.status == 0 else {
            throw TestProcessError(arguments: [executable] + arguments, status: result.status)
        }
    }

    /** `run` on the calling thread, for work already inside `offPool`. */
    public static func runBlocking(
        _ executable: String, _ arguments: [String], currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> TestProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return TestProcessResult(
            output: String(decoding: data, as: UTF8.self), pid: process.processIdentifier,
            status: process.terminationStatus)
    }
}
