import Darwin
import DirectaKit
import Foundation
import Testing
import os

@testable import DirectaDaemonCore

/** Shared test support. The fixture-server lookup lived in six copies that had
    already drifted apart (one checked existence rather than executability, and
    looked in one location instead of two), so a suite could fail to find a
    binary its neighbour found. */

/** Every `LaunchdJobLauncher` a test constructs passes this instead of the
    production `LaunchdJobs.childLabelPrefix`, so a job bootstrapped under
    test is never matched by `LaunchdJobs.parseChildJobs`: the live daemon's
    `doctor` and leftover-job reap both read the real gui domain through that
    same parse, and a test job carrying the production prefix would be visible
    to them, and to a concurrently running smoke.sh, as a real leftover. */
let testLaunchdJobLabelPrefix = "dev.quantizor.directa.test-job."

/** The one raw `posix_spawn` for tests that need spawn attributes Foundation's
    `Process` cannot set (a new session, a signal mask, a Darwin SPI). The
    child inherits no descriptor but stdin, stdout, and stderr, each on
    /dev/null (`POSIX_SPAWN_CLOEXEC_DEFAULT`, the flag `swift-subprocess`
    passes on every spawn): a plain `posix_spawn` copies every descriptor the
    test process has open at that instant, including the write end of any
    pipe a concurrent test is draining, and that reader then waits for this
    child to exit rather than for the process it started. `flags` joins the
    close-on-exec default; `configure` sets any other attribute. The caller
    owns reaping. */
func spawnBare(
    _ argv: [String], flags: Int32 = 0,
    configure: (inout posix_spawnattr_t?) throws -> Void = { _ in }
) throws -> pid_t {
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | flags))
    try configure(&attr)

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

    var pid: pid_t = 0
    let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    defer { for arg in cArgs where arg != nil { free(arg) } }
    let status = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, environ)
    guard status == 0 else {
        throw NSError(
            domain: "directa.test", code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "posix_spawn failed: \(String(cString: strerror(status)))"])
    }
    return pid
}

/** Spawns a bare, throwaway long-lived process to stand in for "a server pid a
    prior daemon recorded", independent of any supervisor or registry (a test
    that adopts it owns the only bookkeeping). `POSIX_SPAWN_SETSID` makes the
    returned pid a session leader, `pgid == pid`, the same property
    `SubprocessLauncher`'s `createSession` gives a real spawn: a group-directed
    teardown in a test can then never reach outside this one process, in
    particular never the test runner's own group. The process's lifetime is
    not tied to the test process, so every caller must kill it explicitly. */
func spawnSurvivor() throws -> pid_t {
    let pid = try spawnBare(["/bin/sh", "-c", "sleep 30"], flags: POSIX_SPAWN_SETSID)
    /** `swift-subprocess` reaps its own children as part of awaiting their
        termination status; a bare `posix_spawn` here has no one else doing
        that. Without a reaper, a test's `kill(pid, 0)` liveness check can
        never observe the teardown it exists to prove: a zombie still answers
        that call with success until something calls `waitpid` on it. */
    let spawned = pid
    let reaper = Thread {
        var reapedStatus: Int32 = 0
        waitpid(spawned, &reapedStatus, 0)
    }
    reaper.start()
    return spawned
}

/** Resolves once `signal(_:)` is called (or immediately, if it already was),
    so a test controls exactly when a fake adopted child "exits" without tying
    that to a real process death. */
actor AdoptGate {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<ProcessOutcome, Never>?
    private var pending: ProcessOutcome?

    func outcome() async -> ProcessOutcome {
        callCount += 1
        if let pending { return pending }
        return await withCheckedContinuation { continuation = $0 }
    }

    func signal(_ outcome: ProcessOutcome) {
        if let continuation {
            continuation.resume(returning: outcome)
            self.continuation = nil
        } else {
            pending = outcome
        }
    }
}

/** `run` delegates to a real launcher so the bounce+respawn fallback still
    spawns for real; `adopt` is fully test-controlled through `gate`, which is
    what lets a test observe "adopted, not yet exited" independent of the real
    process the adopted pid names. */
struct FakeAdoptLauncher: ProcessLauncher {
    let gate: AdoptGate
    private let inner: any ProcessLauncher = SubprocessLauncher()

    func run(
        argv: [String], capture: SpawnCapture, cwd: String?, environment: [String: String],
        onExitedBeforeWatch: @escaping @Sendable (pid_t?) async -> Void,
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome {
        await inner.run(
            argv: argv, capture: capture, cwd: cwd, environment: environment,
            onExitedBeforeWatch: onExitedBeforeWatch, onSpawn: onSpawn)
    }

    func prepareAdopt(pid: pid_t) -> Bool { true }

    func adopt(pid: pid_t, label: String) async -> ProcessOutcome {
        await gate.outcome()
    }
}

/** A launchd child job whose exit watch cannot be armed (the pid died between
    the job listing and the arm, or the kernel refused the registration):
    `prepareAdopt` refuses every pid, while `run` spawns for real so the
    bounce+respawn fallback has something to start. Counts `prepareAdopt`
    calls so a test can tell "refused" apart from "never asked". */
final class UnwatchableAdoptLauncher: ProcessLauncher {
    private let inner: any ProcessLauncher = SubprocessLauncher()
    private let prepareCalls = OSAllocatedUnfairLock(initialState: 0)

    var prepareCallCount: Int { prepareCalls.withLock { $0 } }

    func run(
        argv: [String], capture: SpawnCapture, cwd: String?, environment: [String: String],
        onExitedBeforeWatch: @escaping @Sendable (pid_t?) async -> Void,
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome {
        await inner.run(
            argv: argv, capture: capture, cwd: cwd, environment: environment,
            onExitedBeforeWatch: onExitedBeforeWatch, onSpawn: onSpawn)
    }

    func prepareAdopt(pid: pid_t) -> Bool {
        prepareCalls.withLock { $0 += 1 }
        return false
    }

    func adopt(pid: pid_t, label: String) async -> ProcessOutcome {
        Issue.record("adopt(pid:label:) ran after prepareAdopt refused pid \(pid)")
        return .spawnFailed(SpawnError(message: "adopt after a refused prepareAdopt"))
    }
}

/** The launchd shape of a command that exits before its exit watch is armed,
    without a live launchd job: writes `stderrText` to the capture, reports
    `pid` through `onExitedBeforeWatch` (never `onSpawn`), and returns the
    status-unknown outcome `LaunchdJobLauncher` reports for that case. A nil
    `pid` is the job launchd never showed a pid for. The narrow path never
    signals the pid, and a non-nil one here is past the kernel's pid range
    so it could not reach a live process even if it did. */
struct ExitedBeforeWatchLauncher: ProcessLauncher {
    let pid: pid_t?
    let stderrText: String

    func run(
        argv: [String], capture: SpawnCapture, cwd: String?, environment: [String: String],
        onExitedBeforeWatch: @escaping @Sendable (pid_t?) async -> Void,
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome {
        let bytes = Array(stderrText.utf8)
        let written = bytes.withUnsafeBytes { write(capture.stderrFD, $0.baseAddress, $0.count) }
        guard written == bytes.count else {
            return .spawnFailed(SpawnError(message: "could not write the fake child's stderr"))
        }
        await onExitedBeforeWatch(pid)
        return .exitedStatusUnknown
    }

    func prepareAdopt(pid: pid_t) -> Bool { false }

    func adopt(pid: pid_t, label: String) async -> ProcessOutcome {
        .spawnFailed(SpawnError(message: "ExitedBeforeWatchLauncher never adopts"))
    }
}

/** `run` reports a real, killable pid through `onSpawn` (`signalRun`'s `kill`
    calls need a real process to act on) and then blocks on `gate` exactly like
    `FakeAdoptLauncher.adopt`, independent of whether that pid is still alive:
    the deterministic stand-in for "the child exited but recordOutcome was
    never told," which is what lets a bounded wait for that outcome be tested
    without a real multi-second sleep or a race against how fast a flood
    drains. */
struct StuckRunLauncher: ProcessLauncher {
    let gate: AdoptGate

    func run(
        argv: [String], capture: SpawnCapture, cwd: String?, environment: [String: String],
        onExitedBeforeWatch: @escaping @Sendable (pid_t?) async -> Void,
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome {
        guard let pid = try? spawnSurvivor() else {
            return .spawnFailed(SpawnError(message: "spawnSurvivor failed"))
        }
        await onSpawn(pid)
        return await gate.outcome()
    }

    func prepareAdopt(pid: pid_t) -> Bool { false }

    func adopt(pid: pid_t, label: String) async -> ProcessOutcome {
        .spawnFailed(SpawnError(message: "StuckRunLauncher never adopts"))
    }
}

/** A one-way latch: `wait` suspends until `open`, and returns at once after. */
actor SpawnGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/** The launchd shape of a job whose pid publishes a moment after the process
    exists: the real process runs (through `SubprocessLauncher`) while
    `onSpawn` is held behind `gate`, so the supervisor sits in `.starting` with
    no pid. Records every spawned pid so a test can check (and clean up) the
    process itself. */
final class DelayedSpawnLauncher: ProcessLauncher {
    let gate: SpawnGate
    private let inner: any ProcessLauncher = SubprocessLauncher()
    private let spawned = OSAllocatedUnfairLock(initialState: [pid_t]())

    init(gate: SpawnGate) {
        self.gate = gate
    }

    var pids: [pid_t] { spawned.withLock { $0 } }

    func run(
        argv: [String], capture: SpawnCapture, cwd: String?, environment: [String: String],
        onExitedBeforeWatch: @escaping @Sendable (pid_t?) async -> Void,
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome {
        await inner.run(
            argv: argv, capture: capture, cwd: cwd, environment: environment,
            onExitedBeforeWatch: onExitedBeforeWatch,
            onSpawn: { [gate, spawned] pid in
                spawned.withLock { $0.append(pid) }
                await gate.wait()
                await onSpawn(pid)
            })
    }

    func prepareAdopt(pid: pid_t) -> Bool { false }

    func adopt(pid: pid_t, label: String) async -> ProcessOutcome {
        .spawnFailed(SpawnError(message: "DelayedSpawnLauncher never adopts"))
    }
}

/** Ports the unit suites allocate from. Reserved as a block so the stray reaper
    below can tell this suite's leftovers from any other directa process on the
    machine, and so a new test picks its port from a documented range instead of
    guessing at a free number. */
enum TestPorts {
    /** Wide enough to cover the suites that draw a random port as well as the
        hand-assigned literals. It first stopped at 45500, which left
        `ResourceLockTests` outside it at 41_000 and 42_000: those fixtures went
        unreaped, and worse, they shared a range with `scripts/smoke.sh`, which
        draws its project-phase ports from 41000 too. Widening to reach them
        would have pointed the reaper at smoke's fixtures, so the suites moved
        in here instead. Anything added below must stay clear of smoke's 39000
        and 41000 ranges. */
    static let range = 45000..<46000

    static func owns(_ port: Int) -> Bool { range.contains(port) }
}

/** Path to the built fixture-server, or nil when it has not been built.

    Touching this also reaps strays exactly once per test process; see
    `strayFixturesReaped`. Every suite that spawns a fixture goes through here,
    so there is no separate step to forget. */
func fixtureServerExecutable() -> String? {
    _ = strayFixturesReaped
    return fixtureServerBinaryPath()
}

/** The lookup on its own, with no reaping, so the reaper can find the binary it
    is matching against without recursing back into itself. */
private func fixtureServerBinaryPath() -> String? {
    let candidates = [
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: ".build/debug/fixture-server"),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/debug/fixture-server"),
    ]
    return candidates.map(\.path).first { FileManager.default.isExecutableFile(atPath: $0) }
}

/** A Swift global initializes lazily and exactly once, which is the whole
    mechanism: the first suite to ask for the fixture pays for the sweep and
    every later one gets the cached value. */
private let strayFixturesReaped: Bool = {
    reapStrayFixtureServers()
    return true
}()

/** Kills fixture-servers left holding a unit-suite port by a run that was
    interrupted before it could stop them.

    A supervised child outliving its daemon is deliberate product behavior, not
    a leak, so the cleanup belongs to whoever spawned it. When a run is killed
    part way that owner is gone, and the next run fails somewhere unrelated with
    `port-held` naming a pid nothing is tracking. That cost this suite two runs
    before it was worth automating.

    Two conditions, both required, keep this from reaching a process it does not
    own. The parent must be gone (`ppid == 1`): a fixture belonging to a live run
    is parented by that run's test process, so a second concurrent `swift test`
    is untouched. And the command line must name a port this suite reserves,
    which is what keeps it away from `scripts/smoke.sh`, whose fixtures use their
    own ranges and are deliberately orphaned by its daemon-kill assertions. */
private func reapStrayFixtureServers() {
    guard let binary = fixtureServerBinaryPath() else { return }
    let name = (binary as NSString).lastPathComponent
    var killed: [pid_t] = []
    for candidate in runningProcesses()
    where shouldReapStray(command: candidate.command, parent: candidate.parent, binaryName: name) {
        kill(candidate.pid, SIGKILL)
        killed.append(candidate.pid)
    }
    /** Waits for the kernel to actually tear them down. SIGKILL returns
        immediately but the listening socket outlives the call by a moment, and a
        suite that spawned straight afterwards raced it and failed with
        `port-held` naming a pid this had just killed: a cleanup that does not
        wait for its own effect is only half a cleanup. */
    for _ in 0..<100 where !killed.isEmpty {
        killed = killed.filter { kill($0, 0) == 0 }
        if killed.isEmpty { break }
        usleep(20_000)
    }
}

/** The decision on its own, so both halves are testable without spawning
    anything: the two it must kill and, more importantly, the two it must not. */
func shouldReapStray(command: String, parent: pid_t, binaryName: String) -> Bool {
    /** Matched by name rather than by absolute path. A fixture launched through
        a relative path appears in `ps` exactly as invoked, so a full-path match
        silently skipped it, and a cleanup that quietly skips its target is
        indistinguishable from one that works. */
    guard command.contains(binaryName) else { return false }
    guard parent == 1 else { return false }
    return command.split(separator: " ").compactMap { Int($0) }.contains(where: TestPorts.owns)
}

private struct RunningProcess {
    let command: String
    let parent: pid_t
    let pid: pid_t
}

/** `ps` rather than the sysctl sweep in DirectaDaemonCore, because the full
    command line is the thing being matched and `kinfo_proc` does not carry it. */
private func runningProcesses() -> [RunningProcess] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-A", "-o", "pid=,ppid=,command="]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return [] }
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    process.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1])
        else { return nil }
        return RunningProcess(
            command: fields.dropFirst(2).joined(separator: " "), parent: parent, pid: pid)
    }
}
