import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaDaemonCore

/** Deterministic prober: plays a scripted sequence, then repeats the last entry. */
private actor ProbeScript {
    private var results: [Bool]

    init(_ results: [Bool]) {
        self.results = results
    }

    func next() -> Bool {
        if results.count > 1 { return results.removeFirst() }
        return results.first ?? false
    }
}

private struct ScriptedProber: HealthProber {
    let script: ProbeScript

    func probe(_ check: EffectiveHealthcheck) async -> Bool {
        await script.next()
    }
}

/** One probe in flight per waiter. `started` counts calls, so a test can tell
    a new check has begun (the previous result is already recorded) without
    sleeping. */
private actor ProbeGate {
    private var served = 0
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func next() async -> Bool {
        served += 1
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    var started: Int { served }

    func releaseOldest(_ success: Bool) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: success)
    }

    func releaseAll(_ success: Bool) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: success)
        }
    }
}

private struct GateProber: HealthProber {
    let gate: ProbeGate

    func probe(_ check: EffectiveHealthcheck) async -> Bool {
        await gate.next()
    }
}

private actor FinishFlag {
    private(set) var finished = false

    func mark() { finished = true }
}

private func waitForProbe(after seen: Int, gate: ProbeGate) async throws {
    try #require(await eventually(within: .seconds(2)) { await gate.started > seen })
}

private func makeSupervisor(
    command: [String],
    healthcheck: HealthCheckSpec?,
    prober: any HealthProber,
    port: Int? = nil
) throws -> (ServerSupervisor, DirectaPaths, String) {
    let base = try TemporaryTree.directory(named: "health")
    let project = base.appending(path: "proj")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let paths = DirectaPaths(dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs"))
    let spec = ServerSpec(command: command, healthcheck: healthcheck, name: "web", port: port)
    let supervisor = ServerSupervisor(
        launcher: SubprocessLauncher(), paths: paths, prober: prober, projectPath: project.path,
        registry: Registry(paths: paths), spec: spec)
    return (supervisor, paths, project.path)
}

@Suite(.temporaryTree) struct HealthStateMachineTests {
    private let fastTCP = HealthCheckSpec(
        healthyAfter: 1, intervalMs: 30, port: 1, timeoutMs: 100, type: .tcp, unhealthyAfter: 3)

    @Test func startingUntilFirstHealthyThenRunning() async throws {
        let (supervisor, _, _) = try makeSupervisor(
            command: ["/bin/sh", "-c", "sleep 30"],
            healthcheck: fastTCP,
            prober: ScriptedProber(script: ProbeScript([false, false, true])))
        let started = await supervisor.start()
        /** Failures before first-healthy never mark unhealthy: still starting. */
        #expect(started.phase == .starting)
        #expect(try await awaitPhase(supervisor, .running).phase == .running)
        _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
    }

    @Test func unhealthyAfterThresholdAndRecovery() async throws {
        /** Pad failures past unhealthyAfter so the unhealthy phase lasts longer
            than a few polling intervals: a tight [true,F,F,F,true] script can
            recover before the assertion sees .unhealthy (flake on CI). */
        let (supervisor, _, _) = try makeSupervisor(
            command: ["/bin/sh", "-c", "sleep 30"],
            healthcheck: fastTCP,
            prober: ScriptedProber(
                script: ProbeScript([true] + Array(repeating: false, count: 12) + [true])))
        _ = await supervisor.start()
        #expect(try await awaitPhase(supervisor, .running).phase == .running)
        #expect(try await awaitPhase(supervisor, .unhealthy).phase == .unhealthy)
        /** A healthy probe recovers the phase without a restart. */
        #expect(try await awaitPhase(supervisor, .running).phase == .running)
        _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
    }

    @Test func ensureFailsFastOnCrash() async throws {
        let (supervisor, _, _) = try makeSupervisor(
            command: ["/bin/sh", "-c", "exit 5"],
            healthcheck: nil,
            prober: NetworkHealthProber())
        let began = ContinuousClock.now
        let result = await supervisor.ensure(timeoutSeconds: 30)
        let elapsed = began.duration(to: ContinuousClock.now)
        #expect(result.reason == .crashed)
        #expect(result.server.lastExit?.code == 5)
        #expect(result.server.recentLogTail != nil || result.server.lastExit != nil)
        /** Fail-fast: nowhere near the 30s timeout. */
        #expect(elapsed < .seconds(10))
    }

    @Test func ensureIsNoOpWhenRunning() async throws {
        let (supervisor, _, _) = try makeSupervisor(
            command: ["/bin/sh", "-c", "sleep 30"],
            healthcheck: fastTCP,
            prober: ScriptedProber(script: ProbeScript([true])))
        let first = await supervisor.ensure(timeoutSeconds: 10)
        #expect(first.reason == nil)
        let second = await supervisor.ensure(timeoutSeconds: 10)
        #expect(second.reason == nil)
        #expect(second.server.pid == first.server.pid)
        _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
    }

    @Test func ensureSpawnFailureReportsFailed() async throws {
        let (supervisor, _, _) = try makeSupervisor(
            command: ["/nonexistent/binary-xyz"],
            healthcheck: nil,
            prober: NetworkHealthProber())
        let result = await supervisor.ensure(timeoutSeconds: 10)
        #expect(result.reason == .failed)
        #expect(result.server.spawnError != nil)
    }

    @Test func waitStoppedResolvesOnStop() async throws {
        let (supervisor, _, _) = try makeSupervisor(
            command: ["/bin/sh", "-c", "sleep 30"],
            healthcheck: fastTCP,
            prober: ScriptedProber(script: ProbeScript([true])))
        _ = await supervisor.start()
        async let waiter = supervisor.wait(for: .stopped, timeoutSeconds: 10)
        _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
        #expect(await waiter == nil)
    }

    /** The pass that made the previous process healthy is not this process's
        pass. `wait --healthy` was returning in that window, and status still
        showed the old `lastHealthAt` and the old exit. */
    @Test func aNewRunDoesNotInheritThePreviousRunsHealth() async throws {
        let gate = ProbeGate()
        let (supervisor, _, _) = try makeSupervisor(
            command: ["/bin/sh", "-c", "sleep 30"],
            healthcheck: fastTCP,
            prober: GateProber(gate: gate))
        do {
            _ = await supervisor.start()
            try await waitForProbe(after: 0, gate: gate)
            await gate.releaseOldest(true)
            let healthy = try await awaitPhase(supervisor, .running)
            try #require(healthy.lastHealthAt != nil)

            try await waitForProbe(after: 1, gate: gate)
            _ = await supervisor.stop(graceSeconds: 1, reason: "restart")
            let restarted = await supervisor.start()
            #expect(restarted.phase == .starting)
            #expect(restarted.lastHealthAt == nil)
            #expect(restarted.lastExit == nil)

            await gate.releaseOldest(true)
            let promoted = try await eventually(within: .seconds(1)) {
                await supervisor.status().phase == .running
            }
            #expect(!promoted)
            #expect((await supervisor.status()).lastHealthAt == nil)
            await gate.releaseAll(false)
            _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
        } catch {
            await gate.releaseAll(false)
            _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
            throw error
        }
    }

    /** One failed check leaves the phase `running` until `unhealthyAfter`.
        `wait --healthy` still has to block: the port is refusing. */
    @Test func waitHealthyBlocksWhileTheLatestProbeIsFailing() async throws {
        let (supervisor, gate) = try await serverPastOneFailedProbe()
        do {
            let flag = FinishFlag()
            let task = Task {
                let reason = await supervisor.wait(for: .healthy, timeoutSeconds: 3)
                await flag.mark()
                return reason
            }
            let early = try await eventually(within: .milliseconds(500)) { await flag.finished }
            if early {
                let reason = await task.value
                #expect(reason != nil, "wait returned while the latest health check was failing")
            } else {
                await gate.releaseOldest(true)
                #expect(await task.value == nil)
                #expect(await supervisor.status().phase == .running)
            }
            await gate.releaseAll(false)
            _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
        } catch {
            await gate.releaseAll(false)
            _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
            throw error
        }
    }

    /** Same window as the wait above: the phase stays `running` through a
        failing check, and ensure waits with it rather than returning. */
    @Test func ensureWaitsWhileTheLatestProbeIsFailing() async throws {
        let (supervisor, gate) = try await serverPastOneFailedProbe()
        do {
            let flag = FinishFlag()
            let task = Task {
                let result = await supervisor.ensure(timeoutSeconds: 3)
                await flag.mark()
                return result
            }
            let early = try await eventually(within: .milliseconds(500)) { await flag.finished }
            if early {
                let result = await task.value
                #expect(result.reason != nil, "ensure returned while the latest health check was failing")
            } else {
                await gate.releaseOldest(true)
                let result = await task.value
                #expect(result.reason == nil)
                #expect(result.server.phase == .running)
            }
            await gate.releaseAll(false)
            _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
        } catch {
            await gate.releaseAll(false)
            _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
            throw error
        }
    }

    /** Healthy, then one failure recorded, with the next probe held. Phase
        stays `running` (`unhealthyAfter` is 3). */
    private func serverPastOneFailedProbe() async throws -> (ServerSupervisor, ProbeGate) {
        let gate = ProbeGate()
        let (supervisor, _, _) = try makeSupervisor(
            command: ["/bin/sh", "-c", "sleep 30"],
            healthcheck: fastTCP,
            prober: GateProber(gate: gate))
        do {
            _ = await supervisor.start()
            try await waitForProbe(after: 0, gate: gate)
            await gate.releaseOldest(true)
            try await waitForProbe(after: 1, gate: gate)
            try #require((await supervisor.status()).phase == .running)
            await gate.releaseOldest(false)
            try await waitForProbe(after: 2, gate: gate)
            try #require((await supervisor.status()).phase == .running)
            return (supervisor, gate)
        } catch {
            await gate.releaseAll(false)
            _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
            throw error
        }
    }
}

@Suite struct EffectiveHealthcheckTests {
    @Test func explicitHTTPWins() {
        let spec = ServerSpec(
            command: ["x"],
            healthcheck: HealthCheckSpec(type: .http, url: "http://127.0.0.1:9/health"),
            name: "s", port: 3000)
        #expect(
            EffectiveHealthcheck.resolve(spec: spec)
                == .http(url: "http://127.0.0.1:9/health", timeoutMs: 1500))
    }

    @Test func declaredPortImpliesTCP() {
        let spec = ServerSpec(command: ["x"], name: "s", port: 4321)
        #expect(EffectiveHealthcheck.resolve(spec: spec) == .tcp(port: 4321, timeoutMs: 1500))
    }

    @Test func bareSpecMeansStabilizationWindow() {
        let spec = ServerSpec(command: ["x"], name: "s")
        #expect(EffectiveHealthcheck.resolve(spec: spec) == .none(stabilizationMs: 2000))
    }

    @Test func tcpProbeAgainstRealListener() throws {
        /** A live in-test listener answers; a port nobody is accepting on
            refuses. Closed exactly once: this suite shares a process with the
            others, so closing an fd twice can shut one another thread just
            opened and was handed the same number. */
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(sock, 4)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        #expect(LoopbackProbe.isListening(port: port, timeoutMs: 500))
        close(sock)

        /** The negative uses a port this test holds and never listens on, so no
            other socket can take it. Asserting the released port above stays
            free would race: `bind(0)` returns an ephemeral port, the range the
            kernel hands to outbound connections. Re-binding it is no better,
            since a closed listener leaves TIME_WAIT behind. */
        let quiet = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(quiet) }
        var quietAddr = sockaddr_in()
        quietAddr.sin_family = sa_family_t(AF_INET)
        quietAddr.sin_port = 0
        quietAddr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = withUnsafePointer(to: &quietAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(quiet, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var quietBound = sockaddr_in()
        var quietLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &quietBound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(quiet, $0, &quietLen)
            }
        }
        let quietPort = Int(UInt16(bigEndian: quietBound.sin_port))
        #expect(!LoopbackProbe.isListening(port: quietPort, timeoutMs: 200))
    }

    @Test func tcpProbeAgainstIPv6OnlyListener() throws {
        /** Vite 5+ binds `::1` only; the probe must still see it as up. */
        let sock = socket(AF_INET6, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = 0
        addr.sin6_addr = in6addr_loopback
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        listen(sock, 4)
        var bound = sockaddr_in6()
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: bound.sin6_port))
        #expect(LoopbackProbe.isListening(port: port, timeoutMs: 500))
    }
}
