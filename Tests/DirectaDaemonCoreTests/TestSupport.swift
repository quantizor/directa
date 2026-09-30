import Darwin
import DirectaKit
import DirectaTestSupport
import Foundation
import Testing
import os

@testable import DirectaDaemonCore

/** Shared support for the daemon-core suites: raw spawns (`spawnBare` and
    its wrappers), daemon-specific polling (`awaitPhase`; the generic waits
    live in Tests/DirectaTestSupport/Polling.swift), a Router over scratch
    paths (`makeRouterEnv`, `Router.call`/`attempt`), one-shot latches, fake
    launchers, the per-run port block (`TestPorts`), and the fixture-server
    lookup with its stray reaper. */

// MARK: - Launchd jobs

/** Every `LaunchdJobLauncher` a test runs carries this prefix instead of the
    production `LaunchdJobs.childLabelPrefix`, so a job bootstrapped under
    test is never matched by `LaunchdJobs.parseChildJobs`: the live daemon's
    `doctor` and leftover-job reap both read the real gui domain through that
    same parse, and a test job carrying the production prefix would be visible
    to them, and to a concurrently running smoke.sh, as a real leftover. */
let testLaunchdJobLabelPrefix = "dev.quantizor.directa.test-job."

/** A kernel unique id no process ever carries: the kernel counts them up
    from 1 each boot and never reuses one, so it never reaches this value.
    A test that makes up the identity of a root other than the live one uses
    it, since the lineage walk treats that root's unique id as a parent to
    sweep: a neighbor of a real id (the real one plus 1) is whichever process
    the machine created next, often a concurrent test's with children of its
    own, which the walk would then find and a stop would signal. */
let unissuedUniqueID = UInt64.max

/** The one way a test builds a `LaunchdJobLauncher`;
    `aLaunchdJobLauncherIsOnlyBuiltThroughTheTestFactory` fails any other
    construction under Tests. */
func testLaunchdJobLauncher() -> LaunchdJobLauncher {
    LaunchdJobLauncher(labelPrefix: testLaunchdJobLabelPrefix)
}

// MARK: - Raw spawns

/** The one raw `posix_spawn` for tests that need spawn attributes Foundation's
    `Process` cannot set (a new session, a Darwin SPI). The child inherits no
    descriptor but stdin, stdout, and stderr, each on /dev/null unless
    `stdoutFD` names the descriptor its stdout is duplicated from
    (`POSIX_SPAWN_CLOEXEC_DEFAULT`, the flag `swift-subprocess` passes on
    every spawn): a plain `posix_spawn` copies every descriptor the test
    process has open at that instant, including the write end of any pipe a
    concurrent test is draining, and that reader then waits for this child to
    exit rather than for the process it started.

    The child's signal mask is emptied and every disposition reset to default
    (`POSIX_SPAWN_SETSIGMASK` / `POSIX_SPAWN_SETSIGDEF`, the same pair
    `swift-subprocess` passes): the test runner's threads can have SIGTERM
    blocked, and a child inheriting that mask never notices a stop's SIGTERM,
    so a teardown test would pass or fail on which pool thread spawned it.
    `flags` joins these defaults; `configure` sets any other attribute. The
    caller owns reaping. */
func spawnBare(
    _ argv: [String], flags: Int32 = 0, stdoutFD: Int32? = nil,
    configure: (inout posix_spawnattr_t?) throws -> Void = { _ in }
) throws -> pid_t {
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(
        &attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | flags))
    var noSignals = sigset_t()
    var allSignals = sigset_t()
    sigemptyset(&noSignals)
    sigfillset(&allSignals)
    posix_spawnattr_setsigmask(&attr, &noSignals)
    posix_spawnattr_setsigdefault(&attr, &allSignals)
    try configure(&attr)

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    if let stdoutFD {
        posix_spawn_file_actions_adddup2(&actions, stdoutFD, STDOUT_FILENO)
    } else {
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    }
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

/** `argv`'s whole stdout, read to end of file, with the child reaped by
    `waitpid` rather than Foundation's `Process`, whose `waitUntilExit` spins a
    run loop on the calling cooperative thread. Blocks its caller, so it is for
    synchronous setup only (the stray reaper's `ps`); async code goes through
    `TestProcess`. */
func captureOutput(_ argv: [String]) throws -> String {
    let output = try makeOutputPipe()
    defer { close(output.read) }
    let spawned = Result { try spawnBare(argv, stdoutFD: output.write) }
    close(output.write)
    let pid = try spawned.get()
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(output.read, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    return String(decoding: data, as: UTF8.self)
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
    try spawnReapedSessionLeader(["/bin/sh", "-c", "sleep 30"])
}

/** `argv` as a session leader nothing supervises, reaped the moment it exits,
    its stdout on `stdoutFD` when given (as `spawnBare`). The caller owns
    killing it. */
func spawnReapedSessionLeader(_ argv: [String], stdoutFD: Int32? = nil) throws -> pid_t {
    let pid = try spawnBare(argv, flags: POSIX_SPAWN_SETSID, stdoutFD: stdoutFD)
    /** `swift-subprocess` reaps its own children as part of awaiting their
        termination status; a bare `posix_spawn` here has no one else doing
        that. Without a reaper, a test's `kill(pid, 0)` liveness check can
        never observe the teardown it exists to prove: a zombie still answers
        that call with success until something calls `waitpid` on it. */
    let reaper = Thread {
        var reapedStatus: Int32 = 0
        waitpid(pid, &reapedStatus, 0)
    }
    reaper.start()
    return pid
}

/** A pipe for a spawned root's stdout: the test reads the read end, passes
    the write end as `stdoutFD`, and closes the write end once the spawn has
    happened. Both ends are close-on-exec, so no other spawn inherits them. */
func makeOutputPipe() throws -> (read: Int32, write: Int32) {
    var fds: [Int32] = [0, 0]
    try #require(pipe(&fds) == 0)
    for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    return (fds[0], fds[1])
}

/** The pid a fixture's `--setsid-listener` prints, read from `fd`. Stops at
    that line rather than end of file, since the listener keeps the same
    stdout open for as long as it lives; nil if every writer closes first or
    nothing arrives within `within`, so a listener that holds stdout open
    without printing fails the test rather than hanging it. */
func readSetsidListenerPid(from fd: Int32, within limit: Duration = .seconds(10)) -> pid_t? {
    let pattern = #/setsid listener pid (\d+)\n/#
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    var text = ""
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        if let match = text.firstMatch(of: pattern) { return pid_t(match.1) }
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return nil }
        let (seconds, attoseconds) = remaining.components
        let milliseconds = Int32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000)
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, max(1, milliseconds)) > 0 else { return nil }
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        text += String(decoding: buffer.prefix(count), as: UTF8.self)
    }
}

/** `readSetsidListenerPid` from async code: the read blocks until the
    fixture prints, so it runs off the pool. Swift picks this form in any
    async context, so a test that forgets `await` does not compile. */
func readSetsidListenerPid(from fd: Int32) async -> pid_t? {
    await offPool { readSetsidListenerPid(from: fd) }
}

// MARK: - Polling

/** The supervisor's status once its phase is `phase`, or its latest status
    when `limit` elapses first, so the caller's own `#expect` names what it
    saw. */
func awaitPhase(
    _ supervisor: ServerSupervisor, _ phase: ServerPhase, within limit: Duration = .seconds(5)
) async throws -> ServerStatus {
    var latest = await supervisor.status()
    _ = try await eventually(within: limit) {
        latest = await supervisor.status()
        return latest.phase == phase
    }
    return latest
}

/** The pid a fixture printed as a whole `<label> pid <n>` line (`grandchild`,
    `setsid listener`) into the file at `url`, once it appears within
    `limit`; a line still being written does not count. */
func printedPid(_ label: String, in url: URL, within limit: Duration = .seconds(5)) async throws -> pid_t? {
    let marker = "\(label) pid "
    return try await firstAnswer(within: limit) {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        guard rest.dropFirst(digits.count).first == "\n" else { return nil }
        return pid_t(digits)
    }
}

// MARK: - Router over scratch paths

/** A data and logs root plus one project directory, all inside the current
    test's `TemporaryTree`. */
struct RouterEnv {
    let paths: DirectaPaths
    /** A real directory: a spawned child chdirs into it. */
    let project: String
}

func makeRouterEnv(named name: String, project: String = "proj") throws -> RouterEnv {
    let base = try TemporaryTree.directory(named: name)
    let projectURL = base.appending(path: project)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    return RouterEnv(
        paths: DirectaPaths(dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
        project: projectURL.path)
}

extension Router {
    /** The decoded response to one wire request, exactly as a client reads it. */
    func response<P: Codable & Sendable, R: Codable & Sendable>(
        _ method: WireMethod, _ params: P, _: R.Type = R.self
    ) async throws -> WireResponse<R> {
        let line = try NDJSON.encodeLine(WireRequest(id: "t", method: method.rawValue, params: params))
        let data = await handle(line: line)
        return try JSONCoding.decoder().decode(WireResponse<R>.self, from: data)
    }

    /** The result of a request expected to succeed; a refusal throws its
        `WireError`, so the failing test names the daemon's own reason. */
    func call<P: Codable & Sendable, R: Codable & Sendable>(
        _ method: WireMethod, _ params: P, _ expecting: R.Type = R.self
    ) async throws -> R {
        try await attempt(method, params, expecting).get()
    }

    /** The result, or the `WireError` the daemon refused with, for a request
        that may fail. */
    func attempt<P: Codable & Sendable, R: Codable & Sendable>(
        _ method: WireMethod, _ params: P, _ expecting: R.Type = R.self
    ) async throws -> Result<R, WireError> {
        let decoded = try await response(method, params, expecting)
        if decoded.ok, let result = decoded.result { return .success(result) }
        return .failure(decoded.error ?? WireError(code: .internalError, message: "no result"))
    }
}

/** The `stopped` events recorded for `project` once one carries `detail`
    (any, when nil), or nil when none does within `limit`. A supervisor the
    router already dropped posts this event after its last log write and has
    its state write refused, so awaiting it is how a test whose stop gave up
    makes sure nothing writes into its tree after it returns. */
func awaitStoppedEvents(
    _ router: Router, project: String, detail: String? = nil, within limit: Duration = .seconds(5)
) async throws -> [EventRecord]? {
    try await firstAnswer(within: limit) {
        let stopped = try await router.call(
            .eventsQuery, EventsQueryParams(project: project), EventsQueryResult.self
        ).events.filter { $0.kind == .stopped }
        return stopped.contains { detail == nil || $0.detail == detail } ? stopped : nil
    }
}

// MARK: - Latches

/** A one-shot latch: `wait` suspends until `open`, then every waiter, and
    every later `wait`, gets the opened value. A second `open` is ignored. */
actor Latch<Value: Sendable> {
    private var value: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    func open(_ value: Value) {
        guard self.value == nil else { return }
        self.value = value
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: value) }
    }

    func wait() async -> Value {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

extension Latch where Value == Void {
    func open() { open(()) }
}

/** Holds a launcher's spawn report until the test opens it. */
typealias SpawnGate = Latch<Void>

/** Resolves every `outcome()` once `signal(_:)` is called (at once, for a call
    made after), so a test controls exactly when a fake child "exits" without
    tying that to a real process death. Counts calls so a test can tell
    "waiting on the exit" apart from "never asked". */
actor AdoptGate {
    private(set) var callCount = 0
    private let called = Latch<Void>()
    private let exit = Latch<ProcessOutcome>()

    func outcome() async -> ProcessOutcome {
        callCount += 1
        await called.open()
        return await exit.wait()
    }

    func signal(_ outcome: ProcessOutcome) async {
        await exit.open(outcome)
    }

    /** Returns once `outcome()` has been called at least once. */
    func awaitFirstCall() async {
        await called.wait()
    }
}

// MARK: - Fake launchers

/** A fake whose `run` is a real spawn through `inner`. */
protocol ForwardsRun: ProcessLauncher {
    var inner: any ProcessLauncher { get }
}

extension ForwardsRun {
    func run(
        argv: [String], capture: SpawnCapture, cwd: String?, environment: [String: String],
        onExitedBeforeWatch: @escaping @Sendable (pid_t?) async -> Void,
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome {
        await inner.run(
            argv: argv, capture: capture, cwd: cwd, environment: environment,
            onExitedBeforeWatch: onExitedBeforeWatch, onSpawn: onSpawn)
    }
}

/** A fake that refuses every adoption, so recovery bounces instead. */
protocol NeverAdopts: ProcessLauncher {}

extension NeverAdopts {
    func prepareAdopt(pid: pid_t) -> Bool { false }

    func adopt(pid: pid_t, label: String) async -> ProcessOutcome {
        .spawnFailed(SpawnError(message: "\(Self.self) never adopts"))
    }
}

/** `run` spawns for real so the bounce+respawn fallback still has something
    to start; `adopt` is fully test-controlled through `gate`, which is what
    lets a test observe "adopted, not yet exited" independent of the real
    process the adopted pid names. */
struct FakeAdoptLauncher: ForwardsRun {
    let gate: AdoptGate
    let inner: any ProcessLauncher = SubprocessLauncher()

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
final class UnwatchableAdoptLauncher: ForwardsRun {
    let inner: any ProcessLauncher = SubprocessLauncher()
    private let prepareCalls = OSAllocatedUnfairLock(initialState: 0)

    var prepareCallCount: Int { prepareCalls.withLock { $0 } }

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
    the pid `reported` names through `onExitedBeforeWatch` (never `onSpawn`),
    and returns the status-unknown outcome `LaunchdJobLauncher` reports for
    that case. The narrow path never signals the pid, and neither case can
    name a live process even if it did. */
struct ExitedBeforeWatchLauncher: NeverAdopts {
    enum ReportedPid: CaseIterable, Sendable {
        /** Past the kernel's pid range, so no process can have it. */
        case beyondThePidRange
        /** The job launchd never showed a pid for. */
        case neverShown

        var pid: pid_t? {
            switch self {
            case .beyondThePidRange: Int32.max
            case .neverShown: nil
            }
        }
    }

    let reported: ReportedPid
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
        await onExitedBeforeWatch(reported.pid)
        return .exitedStatusUnknown
    }
}

/** `run` reports a real, killable pid through `onSpawn` (`signalRun`'s `kill`
    calls need a real process to act on) and then blocks on `gate` exactly like
    `FakeAdoptLauncher.adopt`, independent of whether that pid is still alive:
    the deterministic stand-in for "the child exited but recordOutcome was
    never told," which is what lets a bounded wait for that outcome be tested
    without a real multi-second sleep or a race against how fast a flood
    drains. `spawnRoot` picks the real process `run` reports, a long-lived
    session leader by default. A gate stays open once signalled, so a test
    where a stop clears and a fresh run begins names `laterRunsGate`: every
    run after the first waits on it instead, and stays stuck until the test
    signals it. */
struct StuckRunLauncher: NeverAdopts {
    let gate: AdoptGate
    var laterRunsGate: AdoptGate?
    var spawnRoot: @Sendable () throws -> pid_t = spawnSurvivor
    let runs = OSAllocatedUnfairLock(initialState: 0)

    func run(
        argv: [String], capture: SpawnCapture, cwd: String?, environment: [String: String],
        onExitedBeforeWatch: @escaping @Sendable (pid_t?) async -> Void,
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome {
        let pid: pid_t
        do {
            pid = try spawnRoot()
        } catch {
            return .spawnFailed(SpawnError(message: "the stuck run's root failed to spawn: \(error)"))
        }
        await onSpawn(pid)
        let run = runs.withLock { count in
            count += 1
            return count
        }
        return await (run > 1 ? laterRunsGate ?? gate : gate).outcome()
    }
}

/** The launchd shape of a job whose pid publishes a moment after the process
    exists: the real process runs (through `SubprocessLauncher`) while
    `onSpawn` is held behind `gate`, so the supervisor sits in `.starting` with
    no pid. Records every spawned pid so a test can check (and clean up) the
    process itself. */
final class DelayedSpawnLauncher: NeverAdopts {
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

    /** The first pid `run` spawned, once it has, within `limit`. */
    func firstPid(within limit: Duration) async throws -> pid_t? {
        try await firstAnswer(within: limit) { pids.first }
    }
}

// MARK: - Ports

/** The block of ports this test process binds. Two `swift test` runs at once
    (two worktrees, or a run beside a debugger session) would otherwise bind
    the same literal ports and fail each other with `port-held`, so each run
    leases one block of `span` ports under an exclusive `flock` on a per-block
    file in /tmp (machine-wide, like the ports themselves) and holds it for
    the life of the process; the kernel drops the lock when the process
    exits, however it exits. A run finding every block leased waits for one
    to free. Every block stays clear of each range scripts/smoke.sh draws
    from, which `theSuitePortBlocksAvoidEverySmokeRange` checks against the
    script itself. A test names its port as an offset into the block
    (`TestPorts.port(111)`), never as an absolute number. */
enum TestPorts {
    static let bases = [45000, 46000, 47000, 48000]
    static let span = 1000

    /** Leased on first use. */
    static let range: Range<Int> = lease()

    /** Every port any run may lease, for the checks against smoke's ranges. */
    static var reserved: Range<Int> {
        (bases.min() ?? 0)..<((bases.max() ?? 0) + span)
    }

    static func port(_ offset: Int) -> Int { range.lowerBound + offset }

    static func lockPath(base: Int) -> String { "/tmp/directa-test-ports-\(base).lock" }

    private static func lease() -> Range<Int> {
        while true {
            for base in bases {
                let descriptor = open(lockPath(base: base), O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
                guard descriptor >= 0 else { continue }
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    /** Held open for the life of the process; closing it
                        would release the lease. */
                    return base..<(base + span)
                }
                close(descriptor)
            }
            usleep(100_000)
        }
    }
}

// MARK: - Fixture server

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

/** Kills fixture-servers left holding a port in this run's leased block by a
    run that was interrupted before it could stop them.

    A supervised child outliving its daemon is deliberate product behavior, not
    a leak, so the cleanup belongs to whoever spawned it. When a run is killed
    part way that owner is gone, and the next run to lease the block fails
    somewhere unrelated with `port-held` naming a pid nothing is tracking.

    Two conditions, both required, keep this from reaping a process it does
    not own. The command line must name a port in the block this process
    leased, and no other live run can be using a block this process holds the
    lease on; smoke.sh's fixtures use their own ranges and are deliberately
    orphaned by its daemon-kill assertions. And the parent must be gone
    (`ppid == 1`), so a process some live parent still owns is left to it. */
private func reapStrayFixtureServers() {
    guard let binary = fixtureServerBinaryPath() else { return }
    let name = (binary as NSString).lastPathComponent
    var killed: [pid_t] = []
    for candidate in runningProcesses()
    where shouldReapStray(
        command: candidate.command, parent: candidate.parent, binaryName: name, ports: TestPorts.range)
    {
        kill(candidate.pid, SIGKILL)
        killed.append(candidate.pid)
    }
    /** Waits for the kernel to actually tear them down. SIGKILL returns
        immediately but the listening socket outlives the call by a moment, and
        a suite spawning straight afterwards would race it and fail with
        `port-held` naming a pid this had just killed. */
    for _ in 0..<100 where !killed.isEmpty {
        killed = killed.filter { kill($0, 0) == 0 }
        if killed.isEmpty { break }
        usleep(20_000)
    }
}

/** The decision on its own, so both halves are testable without spawning
    anything: the ones it must kill and, more importantly, the ones it must
    not. */
func shouldReapStray(command: String, parent: pid_t, binaryName: String, ports: Range<Int>) -> Bool {
    /** Matched by name rather than by absolute path: a fixture launched
        through a relative path appears in `ps` exactly as invoked, so a
        full-path match would skip it without a sound. */
    guard command.contains(binaryName) else { return false }
    guard parent == 1 else { return false }
    return command.split(separator: " ").compactMap { Int($0) }.contains(where: ports.contains)
}

private struct RunningProcess {
    let command: String
    let parent: pid_t
    let pid: pid_t
}

/** `ps` rather than the sysctl sweep in DirectaDaemonCore, because the full
    command line is the thing being matched and `kinfo_proc` does not carry it.
    A bare spawn reaped with `waitpid` rather than Foundation's `Process`,
    whose `waitUntilExit` spins a run loop on whichever cooperative thread
    first asks for the fixture. An empty list when `ps` cannot run, which only
    means nothing is reaped. */
private func runningProcesses() -> [RunningProcess] {
    guard let text = try? captureOutput(["/bin/ps", "-A", "-o", "pid=,ppid=,command="]) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1])
        else { return nil }
        return RunningProcess(
            command: fields.dropFirst(2).joined(separator: " "), parent: parent, pid: pid)
    }
}
