import Darwin
import DirectaKit
import Foundation

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

/** Spawns a bare, throwaway long-lived process to stand in for "a server pid a
    prior daemon recorded", independent of any supervisor or registry (a test
    that adopts it owns the only bookkeeping). `POSIX_SPAWN_SETSID` makes the
    returned pid a session leader, `pgid == pid`, the same property
    `SubprocessLauncher`'s `createSession` gives a real spawn: a group-directed
    teardown in a test can then never reach outside this one process, in
    particular never the test runner's own group. The process's lifetime is
    not tied to the test process, so every caller must kill it explicitly. */
func spawnSurvivor() throws -> pid_t {
    var pid: pid_t = 0
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    let argv: [UnsafeMutablePointer<CChar>?] = [
        strdup("/bin/sh"), strdup("-c"), strdup("sleep 30"), nil,
    ]
    defer { for arg in argv where arg != nil { free(arg) } }
    let status = posix_spawn(&pid, "/bin/sh", nil, &attr, argv, environ)
    guard status == 0 else {
        throw NSError(
            domain: "directa.test", code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "posix_spawn failed: \(String(cString: strerror(status)))"])
    }
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
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome {
        await inner.run(argv: argv, capture: capture, cwd: cwd, environment: environment, onSpawn: onSpawn)
    }

    func adopt(pid: pid_t, label: String) async -> ProcessOutcome? {
        await gate.outcome()
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
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome {
        guard let pid = try? spawnSurvivor() else {
            return .spawnFailed(SpawnError(message: "spawnSurvivor failed"))
        }
        await onSpawn(pid)
        return await gate.outcome()
    }

    func adopt(pid: pid_t, label: String) async -> ProcessOutcome? { nil }
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
