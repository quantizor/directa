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

    func probe(_ check: EffectiveHealthcheck) async -> HealthProbeOutcome {
        await script.next() ? .pass : .fail("scripted failure")
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

    func probe(_ check: EffectiveHealthcheck) async -> HealthProbeOutcome {
        await gate.next() ? .pass : .fail("gated failure")
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
        let beforeAnyCheck = await supervisor.start()
        #expect(beforeAnyCheck.lastHealthCheck == nil)
        let firstPass = try await awaitPhase(supervisor, .running)
        #expect(firstPass.phase == .running)
        let passed = try #require(firstPass.lastHealthCheck)
        #expect(passed.passed)
        #expect(passed.failures == 0)
        #expect(passed.detail == nil)

        let failing = try await awaitPhase(supervisor, .unhealthy)
        #expect(failing.phase == .unhealthy)
        /** The count keeps growing while the run stays unhealthy, so only its
            floor is fixed: `unhealthyAfter` failures put it here. */
        let failed = try #require(failing.lastHealthCheck)
        #expect(!failed.passed)
        #expect(failed.failures >= 3)
        #expect(failed.detail == "scripted failure")
        #expect(failed.at >= passed.at)

        /** A healthy probe recovers the phase without a restart, and a pass
            resets the count and drops the failure's detail. */
        let recovered = try await awaitPhase(supervisor, .running)
        #expect(recovered.phase == .running)
        let recoveredCheck = try #require(recovered.lastHealthCheck)
        #expect(recoveredCheck.passed)
        #expect(recoveredCheck.failures == 0)
        #expect(recoveredCheck.detail == nil)

        /** The result belongs to the run: it is gone once the run ends. */
        let stopped = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
        #expect(stopped.lastHealthCheck == nil)
        #expect(await supervisor.status().lastHealthCheck == nil)
    }

    /** With no healthcheck the probe answers "alive" by construction, which
        says nothing about the server, so no result is kept. */
    @Test func noHealthcheckKeepsNoCheckResult() async throws {
        let (supervisor, _, _) = try makeSupervisor(
            command: ["/bin/sh", "-c", "sleep 30"],
            healthcheck: nil,
            prober: NetworkHealthProber())
        _ = await supervisor.start()
        let running = try await awaitPhase(supervisor, .running, within: .seconds(8))
        #expect(running.phase == .running)
        #expect(running.healthcheck == HealthCheckType.none)
        #expect(running.lastHealthAt != nil)
        #expect(running.lastHealthCheck == nil)
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
            /** The phase still says `running`; the latest check says why it is
                not ready. */
            let failing = try #require(await supervisor.status().lastHealthCheck)
            #expect(!failing.passed)
            #expect(failing.failures == 1)
            #expect(failing.detail == "gated failure")

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
                let settled = await supervisor.status()
                #expect(settled.phase == .running)
                #expect(settled.lastHealthCheck?.passed == true)
                #expect(settled.lastHealthCheck?.failures == 0)
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

private enum ResponderError: Error {
    case bind(errno: Int32)
    case socket(errno: Int32)
}

/** A real HTTP/1.1 responder on one loopback family. It answers every request
    with `statusCode` after `delaySeconds`, on threads of its own, so a test
    can hold an answer back for longer than any timeout under test. */
private final class TestHTTPResponder: @unchecked Sendable {
    let port: Int

    private let delaySeconds: Double
    private let listener: Int32
    private let lock = NSLock()
    private var accepted = 0
    private var stopped = false
    private var statusCode: Int

    init(
        delaySeconds: Double = 0, family: Int32 = AF_INET, port: Int = 0, statusCode: Int = 200
    ) throws {
        let sock = socket(family, SOCK_STREAM, 0)
        guard sock >= 0 else { throw ResponderError.socket(errno: errno) }
        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        let bound: Int
        if family == AF_INET6 {
            var only: Int32 = 1
            setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = UInt16(port).bigEndian
            addr.sin6_addr = in6addr_loopback
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard result == 0 else {
                close(sock)
                throw ResponderError.bind(errno: errno)
            }
            var found = sockaddr_in6()
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            _ = withUnsafeMutablePointer(to: &found) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
            }
            bound = Int(UInt16(bigEndian: found.sin6_port))
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else {
                close(sock)
                throw ResponderError.bind(errno: errno)
            }
            var found = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &found) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
            }
            bound = Int(UInt16(bigEndian: found.sin_port))
        }
        listen(sock, 8)
        self.delaySeconds = delaySeconds
        self.listener = sock
        self.port = bound
        self.statusCode = statusCode
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "directa-test-http-responder"
        thread.start()
    }

    /** Connections accepted so far. */
    var connections: Int {
        lock.withLock { accepted }
    }

    /** The status the next answer carries. */
    func respond(with code: Int) {
        lock.withLock { statusCode = code }
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }

    private func acceptLoop() {
        defer { close(listener) }
        while !isStopped {
            var target = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&target, 1, 50) == 1 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            lock.withLock { accepted += 1 }
            let thread = Thread { [self] in answer(client) }
            thread.name = "directa-test-http-answer"
            thread.start()
        }
    }

    private func answer(_ client: Int32) {
        defer { close(client) }
        /** A client that gave up must not turn this write into a SIGPIPE that
            takes the whole test process down. */
        var quiet: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &quiet, socklen_t(MemoryLayout<Int32>.size))
        var request = [UInt8](repeating: 0, count: 4096)
        var incoming = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        guard poll(&incoming, 1, 2000) == 1 else { return }
        _ = recv(client, &request, request.count, 0)
        var waited = 0.0
        while waited < delaySeconds, !isStopped {
            usleep(20_000)
            waited += 0.02
        }
        let code = lock.withLock { statusCode }
        let response = "HTTP/1.1 \(code) Test\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = Array(response.utf8).withUnsafeBufferPointer { send(client, $0.baseAddress, $0.count, 0) }
    }
}

/** The real prober against real HTTP and TCP listeners: what a probe reports
    and how long it is allowed to take. */
@Suite struct NetworkHealthProberTests {
    private func url(_ responder: TestHTTPResponder, host: String = "127.0.0.1") -> String {
        "http://\(host):\(responder.port)/health"
    }

    /** `timeoutMs` bounds the whole probe. A shared session capped every probe
        at five seconds whatever the config said, so a cold boot that answered
        at seven read as a timeout. Runs beside every other suite and costs the
        seven seconds of the answer it waits for. */
    @Test func aSlowAnswerInsideTimeoutMsPasses() async throws {
        let responder = try TestHTTPResponder(delaySeconds: 7)
        defer { responder.stop() }
        let clock = ContinuousClock()
        let began = clock.now
        let outcome = await NetworkHealthProber().probe(
            .http(url: url(responder), timeoutMs: 10_000))
        #expect(outcome == .pass)
        #expect(began.duration(to: clock.now) >= .seconds(7))
    }

    @Test func anAnswerPastTimeoutMsFailsAtTheDeadlineAndSaysSo() async throws {
        let responder = try TestHTTPResponder(delaySeconds: 6)
        defer { responder.stop() }
        let clock = ContinuousClock()
        let began = clock.now
        let outcome = await NetworkHealthProber().probe(.http(url: url(responder), timeoutMs: 500))
        let elapsed = began.duration(to: clock.now)
        #expect(outcome == .fail("timed out after 0.5s"))
        #expect(elapsed >= .milliseconds(450))
        #expect(elapsed < .seconds(3))
    }

    @Test func aWholeSecondDeadlineReadsAsSeconds() async throws {
        let responder = try TestHTTPResponder(delaySeconds: 6)
        defer { responder.stop() }
        let outcome = await NetworkHealthProber().probe(.http(url: url(responder), timeoutMs: 1000))
        #expect(outcome == .fail("timed out after 1s"))
    }

    @Test(arguments: [(200, true), (204, true), (301, true), (404, false), (500, false), (503, false)])
    func theStatusCodeDecidesAndNamesItselfOnFailure(code: Int, passes: Bool) async throws {
        let responder = try TestHTTPResponder(statusCode: code)
        defer { responder.stop() }
        let outcome = await NetworkHealthProber().probe(.http(url: url(responder), timeoutMs: 2000))
        #expect(outcome == (passes ? .pass : .fail("HTTP \(code)")))
    }

    @Test func aRefusedConnectionSaysSo() async {
        /** Port 1 is privileged, so nothing on a developer machine is bound to
            it and the connect is refused at once. */
        let outcome = await NetworkHealthProber().probe(
            .http(url: "http://127.0.0.1:1/health", timeoutMs: 2000))
        #expect(outcome == .fail("connection refused"))
    }

    /** A refusal says the port is free on IPv4; a dev server bound to `::1`
        alone (Vite 5+) is then found on IPv6. */
    @Test func aRefusedIPv4ConnectionFallsBackToIPv6ForALocalhostName() async throws {
        let v6 = try TestHTTPResponder(family: AF_INET6)
        defer { v6.stop() }
        let outcome = await NetworkHealthProber().probe(
            .http(url: "http://probe.localhost:\(v6.port)/health", timeoutMs: 2000))
        #expect(outcome == .pass)
        #expect(v6.connections == 1)
    }

    /** A timeout on IPv4 means something holds the address and has not
        answered. A second wait on IPv6 would stretch the probe past the
        `timeoutMs` the caller chose, and a pass from another stack's listener
        would hide that the server itself is not answering. */
    @Test func anIPv4TimeoutDoesNotRetryIPv6() async throws {
        let v4 = try TestHTTPResponder(delaySeconds: 5)
        defer { v4.stop() }
        let v6 = try TestHTTPResponder(family: AF_INET6, port: v4.port)
        defer { v6.stop() }
        let clock = ContinuousClock()
        let began = clock.now
        let outcome = await NetworkHealthProber().probe(
            .http(url: "http://probe.localhost:\(v4.port)/health", timeoutMs: 600))
        let elapsed = began.duration(to: clock.now)
        #expect(outcome == .fail("timed out after 0.6s"))
        #expect(elapsed < .milliseconds(1500))
        #expect(v6.connections == 0)
    }

    @Test func aLocalhostNameRefusedOnBothFamiliesSaysRefused() async {
        let outcome = await NetworkHealthProber().probe(
            .http(url: "http://probe.localhost:1/health", timeoutMs: 2000))
        #expect(outcome == .fail("connection refused"))
    }

    @Test func tcpPassesAgainstAListenerAndNamesARefusal() async throws {
        let responder = try TestHTTPResponder()
        defer { responder.stop() }
        let prober = NetworkHealthProber()
        #expect(await prober.probe(.tcp(port: responder.port, timeoutMs: 1000)) == .pass)
        #expect(await prober.probe(.tcp(port: 1, timeoutMs: 1000)) == .fail("connection refused"))
    }

    @Test func noHealthcheckAlwaysPasses() async {
        #expect(await NetworkHealthProber().probe(.none(stabilizationMs: 2000)) == .pass)
    }
}

/** A server that answers 500 reads "running and healthy" in `why` until
    enough checks fail to turn it unhealthy. These drive a real Router, a real
    supervisor, and a real HTTP responder end to end. */
@Suite(.temporaryTree) struct HealthReportingEndToEndTests {
    @Test func whyNamesTheFailingCheckOfARunningServerAnswering500() async throws {
        let responder = try TestHTTPResponder()
        defer { responder.stop() }
        let env = try makeRouterEnv(named: "why-health")
        /** `unhealthyAfter` stays far above what this test reaches, so the
            phase holds at `running` while the checks fail. */
        let config = """
            {"servers":{"web":{"command":["/bin/sh","-c","sleep 60"],\
            "healthcheck":{"intervalMs":100,"timeoutMs":1000,"type":"http","unhealthyAfter":200,\
            "url":"http://127.0.0.1:\(responder.port)/health"}}},"version":1}
            """
        try Data(config.utf8).write(
            to: URL(fileURLWithPath: env.project).appending(path: "devservers.json"))
        let router = Router(
            launcher: SubprocessLauncher(), paths: env.paths, registry: Registry(paths: env.paths))
        let target = ServerTargetParams(name: "web", project: env.project)
        let statusParams = ProjectParams(name: "web", project: env.project)

        _ = try await router.call(.serverStart, target, ServerResult.self)
        func latest() async throws -> ServerStatus? {
            try await router.call(.serverStatus, statusParams, ServerListResult.self).servers.first
        }
        let healthy = try await eventually(within: .seconds(5)) {
            let status = try await latest()
            return status?.phase == .running && status?.lastHealthCheck?.passed == true
        }
        try #require(healthy)
        #expect(
            try await router.call(.serverWhy, target, WhyResult.self).findings.first?.summary
                == "running and healthy")

        responder.respond(with: 500)
        let failing = try await eventually(within: .seconds(5)) {
            (try await latest()?.lastHealthCheck?.failures ?? 0) >= 2
        }
        try #require(failing)
        let status = try #require(try await latest())
        #expect(status.phase == .running)
        #expect(status.lastHealthCheck?.detail == "HTTP 500")

        let summary = try #require(
            try await router.call(.serverWhy, target, WhyResult.self).findings.first?.summary)
        #expect(summary.hasPrefix("running; "))
        #expect(summary.hasSuffix(" health checks failed in a row (HTTP 500)"))
        #expect(!summary.contains("healthy"))

        /** The next pass brings the description back. */
        responder.respond(with: 200)
        let recovered = try await eventually(within: .seconds(5)) {
            try await latest()?.lastHealthCheck?.passed == true
        }
        try #require(recovered)
        #expect(
            try await router.call(.serverWhy, target, WhyResult.self).findings.first?.summary
                == "running and healthy")
        _ = try await router.call(.serverStop, target, ServerResult.self)
    }
}
