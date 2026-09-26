import Darwin
import Foundation
import Testing

/** The stray reaper decides whether to SIGKILL a process, so the cases it must
    refuse matter more than the ones it acts on. Each was checked against real
    processes once; these pin the decision so it stays checked. */
@Suite struct TestSupportTests {
    private let binary = "fixture-server"

    @Test func reapsAnOrphanHoldingASuitePort() {
        #expect(
            shouldReapStray(
                command: "/Users/x/directa/.build/debug/fixture-server --listen-tcp 45411",
                parent: 1, binaryName: binary))
    }

    /** Launched through a relative path, which is how it appears in `ps` when
        invoked that way. Matching the absolute path missed this and the miss was
        silent. */
    @Test func reapsAnOrphanInvokedThroughARelativePath() {
        #expect(
            shouldReapStray(
                command: "./.build/debug/fixture-server --listen-tcp 45411", parent: 1,
                binaryName: binary))
    }

    /** A fixture belonging to a live run is parented by that run's test process,
        so a second concurrent `swift test` must survive this untouched. */
    @Test func refusesAFixtureWithALiveParent() {
        #expect(
            shouldReapStray(
                command: "/Users/x/directa/.build/debug/fixture-server --listen-tcp 45411",
                parent: 40100, binaryName: binary) == false)
    }

    /** scripts/smoke.sh allocates outside this range and deliberately orphans a
        fixture to prove children survive a daemon kill. Reaping that would break
        the assertion it exists to make. */
    @Test func refusesAnOrphanOutsideTheSuitePortRange() {
        #expect(
            shouldReapStray(
                command: "/Users/x/directa/.build/debug/fixture-server --listen-tcp 39421",
                parent: 1, binaryName: binary) == false)
    }

    @Test func refusesAProcessThatIsNotTheFixture() {
        #expect(
            shouldReapStray(command: "/usr/bin/node server.js --port 45411", parent: 1, binaryName: binary)
                == false)
    }

    /** No port at all means nothing to squat, so there is no reason to kill it. */
    @Test func refusesAFixtureCarryingNoSuitePort() {
        #expect(
            shouldReapStray(
                command: "/Users/x/directa/.build/debug/fixture-server --spawn-grandchild", parent: 1,
                binaryName: binary) == false)
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
        let ready = poll(&poller, 1, 2000)
        var byte: UInt8 = 0
        #expect(ready == 1, "the survivor still holds the pipe's write end")
        #expect(ready == 1 && read(reader, &byte, 1) == 0)
    }

    /** The literals, and the randomized ports `ResourceLockTests` draws, must
        all fall inside the block; smoke.sh's two ranges must all fall outside
        it. An earlier version of this test asserted 41000 was outside and
        called that correct, which pinned a real gap as deliberate: the lock
        suite was drawing from 41_000 at the time, so its fixtures were never
        reaped. Both directions are asserted here so neither can drift alone. */
    @Test func theSuitePortRangeCoversEverySuiteAndAvoidsSmoke() {
        for port in [45001, 45426, 45471, 45500, 45749, 45750, 45999] {
            #expect(TestPorts.owns(port), "\(port) is used by a suite but not reserved")
        }
        for port in [39000, 39499, 41000, 41501] {
            #expect(TestPorts.owns(port) == false, "\(port) belongs to smoke.sh")
        }
    }
}
