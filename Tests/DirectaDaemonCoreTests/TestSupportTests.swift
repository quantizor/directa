import Darwin
import DirectaTestSupport
import Foundation
import Testing
import os

@testable import DirectaDaemonCore

/** The stray reaper decides whether to SIGKILL a process, so the cases it must
    refuse matter more than the ones it acts on; these pin each decision. The
    rest pin the spawn, latch, and port-block guarantees the suites lean on. */
@Suite struct TestSupportTests {
    private let binary = "fixture-server"
    /** A block as a run would lease it, independent of the one this process
        actually holds. */
    private let block = 45000..<46000

    @Test func reapsAnOrphanHoldingAPortInTheLeasedBlock() {
        #expect(
            shouldReapStray(
                command: "/Users/x/directa/.build/debug/fixture-server --listen-tcp 45411",
                parent: 1, binaryName: binary, ports: block))
    }

    /** Launched through a relative path, which is how it appears in `ps` when
        invoked that way. */
    @Test func reapsAnOrphanInvokedThroughARelativePath() {
        #expect(
            shouldReapStray(
                command: "./.build/debug/fixture-server --listen-tcp 45411", parent: 1,
                binaryName: binary, ports: block))
    }

    /** A fixture with a live parent belongs to that parent. */
    @Test func refusesAFixtureWithALiveParent() {
        #expect(
            shouldReapStray(
                command: "/Users/x/directa/.build/debug/fixture-server --listen-tcp 45411",
                parent: 40100, binaryName: binary, ports: block) == false)
    }

    /** A concurrent run's block, even for an orphan: that run may be in the
        middle of a test that orphaned it on purpose. */
    @Test func refusesAnOrphanInAnotherRunsBlock() {
        #expect(
            shouldReapStray(
                command: "/Users/x/directa/.build/debug/fixture-server --setsid-listener 46411",
                parent: 1, binaryName: binary, ports: block) == false)
    }

    /** scripts/smoke.sh allocates outside every block and deliberately orphans
        a fixture to prove children survive a daemon kill. Reaping that would
        break the assertion it exists to make. */
    @Test func refusesAnOrphanOutsideTheLeasedBlock() {
        #expect(
            shouldReapStray(
                command: "/Users/x/directa/.build/debug/fixture-server --listen-tcp 39421",
                parent: 1, binaryName: binary, ports: block) == false)
    }

    @Test func refusesAProcessThatIsNotTheFixture() {
        #expect(
            shouldReapStray(
                command: "/usr/bin/node server.js --port 45411", parent: 1, binaryName: binary,
                ports: block) == false)
    }

    /** No port at all means nothing to squat, so there is no reason to kill it. */
    @Test func refusesAFixtureCarryingNoPort() {
        #expect(
            shouldReapStray(
                command: "/Users/x/directa/.build/debug/fixture-server --spawn-grandchild", parent: 1,
                binaryName: binary, ports: block) == false)
    }

    /** A bare spawn that inherits a pipe's write end keeps that pipe open for
        its whole life, so a reader elsewhere in the run (every supervisor's
        git call drains to end of file) waits on the child instead of on the
        process it started. Enough of those at once fill the cooperative pool
        and stall every test for the child's full lifetime. */
    @Test func aBareSpawnHoldsNoPipeTheTestProcessHasOpen() throws {
        let pipe = Pipe()
        let survivor = try spawnSurvivor()
        defer { kill(survivor, SIGKILL) }
        try pipe.fileHandleForWriting.close()

        let reader = pipe.fileHandleForReading.fileDescriptor
        var poller = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
        try #require(poll(&poller, 1, 2000) == 1, "the survivor still holds the pipe's write end")
        var byte: UInt8 = 0
        #expect(read(reader, &byte, 1) == 0)
    }

    /** A spawning thread with SIGTERM blocked must not hand that mask to the
        child, or the child ignores every stop. */
    @Test func aBareSpawnTakesSIGTERMWhateverTheSpawningThreadBlocks() async throws {
        var blockTerm = sigset_t()
        var previous = sigset_t()
        sigemptyset(&blockTerm)
        sigaddset(&blockTerm, SIGTERM)
        pthread_sigmask(SIG_BLOCK, &blockTerm, &previous)
        let spawned = Result { try spawnSurvivor() }
        pthread_sigmask(SIG_SETMASK, &previous, nil)
        let survivor = try spawned.get()
        defer { kill(survivor, SIGKILL) }

        kill(survivor, SIGTERM)
        #expect(try await awaitExit(survivor, within: .seconds(5)), "the child kept the spawning thread's mask")
    }

    /** A gate signalled while a caller waits stays open: every later
        `outcome()` returns the same value at once rather than suspending with
        nothing left to resume it. */
    @Test func anAdoptGateSignalledUnderAWaiterStaysOpen() async throws {
        let gate = AdoptGate()
        let first = Task { await gate.outcome() }
        defer { gate.signal(.exitedStatusUnknown) }
        try #require(try await eventually(within: .seconds(5)) { await gate.callCount == 1 })
        gate.signal(.exited(code: 3))
        #expect(Self.exitCode(await first.value) == 3)

        /** Unstructured, so a second call that never returns fails this test
            instead of hanging the run on a task group's implicit join. */
        let second = OSAllocatedUnfairLock<Int?>(initialState: nil)
        Task {
            let code = Self.exitCode(await gate.outcome())
            second.withLock { $0 = code }
        }
        let answered = try await eventually(within: .seconds(2)) { second.withLock { $0 } != nil }
        #expect(answered, "a second outcome() after the signal never returned")
        #expect(second.withLock { $0 } == 3)
    }

    /** Every caller waiting when the gate is signalled is resumed, not only
        the latest one. */
    @Test func anAdoptGateSignalledUnderTwoWaitersResumesBoth() async throws {
        let gate = AdoptGate()
        let codes = OSAllocatedUnfairLock(initialState: [Int]())
        for _ in 0..<2 {
            Task {
                if let code = Self.exitCode(await gate.outcome()) {
                    codes.withLock { $0.append(code) }
                }
            }
        }
        defer { gate.signal(.exitedStatusUnknown) }
        try #require(try await eventually(within: .seconds(5)) { await gate.callCount == 2 })
        gate.signal(.exited(code: 4))
        let resumed = try await eventually(within: .seconds(2)) { codes.withLock { $0.count } == 2 }
        #expect(resumed, "\(codes.withLock { $0.count }) of 2 waiters resumed after the signal")
        #expect(codes.withLock { $0 } == [4, 4])
    }

    /** The first value stays, and a `wait` after the open answers at once. */
    @Test func aLatchKeepsItsFirstValueAndAnswersLaterWaits() async {
        let latch = Latch<Int>()
        latch.open(1)
        latch.open(2)
        #expect(await latch.wait() == 1)
    }

    /** A test that throws while a job it started waits on a gate must still
        finish: Swift cancels and then awaits an `async let` at scope exit,
        and a checked continuation ignores the cancellation, so the job ends
        only once the gate opens. The `defer` that opens it is declared after
        the `async let`, which scope exit unwinds first. Run unstructured and
        raced against a deadline, so a regression fails here instead of
        hanging the run. */
    @Test func aGateOpenedInADeferAfterTheJobLetsAThrowingTestFinish() async throws {
        let gate = SpawnGate()
        let thrown = OSAllocatedUnfairLock<(any Error)?>(initialState: nil)
        Task {
            do { try await Self.throwWhileAJobWaits(on: gate) } catch { thrown.withLock { $0 = error } }
        }
        /** Frees a job a broken `defer` left waiting. */
        defer { gate.open() }

        let finished = try await eventually(within: .seconds(2)) { thrown.withLock { $0 } != nil }
        #expect(finished, "the throwing test never finished: its gate was not opened before the job was awaited")
        #expect(thrown.withLock { $0 } is EarlyExit)
    }

    /** The ordering rule itself: a `defer` declared before the `async let`
        runs after the implicit await, so the test stays stuck until something
        else opens the gate. */
    @Test func aGateOpenedInADeferBeforeTheJobLeavesAThrowingTestStuck() async throws {
        let gate = SpawnGate()
        let thrown = OSAllocatedUnfairLock<(any Error)?>(initialState: nil)
        Task {
            do { try await Self.throwWhileAJobWaitsWithTheDeferFirst(on: gate) } catch { thrown.withLock { $0 = error } }
        }
        defer { gate.open() }

        let finished = try await eventually(within: .milliseconds(500)) { thrown.withLock { $0 } != nil }
        #expect(!finished, "the test finished without the gate opening")
        gate.open()
        let released = try await eventually(within: .seconds(2)) { thrown.withLock { $0 } != nil }
        #expect(released, "opening the gate did not release the stuck test")
    }

    private struct EarlyExit: Error {}

    private static func throwWhileAJobWaits(on gate: SpawnGate) async throws {
        async let _: Void = gate.wait()
        defer { gate.open() }
        throw EarlyExit()
    }

    private static func throwWhileAJobWaitsWithTheDeferFirst(on gate: SpawnGate) async throws {
        defer { gate.open() }
        async let _: Void = gate.wait()
        throw EarlyExit()
    }

    /** The fixture's setsid listener is spawned from a Dispatch worker thread
        (the delay), which can have SIGTERM blocked; the listener must not
        inherit that. Its parent exits at once so launchd reaps it, which lets
        the exit show as a pid that stops answering. */
    @Test func aFixtureSetsidListenerTakesSIGTERMFromADispatchThread() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let (readEnd, writeEnd) = try makeOutputPipe()
        defer { close(readEnd) }
        let root = try spawnReapedSessionLeader(
            [
                fixture, "--setsid-listener", "\(TestPorts.port(60))", "--grandchild-after", "0.1",
                "--exit-after-spawn",
            ], stdoutFD: writeEnd)
        close(writeEnd)
        defer { kill(root, SIGKILL) }
        let listener = try #require(await readPrintedPid("setsid listener", from: readEnd))
        defer { kill(listener, SIGKILL) }

        kill(listener, SIGTERM)
        #expect(try await awaitExit(listener, within: .seconds(5)), "the listener kept the spawning thread's mask")
    }

    /** A `/bin/sh` that starts the fixture (with `flags`, output discarded)
        in the background, prints its pid, then runs `afterwards`; returns the
        shell's pid and the fixture's. The caller owns killing both. */
    private func startFixtureFromAShell(
        flags: String, afterwards: String
    ) async throws -> (shell: pid_t, fixture: pid_t) {
        let fixture = try #require(fixtureServerExecutable())
        let (readEnd, writeEnd) = try makeOutputPipe()
        defer { close(readEnd) }
        let shell = try spawnReapedSessionLeader(
            ["/bin/sh", "-c", "\"$0\" \(flags) >/dev/null 2>&1 & echo \"started pid $!\"; \(afterwards)", fixture],
            stdoutFD: writeEnd)
        close(writeEnd)
        let started = await readPrintedPid("started", from: readEnd)
        guard let started else {
            kill(shell, SIGKILL)
            throw NSError(
                domain: "directa.test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "the shell never printed the fixture's pid"])
        }
        return (shell, started)
    }

    /** A flood burns a core, so it must not outlive the process that started
        it: a test run killed part way would leave one behind under launchd. */
    @Test func aFloodFixtureExitsWithTheProcessThatStartedIt() async throws {
        let (shell, flood) = try await startFixtureFromAShell(flags: "--flood", afterwards: "exec sleep 30")
        defer {
            kill(shell, SIGKILL)
            kill(flood, SIGKILL)
        }

        kill(shell, SIGKILL)
        #expect(try await awaitExit(flood, within: .seconds(5)), "the flood kept running after its starter was killed")
    }

    /** A starter that is gone before the fixture arms its watch is never
        reported to the watch, so the fixture checks for that itself. */
    @Test func aFloodFixtureWhoseStarterIsAlreadyGoneExits() async throws {
        let (shell, flood) = try await startFixtureFromAShell(flags: "--flood", afterwards: "exit 0")
        defer {
            kill(shell, SIGKILL)
            kill(flood, SIGKILL)
        }

        #expect(try await awaitExit(flood, within: .seconds(5)), "the flood kept running with no process that started it")
    }

    /** The teardown fixtures exist to outlive their parents, so only a flood
        is tied to its starter. */
    @Test func aHeartbeatFixtureOutlivesTheProcessThatStartedIt() async throws {
        let (shell, heartbeat) = try await startFixtureFromAShell(flags: "", afterwards: "exec sleep 30")
        defer {
            kill(shell, SIGKILL)
            kill(heartbeat, SIGKILL)
        }

        kill(shell, SIGKILL)
        #expect(!(try await eventually(within: .seconds(1)) { kill(heartbeat, 0) != 0 }))
    }

    /** The fixture keeps its stdout open and keeps printing after the pid
        line, so the read stops at that line, not at end of file. */
    @Test func aPrintedPidIsTakenFromItsWholeLineAmongOtherOutput() async throws {
        let (readEnd, writeEnd) = try makeOutputPipe()
        defer {
            close(readEnd)
            close(writeEnd)
        }
        let text = Array("heartbeat 1\ngrandchild pid 4242\nheartbeat 2\n".utf8)
        try #require(write(writeEnd, text, text.count) == text.count)

        #expect(await offPool { readPrintedPid("grandchild", from: readEnd, within: .seconds(5)) } == 4242)
    }

    /** A writer that holds stdout open without finishing the line, or prints
        another label, ends the read at the deadline rather than hanging it or
        returning a half-written pid. */
    @Test(arguments: ["grandchild pid 12", "setsid listener pid 12\n", ""])
    func aReadWithoutItsPidLineEndsAtTheDeadline(printed: String) async throws {
        let (readEnd, writeEnd) = try makeOutputPipe()
        defer {
            close(readEnd)
            close(writeEnd)
        }
        let text = Array(printed.utf8)
        try #require(write(writeEnd, text, text.count) == text.count)

        #expect(await offPool { readPrintedPid("grandchild", from: readEnd, within: .milliseconds(200)) } == nil)
    }

    private static func exitCode(_ outcome: ProcessOutcome) -> Int? {
        guard case .exited(let code) = outcome else { return nil }
        return code
    }

    /** The run's block is one of the leasable ones, and its lease is held: a
        second lock on the same file, as a concurrent run would take, is
        refused. */
    @Test func thisRunHoldsTheLeaseOnItsPortBlock() throws {
        let base = TestPorts.range.lowerBound
        #expect(TestPorts.bases.contains(base))
        #expect(TestPorts.range.count == TestPorts.span)
        let descriptor = open(TestPorts.lockPath(base: base), O_RDONLY | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == -1)
        #expect(errno == EWOULDBLOCK)
    }

    /** A test with two checkouts of one repository gets the second as a real
        directory beside the first, in the same scratch tree as the router's
        data and logs roots. */
    @Test(.temporaryTree) func aSiblingProjectIsARealDirectoryBesideTheFirst() throws {
        let env = try makeRouterEnv(named: "sibling", project: "first")
        let second = try env.sibling(named: "second")
        let base = URL(fileURLWithPath: env.project).deletingLastPathComponent()

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: second, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(second == base.appending(path: "second").path)
        #expect(env.project == base.appending(path: "first").path)
        #expect(env.paths.dataDir == base.appending(path: "data"))
        #expect(env.paths.logsDir == base.appending(path: "logs"))
    }

    /** Every block any run may lease must stay clear of every range
        scripts/smoke.sh draws from, read from the script itself so a new
        smoke range cannot land on a unit block unnoticed. */
    @Test func theSuitePortBlocksAvoidEverySmokeRange() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/smoke.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        let ranges = text.matches(of: #/\$\(\((\d+) \+ \(RANDOM % (\d+)\)\)\)/#).compactMap { match in
            Int(match.1).flatMap { base in Int(match.2).map { base..<(base + $0) } }
        }
        try #require(!ranges.isEmpty, "found no RANDOM port range in scripts/smoke.sh")
        for range in ranges {
            #expect(!range.overlaps(TestPorts.reserved), "smoke draws \(range), inside the unit blocks")
        }
    }

    /** A `LaunchdJobLauncher` built anywhere but `testLaunchdJobLauncher()`
        can carry the production label prefix, which the live daemon's
        `doctor` and leftover-job reap would read as a real leftover. */
    @Test func aLaunchdJobLauncherIsOnlyBuiltThroughTheTestFactory() throws {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        /** Split so this line does not match itself. */
        let construction = "LaunchdJobLauncher" + "("
        let walker = try #require(FileManager.default.enumerator(atPath: testsRoot.path))
        var offenders: [String] = []
        for case let relative as String in walker
        where relative.hasSuffix(".swift") && relative != "DirectaDaemonCoreTests/TestSupport.swift" {
            let text = try String(contentsOf: testsRoot.appending(path: relative), encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where Self.constructs(construction, in: line) {
                offenders.append("\(relative):\(index + 1)")
            }
        }
        #expect(offenders == [], "build it with testLaunchdJobLauncher()")
    }

    /** A port a daemon-core suite binds is named through `TestPorts.port`,
        because a literal in the leasable range belongs to whichever run holds
        that block and collides with a concurrent run that leases another. */
    @Test func noDaemonCoreSuiteNamesAPortInTheLeasableRangeByLiteral() throws {
        let suites = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let exempt = ["TestSupport.swift", "TestSupportTests.swift"]
        let literal = #/\b4[5-8]_?\d{3}\b/#
        var offenders: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: suites.path).sorted()
        where name.hasSuffix(".swift") && !exempt.contains(name) {
            let text = try String(contentsOf: suites.appending(path: name), encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.firstMatch(of: literal) != nil {
                offenders.append("\(name):\(index + 1)")
            }
        }
        #expect(offenders == [], "name the port with TestPorts.port(offset)")
    }

    /** `name` as its own identifier, so the factory's own name, which ends
        in it, never counts. */
    private static func constructs(_ name: String, in line: Substring) -> Bool {
        line.ranges(of: name).contains { range in
            guard range.lowerBound > line.startIndex else { return true }
            let before = line[line.index(before: range.lowerBound)]
            return !(before.isLetter || before.isNumber || before == "_")
        }
    }
}
