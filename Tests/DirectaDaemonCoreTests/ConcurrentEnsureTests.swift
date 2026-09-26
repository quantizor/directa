import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaDaemonCore

/** Two sessions calling `ensure` on the same server at the same moment is the
    ordinary case for this tool, not an edge one: agents run concurrently, and
    the session-start hook plus a hand-typed command can land together. The
    invariant is that the second caller joins the first spawn rather than racing
    it, so exactly one process exists and both callers are told the same pid.

    `docs/design.md` promised this as an end-to-end test in a target that only
    ever held `#expect(Bool(true))`, so the promise outlived the coverage. */
@Suite(.serialized, .temporaryTree) struct ConcurrentEnsureTests {
    private func env(port: Int) throws -> (paths: DirectaPaths, project: String) {
        let base = try TemporaryTree.directory(named: "concurrent")
        let project = base.appending(path: "proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fixture = try #require(fixtureServerExecutable())
        let body = """
            {
              "servers": {
                "web": {
                  "command": ["\(fixture)", "--listen-tcp", "\(port)"],
                  "healthcheck": { "type": "tcp", "port": \(port) },
                  "port": \(port)
                }
              },
              "version": 1
            }
            """
        try Data(body.utf8).write(to: project.appending(path: "devservers.json"))
        return (
            paths: DirectaPaths(
                dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
            project: project.path
        )
    }

    private func ensure(_ router: Router, project: String) async throws -> EnsureResult {
        let line = try NDJSON.encodeLine(
            WireRequest(
                id: "e", method: WireMethod.serverEnsure.rawValue,
                params: EnsureParams(name: "web", project: project, timeoutSeconds: 15)))
        let response = try JSONCoding.decoder().decode(
            WireResponse<EnsureResult>.self, from: await router.handle(line: line))
        if response.ok, let result = response.result { return result }
        throw response.error ?? WireError(code: .internalError, message: "ensure returned nothing")
    }

    private func stop(_ router: Router, project: String) async {
        guard
            let line = try? NDJSON.encodeLine(
                WireRequest(
                    id: "s", method: WireMethod.serverStop.rawValue,
                    params: ServerTargetParams(name: "web", project: project)))
        else { return }
        _ = await router.handle(line: line)
    }

    @Test func simultaneousEnsuresProduceOneProcess() async throws {
        let env = try env(port: 45471)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        /** Eight at once rather than two: a single pair can pass by luck if the
            first happens to finish before the second is dispatched. */
        let results = try await withThrowingTaskGroup(of: EnsureResult.self) { group in
            for _ in 0..<8 {
                group.addTask { try await self.ensure(router, project: env.project) }
            }
            var collected: [EnsureResult] = []
            for try await result in group { collected.append(result) }
            return collected
        }

        #expect(results.count == 8)
        let pids = Set(results.compactMap(\.server.pid))
        #expect(pids.count == 1, "each caller should see the same process, saw pids \(pids)")
        for result in results {
            #expect(result.server.phase == .running)
        }

        /** The claim that matters is about the machine, not the replies: a
            second spawn that the supervisor forgot about would still be holding
            the port and would not show up in any of the answers above. */
        let pid = try #require(pids.first)
        let live: [pid_t] = ProcessTree.descendants(of: pid_t(pid)).identities.map(\.pid)
        #expect(live.isEmpty, "the one server spawned unexpected children: \(live)")

        /** Awaited, never a detached Task in a defer: that returns immediately
            and the test process can exit before the stop lands, leaking a server
            that squats this port for the next run. */
        await stop(router, project: env.project)
    }

    /** The race behind a second ensure calling the first ensure's child an
        unmanaged squatter, pinned without timing luck. The second start
        reaches the port pre-check before the first has spawned; the first then
        spawns and its child binds before the second's probe answers. The
        scripted probe stands in for that bind: its first call runs the first
        start through to a pid, then reports the port as listening. That
        listener is the server's own run, so the second start joins it. */
    @Test func aRunSpawnedWhileThePreCheckProbesIsTheServersOwn() async throws {
        let port = 45473
        let base = try TemporaryTree.directory(named: "concurrent")
        let project = base.appending(path: "proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let paths = DirectaPaths(
            dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs"))
        let registry = Registry(paths: paths)
        try await registry.register(
            project: project.path,
            spec: ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web", port: port))
        let script = ProbeScript()
        let startLine = try NDJSON.encodeLine(
            WireRequest(
                id: "s", method: WireMethod.serverStart.rawValue,
                params: ServerTargetParams(name: "web", project: project.path)))
        let probe = PortProbe { probed in
            guard probed == port else { return false }
            switch await script.next() {
            case .interleave:
                guard let router = await script.router else { return false }
                let first = await router.handle(line: startLine)
                await script.recordFirst(first)
                return true
            case .free:
                return false
            case .bound:
                return true
            }
        }
        let router = Router(
            launcher: SubprocessLauncher(), paths: paths, portProbe: probe, registry: registry)
        await script.attach(router)

        let secondData = await router.handle(line: startLine)
        let second = try JSONCoding.decoder().decode(WireResponse<ServerResult>.self, from: secondData)
        let recorded = await script.first
        let firstData = try #require(recorded)
        let first = try JSONCoding.decoder().decode(WireResponse<ServerResult>.self, from: firstData)
        let firstPid = try #require(first.result?.server.pid)
        defer { kill(pid_t(firstPid), SIGKILL) }
        #expect(second.ok, "the second start was refused: \(String(describing: second.error))")
        #expect(second.result?.server.pid == firstPid)
        await stop(router, project: project.path)
    }

    /** The same burst with no `stop` mixed in, which is the half that is known
        to hold. Interleaving a stop kills the test process outright; that is
        written up in BACKLOG.md with its reproduction rather than committed as
        a test that takes the suite down with it. */
    @Test func repeatedEnsuresNeverLeaveASecondListener() async throws {
        let env = try env(port: 45472)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = try await ensure(router, project: env.project)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { _ = try? await self.ensure(router, project: env.project) }
            }
        }
        await stop(router, project: env.project)

        /** Asks the port itself rather than the daemon, because the daemon's own
            view is exactly what a leaked process would be missing from. */
        var free = false
        for _ in 0..<50 where !free {
            free = !LoopbackProbe.isListening(port: 45472)
            if !free { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(free, "port 45472 is still held after every server was stopped")
    }
}

/** Drives the scripted probe: the outer request's first probe interleaves the
    first start, probes made while that start runs its own pre-check see a free
    port, and every probe after it sees the port bound. */
private actor ProbeScript {
    enum Step {
        case bound
        case free
        case interleave
    }

    private(set) var first: Data?
    private var interleaving = false
    private(set) var router: Router?

    func attach(_ router: Router) {
        self.router = router
    }

    func next() -> Step {
        if first != nil { return .bound }
        if interleaving { return .free }
        interleaving = true
        return .interleave
    }

    func recordFirst(_ data: Data) {
        first = data
    }
}
