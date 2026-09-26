import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

private struct TestEnv {
    let paths: DirectaPaths
    /** A real directory: the child chdirs into it, so it must exist. */
    let projectPath: String
}

private func makeEnv() throws -> TestEnv {
    let base = FileManager.default.temporaryDirectory.appending(path: "directa-sup-\(UUID().uuidString)")
    let project = base.appending(path: "proj")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    return TestEnv(
        paths: DirectaPaths(dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
        projectPath: project.path)
}

@Suite struct SupervisorTests {
    @Test func startCapturesOutputAndStopKillsGroup() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(
            command: ["/bin/sh", "-c", "echo started; sleep 30"], name: "web")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        /** start() settles at spawn; health promotion to `running` follows. */
        #expect(started.phase == .starting)
        #expect(started.pid != nil)
        try await Task.sleep(for: .milliseconds(300))
        let spool = paths.structuredLogFile(project: env.projectPath, server: "web")
        let contents = try String(contentsOf: spool, encoding: .utf8)
        #expect(contents.contains("started"))
        let stopped = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
        #expect(stopped.phase == .stopped)
        #expect(stopped.pid == nil)
        if let pid = started.pid {
            #expect(kill(pid_t(pid), 0) != 0)
        }
    }

    @Test func spawnFailureIsFailedNotCrashed() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/nonexistent/binary-xyz"], name: "bad")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        let status = await supervisor.start()
        #expect(status.phase == .failed)
        #expect(status.spawnError != nil)
        #expect(status.pid == nil)
    }

    @Test func deliberateStopRetiresBootIntent() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web")
        let id = serverID(project: env.projectPath, name: "web")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        /** Start records the intent to come back after a reboot. */
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)
        _ = await supervisor.stop(graceSeconds: 2, deliberate: true, reason: "requested by stop")
        /** A deliberate stop retires it: the user asked for down. */
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == nil)
    }

    @Test func drainStopPreservesBootIntent() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web")
        let id = serverID(project: env.projectPath, name: "web")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        _ = await supervisor.stop(
            graceSeconds: 2, deliberate: false, reason: "daemon shutting down")
        /** A launchd drain keeps the intent so the next boot restores the server,
            while the drained phase reads stopped. */
        let persisted = await registry.persistedState(serverID: id)
        #expect(persisted?.phase == .stopped)
        #expect(persisted?.resumeOnBoot == true)
    }

    /** `ensure` called while a flooding server's own `stop()` is still
        draining the tailer must wait for the phase to actually leave
        `.stopping`, not resume the moment `runTask` goes nil (set at the top
        of `recordOutcome`, well before that drain and the registry write
        after it finish). A caller resuming on `runTask` alone recurses
        against a phase that has not moved, on the actor, without ever
        suspending, and grows the daemon's memory without bound. */
    @Test func ensureDuringASlowStopWaitsForThePhaseToLeaveStopping() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let fixture = try #require(fixtureServerExecutable())
        let port = 45480
        let spec = ServerSpec(
            command: [fixture, "--flood", "--listen-tcp", "\(port)"],
            healthcheck: HealthCheckSpec(port: port, type: .tcp), name: "flood", port: port)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        let outcome = await supervisor.wait(for: .healthy, timeoutSeconds: 5)
        #expect(outcome == nil)

        async let stopped: ServerStatus = supervisor.stop(
            graceSeconds: 2, deliberate: false, reason: "test")
        /** A head start so stop() has set `.stopping` and sent SIGTERM before
            ensure() observes it. */
        try await Task.sleep(for: .milliseconds(50))
        #expect(await supervisor.status().phase == .stopping)

        let ensured = await supervisor.ensure(timeoutSeconds: 5)
        #expect(ensured.server.phase == .running)
        #expect(ensured.server.pid != started.pid)

        _ = await stopped
        _ = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
    }

    /** Same defect class, `start()`'s `.stopping` arm: the path `up`
        (`.groupUp`) uses for a spec whose `waitFor` is `started`. */
    @Test func startDuringASlowStopWaitsForThePhaseToLeaveStopping() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let fixture = try #require(fixtureServerExecutable())
        let port = 45481
        let spec = ServerSpec(
            command: [fixture, "--flood", "--listen-tcp", "\(port)"],
            healthcheck: HealthCheckSpec(port: port, type: .tcp), name: "flood", port: port)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        let outcome = await supervisor.wait(for: .healthy, timeoutSeconds: 5)
        #expect(outcome == nil)

        async let stopped: ServerStatus = supervisor.stop(
            graceSeconds: 2, deliberate: false, reason: "test")
        try await Task.sleep(for: .milliseconds(50))
        #expect(await supervisor.status().phase == .stopping)

        let restarted = await supervisor.start()
        #expect(restarted.pid != started.pid)
        #expect(restarted.phase == .starting || restarted.phase == .running)

        _ = await stopped
        _ = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
    }

    /** `stop()`'s own wait must not hang its caller forever if the real
        transition never lands within its bound: it logs and returns with an
        honest `.stopping` phase rather than fabricating a terminal one.
        `StuckRunLauncher` blocks `run()` on a gate the test controls, which is
        what makes the deadline reachable deterministically and fast instead
        of needing a real `graceSeconds + 10s` wait or a race against flood
        drain speed. */
    @Test func stopGivesUpAfterItsBoundAndLeavesPhaseHonestlyStopping() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/true"], name: "stuck")
        let gate = AdoptGate()
        let supervisor = ServerSupervisor(
            launcher: StuckRunLauncher(gate: gate), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec,
            stopTiming: StopTiming(graceSeconds: StopTiming.standard.graceSeconds, overtimeSeconds: 0.2))
        let started = await supervisor.start()
        #expect(started.pid != nil)

        let stopped = await supervisor.stop(graceSeconds: 0.1, reason: "test")
        #expect(stopped.phase == .stopping)

        let logs = await supervisor.logQuery(LogQueryOptions(streams: [.sys])).lines
        #expect(logs.contains { $0.text.contains("stop did not complete within") })

        /** Let the fake `run()` resolve now, so recordOutcome can actually
            finish and nothing is left suspended past the test. */
        await gate.signal(.signaled(signal: Int(SIGKILL)))
        var cleared = false
        for _ in 0..<50 where !cleared {
            cleared = await supervisor.status().phase != .stopping
            if !cleared { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(cleared, "server never left .stopping after the bounded wait gave up")
    }

    private func awaitPhase(_ phase: ServerPhase, of supervisor: ServerSupervisor) async throws {
        for _ in 0..<50 where await supervisor.status().phase != phase {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await supervisor.status().phase == phase)
    }

    /** A `start()` that joins a stop which never lands gives up with the
        stop's own bound (grace plus overtime, 0.15 s here) and reports the
        honest `.stopping`, rather than holding its caller until the run
        finally exits. The gate opens after 1 s on its own, so an unbounded
        join is observed as a late return that restarted the server. */
    @Test func startJoiningAStuckStopGivesUpWithTheStopsOwnBound() async throws {
        let env = try makeEnv()
        let gate = AdoptGate()
        let supervisor = ServerSupervisor(
            launcher: StuckRunLauncher(gate: gate), paths: env.paths, projectPath: env.projectPath,
            registry: Registry(paths: env.paths), spec: ServerSpec(command: ["/bin/true"], name: "stuck"),
            stopTiming: StopTiming(graceSeconds: StopTiming.standard.graceSeconds, overtimeSeconds: 0.1))
        #expect(await supervisor.start().pid != nil)

        async let stopped = supervisor.stop(graceSeconds: 0.05, reason: "test")
        try await awaitPhase(.stopping, of: supervisor)
        let release = Task {
            try? await Task.sleep(for: .seconds(1))
            await gate.signal(.signaled(signal: Int(SIGKILL)))
        }

        let joinStart = ContinuousClock.now
        let joined = await supervisor.start()
        let waited = joinStart.duration(to: .now)
        #expect(joined.phase == .stopping)
        #expect(waited < .milliseconds(700), "start waited \(waited) on a stop bounded at 0.15 s")

        release.cancel()
        await release.value
        _ = await stopped
    }

    /** An `ensure()` that first waits out a stop spends only what is left of
        its timeout afterwards: the stop clears at 0.6 s, the fresh run (no
        healthcheck, so a 2 s stabilization window) cannot turn healthy, and
        the whole call times out near its 1 s budget rather than 0.6 s plus
        a second full second. */
    @Test func ensureAfterAStopClearsSpendsOnlyTheRemainingTimeout() async throws {
        let env = try makeEnv()
        let gate = AdoptGate()
        let supervisor = ServerSupervisor(
            launcher: StuckRunLauncher(gate: gate), paths: env.paths, projectPath: env.projectPath,
            registry: Registry(paths: env.paths), spec: ServerSpec(command: ["/bin/true"], name: "stuck"),
            stopTiming: StopTiming(graceSeconds: StopTiming.standard.graceSeconds, overtimeSeconds: 0.1))
        #expect(await supervisor.start().pid != nil)

        async let stopped = supervisor.stop(graceSeconds: 0.05, reason: "test")
        try await awaitPhase(.stopping, of: supervisor)
        let release = Task {
            try? await Task.sleep(for: .milliseconds(600))
            await gate.signal(.signaled(signal: Int(SIGKILL)))
        }

        let ensureStart = ContinuousClock.now
        let result = await supervisor.ensure(timeoutSeconds: 1)
        let waited = ensureStart.duration(to: .now)
        #expect(result.reason == .timeout)
        #expect(waited < .milliseconds(1_350), "ensure took \(waited) against a 1 s timeout")

        await release.value
        _ = await stopped
        /** The fresh run's survivor dies to this stop's SIGKILL; the gate's
            second signal lets its fake `run()` return. */
        async let cleanup = supervisor.stop(graceSeconds: 0.05, reason: "test cleanup")
        await gate.signal(.signaled(signal: Int(SIGKILL)))
        _ = await cleanup
    }

    /** Two self-exits in the stall window (nonzero, bounded lifetime, never
        healthy) are the crash-loop an interactive credential prompt produces:
        surfaced as blockedOn, persisted across a daemon restart, and cleared
        the first time a run dies differently. */
    @Test func repeatedTimedSelfExitsSurfaceAsBlockedOnInteractiveAuth() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let fixture = try #require(fixtureServerExecutable())
        let spec = ServerSpec(
            command: [fixture, "--exit-after", "2.5", "--code", "1"], name: "auth-stall")
        let bounds = (minSeconds: 1, maxSeconds: 300)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec, stallBounds: bounds)
        let id = serverID(project: env.projectPath, name: "auth-stall")

        func awaitCrashed() async throws -> ServerStatus {
            var status = await supervisor.status()
            for _ in 0..<80 where status.phase != .crashed {
                try await Task.sleep(for: .milliseconds(100))
                status = await supervisor.status()
            }
            return status
        }

        _ = await supervisor.start()
        let first = try await awaitCrashed()
        #expect(first.phase == .crashed)
        #expect(first.blockedOn == nil)

        _ = await supervisor.start()
        let second = try await awaitCrashed()
        #expect(second.phase == .crashed)
        #expect(second.blockedOn == "interactive-auth")
        #expect(await registry.persistedState(serverID: id)?.stallStreak == 2)

        /** The classification survives a daemon restart through the state file. */
        let rehydrated = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec, stallBounds: bounds)
        #expect(await rehydrated.status().blockedOn == "interactive-auth")

        /** A run that dies differently (instantly, here) breaks the pattern. */
        await supervisor.updateSpec(
            ServerSpec(
                command: [fixture, "--exit-after", "0.1", "--code", "1"], name: "auth-stall"))
        _ = await supervisor.start()
        let third = try await awaitCrashed()
        #expect(third.phase == .crashed)
        #expect(third.blockedOn == nil)
        #expect(await registry.persistedState(serverID: id)?.stallStreak == nil)
    }

    /** The crash path's descendants are escalated like a deliberate stop's: an
        orphaned `sleep` inherits the root's SIG_IGN through the shell chain
        (bash cannot reset a disposition ignored on entry, which is how a real
        tree ignores the first pass wholesale), keeps the root's session after
        reparenting, and answers the SIGTERM pass by ignoring it. Without an
        escalation it holds its listeners past the crash while the next ensure
        races it for the port. The Foundation-Process grandchild is not a valid
        stand-in here: posix_spawn resets inherited dispositions, so that child
        dies from the first pass and tests nothing. */
    @Test func crashPathEscalatesDescendantsThatIgnoreTerm() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let fixture = try #require(fixtureServerExecutable())
        let spec = ServerSpec(
            command: [fixture, "--orphan-grandchild-ignterm", "--exit-after", "0.5", "--code", "1"],
            name: "ignorer")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        var status = await supervisor.status()
        for _ in 0..<50 where status.phase != .crashed {
            try await Task.sleep(for: .milliseconds(100))
            status = await supervisor.status()
        }
        #expect(status.phase == .crashed)

        let spool = paths.spoolOutFile(project: env.projectPath, server: "ignorer")
        var grandchildPid: pid_t?
        for _ in 0..<30 {
            let contents = (try? String(contentsOf: spool, encoding: .utf8)) ?? ""
            if let line = contents.split(separator: "\n").first(where: { $0.contains("grandchild pid") }),
                let pid = pid_t(line.split(separator: " ").last.map(String.init) ?? "")
            {
                grandchildPid = pid
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let pid = try #require(grandchildPid)
        /** The escalation grace plus margin: a SIGTERM-obedient tree is already
            gone by here; this one answered the first pass by ignoring it. */
        try await Task.sleep(for: .milliseconds(2500))
        #expect(kill(pid, 0) != 0)
    }

    @Test func crashRecordsExitForensics() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "exit 3"], name: "flaky")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        /** The exit lands asynchronously; poll briefly for the phase transition. */
        var status = await supervisor.status()
        for _ in 0..<50 where status.phase != .crashed {
            try await Task.sleep(for: .milliseconds(100))
            status = await supervisor.status()
        }
        #expect(status.phase == .crashed)
        #expect(status.lastExit?.code == 3)
        /** Forensics survive into the persisted state file. */
        let persisted = await registry.persistedState(serverID: serverID(project: env.projectPath, name: "flaky"))
        #expect(persisted?.lastExit?.code == 3)
    }

    /** A SIGTERM directa never sent (something else signalled the pid directly)
        is the shape of an external supervisor, an IDE stop button, or a
        forwarded Ctrl-C: not a crash, so the phase lands `stopped` and the
        event names the signal and that it came from outside directa. Boot
        intent must survive it, since nobody told directa to keep this down. */
    @Test func externalSIGTERMLandsStoppedWithTheSignalNamedAsExternal() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let events = EventStore(url: paths.eventsFile)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web")
        let id = serverID(project: env.projectPath, name: "web")
        let supervisor = ServerSupervisor(
            events: events, launcher: SubprocessLauncher(), paths: paths,
            projectPath: env.projectPath, registry: registry, spec: spec)
        let started = await supervisor.start()
        let pid = try #require(started.pid)
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)

        kill(pid_t(pid), SIGTERM)
        let status = try await waitForPhase(supervisor, .stopped)
        #expect(status.phase == .stopped)
        #expect(status.lastExit?.signal == Int(SIGTERM))

        /** An external signal is not a directa decision, so it must not retire
            the intent to come back on the next boot. */
        let persisted = await registry.persistedState(serverID: id)
        #expect(persisted?.phase == .stopped)
        #expect(persisted?.resumeOnBoot == true)

        /** Queried unfiltered: the supervisor canonicalizes projectPath at
            construction (`/private/var` vs `/var` on a symlinked temp dir), so
            filtering on env.projectPath's raw spelling would silently match
            nothing; this EventStore is this test's own temp file regardless. */
        let posted = await events.query()
        let stoppedEvent = try #require(posted.last { $0.kind == .stopped })
        #expect(stoppedEvent.detail == "signal=15 (external)")
    }

    /** SIGKILL cannot be a polite request (the process never runs a handler
        for it), so it stays `crashed` exactly like before this feature. */
    @Test func externalSIGKILLStaysCrashed() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        let pid = try #require(started.pid)

        kill(pid_t(pid), SIGKILL)
        let status = try await waitForPhase(supervisor, .crashed)
        #expect(status.phase == .crashed)
        #expect(status.lastExit?.signal == Int(SIGKILL))
    }

    /** A directa-requested stop is unchanged by the external-signal carve-out:
        SIGTERM sent by directa's own stop() still retires boot intent exactly
        as before. */
    @Test func directaRequestedStopIsUnchangedByTheExternalSignalCarveOut() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let events = EventStore(url: paths.eventsFile)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web")
        let id = serverID(project: env.projectPath, name: "web")
        let supervisor = ServerSupervisor(
            events: events, launcher: SubprocessLauncher(), paths: paths,
            projectPath: env.projectPath, registry: registry, spec: spec)
        _ = await supervisor.start()
        let stopped = await supervisor.stop(
            graceSeconds: 2, deliberate: true, reason: "requested by stop")
        #expect(stopped.phase == .stopped)

        let persisted = await registry.persistedState(serverID: id)
        #expect(persisted?.phase == .stopped)
        #expect(persisted?.resumeOnBoot == nil)

        let posted = await events.query()
        let stoppedEvent = try #require(posted.last { $0.kind == .stopped })
        #expect(stoppedEvent.detail == "requested by stop")
    }

    /** An external SIGTERM lands `stopped`, not `crashed`, but directa's own
        stop() never ran its SIGTERM/SIGKILL escalation over this run: the
        descendant sweep must still fire (gated on stopRequested, not phase) or
        a session-escaped grandchild like this one outlives the exit. */
    @Test func externalSIGTERMStillEscalatesOrphanedDescendants() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: [fixture, "--spawn-grandchild"], name: "composite")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        let root = try #require(started.pid)
        var grandchild: pid_t?
        for _ in 0..<40 {
            let spool =
                (try? String(
                    contentsOf: paths.structuredLogFile(
                        project: env.projectPath, server: "composite"),
                    encoding: .utf8)) ?? ""
            if let match = spool.range(of: #"grandchild pid (\d+)"#, options: .regularExpression) {
                grandchild = String(spool[match]).split(separator: " ").last.flatMap { pid_t($0) }
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let child = try #require(grandchild)
        #expect(kill(child, 0) == 0)

        kill(pid_t(root), SIGTERM)
        let status = try await waitForPhase(supervisor, .stopped, tries: 80)
        #expect(status.phase == .stopped)

        var reaped = false
        for _ in 0..<100 where !reaped {
            if kill(child, 0) != 0 { reaped = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if !reaped { kill(child, SIGKILL) }
        #expect(reaped, "grandchild \(child) survived an externally SIGTERM'd root")
    }

    @Test func crashKillsSessionGrandchild() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(
            command: [fixture, "--spawn-grandchild", "--exit-after", "0.6", "--code", "1"],
            name: "composite")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        #expect(started.pid != nil)
        var grandchild: pid_t?
        for _ in 0..<40 {
            let spool =
                (try? String(
                    contentsOf: paths.structuredLogFile(
                        project: env.projectPath, server: "composite"),
                    encoding: .utf8)) ?? ""
            if let match = spool.range(of: #"grandchild pid (\d+)"#, options: .regularExpression) {
                let line = String(spool[match])
                grandchild = line.split(separator: " ").last.flatMap { pid_t($0) }
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let child = try #require(grandchild)
        #expect(kill(child, 0) == 0)
        let crashed = try await waitForPhase(supervisor, .crashed, tries: 80)
        #expect(crashed.phase == .crashed)
        /** The descendant sweep runs after the phase turns, so poll for the
            outcome rather than sleeping a fixed slice: under load that fixed
            wait expires before the sweep lands and fails a working teardown. */
        var reaped = false
        for _ in 0..<100 where !reaped {
            if kill(child, 0) != 0 {
                reaped = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        /** A bare verdict here cost several sessions: "Expectation failed:
            reaped" says a descendant survived but not which one, whose child it
            was, or what group it was in, which are the three facts that separate
            a missed snapshot from a group-kill that could never have reached
            it. */
        #expect(
            reaped,
            """
            grandchild \(child) survived the crash teardown
              pgid: \(getpgid(child)) (root pid was \(started.pid.map(String.init) ?? "nil"))
              ppid: \(ProcessTree.identity(of: child) == nil ? "gone" : String(describing: parentPid(of: child)))
              state: \(processState(of: child))
            """)
        if !reaped { kill(child, SIGKILL) }
    }

    /** Deliberate stop must sweep the session, not only the parent chain. The
        fixture backgrounds a sleep through a shell that then exits, so by stop
        time the sleep has reparented away and a `descendants(of: root)` walk can
        no longer reach it: only the session sweep can. Before stop() unioned in
        the session members, this sleep outlived `directa stop`. */
    @Test func deliberateStopKillsAnOrphanedSessionGrandchild() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: [fixture, "--orphan-grandchild"], name: "web")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        let root = pid_t(exactly: try #require(started.pid))
        var grandchild: pid_t?
        for _ in 0..<40 {
            let spool =
                (try? String(
                    contentsOf: paths.structuredLogFile(project: env.projectPath, server: "web"),
                    encoding: .utf8)) ?? ""
            if let match = spool.range(of: #"grandchild pid (\d+)"#, options: .regularExpression) {
                grandchild = String(spool[match]).split(separator: " ").last.flatMap { pid_t($0) }
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let child = try #require(grandchild)
        #expect(kill(child, 0) == 0)
        /** The precondition that makes this a session-only case: the sleep is no
            longer a parent-chain descendant of the root, so only a session sweep
            finds it. */
        if let root {
            #expect(!ProcessTree.descendants(of: root).identities.contains { $0.pid == child })
        }
        let stopped = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
        #expect(stopped.phase == .stopped)
        var reaped = false
        for _ in 0..<100 where !reaped {
            if kill(child, 0) != 0 {
                reaped = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(
            reaped,
            "orphaned session grandchild \(child) survived directa stop (state: \(processState(of: child)))")
        if !reaped { kill(child, SIGKILL) }
    }

    /** A stop racing concurrent starts must signal only the run being torn
        down. The race is pid churn: a start can replace `pid` while a stop for
        the previous run is mid-teardown, and recordOutcome for the old exit can
        run while a new run is live. Every teardown signal now revalidates the pid
        against the identity captured while that process was alive and reads the
        run's fields captured at entry, so a recycled or replaced pid is never
        hit. The supervisor's host process (this test) is therefore never signaled
        out from under itself. Reaching the assertion at all is the guarantee the
        SIGKILL bug removed; the rounds force the churn that surfaced it. */
    @Test func concurrentStopAndStartNeverSignalTheWrongProcess() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        /** A short-lived child bounds the test: even an interleaving that leaves a
            teardown waiting on the run task resolves when the child exits on its
            own, so a regression cannot hang the suite, only slow this case. */
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 2"], name: "web")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        for _ in 0..<4 {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = await supervisor.stop(graceSeconds: 1, reason: "test race") }
                group.addTask { _ = await supervisor.start() }
                group.addTask { _ = await supervisor.start() }
                for await _ in group {}
            }
        }
        let phase = await supervisor.status().phase
        #expect([.stopped, .starting, .running, .crashed].contains(phase))
        _ = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
        /** The test process survived the race. */
        #expect(getpid() > 0)
    }

    /** Reads a live process's parent from ps, for failure evidence only. */
    private func parentPid(of pid: pid_t) -> String {
        shell(["/bin/ps", "-o", "ppid=", "-p", String(pid)])
    }

    private func processState(of pid: pid_t) -> String {
        let state = shell(["/bin/ps", "-o", "state=", "-p", String(pid)])
        return state.isEmpty ? "not in the process table" : state
    }

    private func shell(_ argv: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /** The same teardown guarantee, with the timing that used to decide it made
        explicit instead of left to machine load.

        Foundation's `Process` puts its child in a NEW process group, so the
        crash path's group-directed kill provably cannot reach a grandchild and
        the descendant snapshot is the only thing that can. That snapshot was
        taken once at spawn and once 100ms later, and for a server with no
        healthcheck the first health probe (which also refreshes it) waits out a
        two second stabilization window. A grandchild appearing in between was
        therefore in no snapshot at all, and a crash orphaned it permanently.

        `crashKillsSessionGrandchild` above spawns its grandchild immediately and
        so usually wins that race, which is exactly why it failed only under
        load. This one spawns at 400ms and loses it every time. */
    @Test func crashKillsAGrandchildSpawnedAfterTheEarlySnapshot() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(
            command: [
                fixture, "--spawn-grandchild", "--grandchild-after", "0.4",
                "--exit-after", "1.0", "--code", "1",
            ],
            name: "late")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        #expect(await supervisor.start().pid != nil)

        var grandchild: pid_t?
        for _ in 0..<60 where grandchild == nil {
            let log =
                (try? String(
                    contentsOf: paths.structuredLogFile(project: env.projectPath, server: "late"),
                    encoding: .utf8)) ?? ""
            if let match = log.range(of: #"grandchild pid (\d+)"#, options: .regularExpression) {
                grandchild = String(log[match]).split(separator: " ").last.flatMap { pid_t($0) }
            }
            if grandchild == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let child = try #require(grandchild, "fixture never reported a grandchild pid")
        /** The premise, asserted rather than assumed: if this ever spawned into
            the root's group, the group kill would cover it and this test would
            be proving nothing. */
        #expect(getpgid(child) == child)

        let crashed = try await waitForPhase(supervisor, .crashed, tries: 80)
        #expect(crashed.phase == .crashed)

        var reaped = false
        for _ in 0..<100 where !reaped {
            if kill(child, 0) != 0 { reaped = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if !reaped {
            /** Names the survivor and its parent, so a failure carries the
                evidence rather than only the verdict. */
            kill(child, SIGKILL)
        }
        #expect(reaped, "grandchild \(child) survived the crash teardown (pgid \(getpgid(child)))")
    }

    /** Poll the supervisor until it reaches `phase` or the budget runs out. */
    private func waitForPhase(
        _ supervisor: ServerSupervisor, _ phase: ServerPhase, tries: Int = 50
    ) async throws -> ServerStatus {
        var status = await supervisor.status()
        for _ in 0..<tries where status.phase != phase {
            try await Task.sleep(for: .milliseconds(100))
            status = await supervisor.status()
        }
        return status
    }

    @Test func crashCapturesErrorLineTally() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(
            command: ["/bin/sh", "-c", "echo boom >&2; echo bang >&2; exit 1"], name: "noisy")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let status = try await waitForPhase(supervisor, .crashed)
        #expect(status.phase == .crashed)
        /** Two stderr lines this run: directa's own count, not the lines. */
        #expect(status.errorSummary?.count == 2)
        #expect(status.errorSummary.map { $0.lastAt >= $0.firstAt } == true)
        /** And it survives into the state file for a post-restart read. */
        let persisted = await registry.persistedState(
            serverID: serverID(project: env.projectPath, name: "noisy"))
        #expect(persisted?.errorSummary?.count == 2)
    }

    @Test func respawnClearsThePreviousRunsTally() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        /** First run writes one stderr line and crashes; the second is quiet and
            sleeps, so its live tally must not inherit the first run's count. */
        let spec = ServerSpec(
            command: ["/bin/sh", "-c", "echo once >&2; exit 1"], name: "cycle")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let crashed = try await waitForPhase(supervisor, .crashed)
        #expect(crashed.errorSummary?.count == 1)
        await supervisor.updateSpec(ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "cycle"))
        _ = await supervisor.start()
        /** A fresh run starts with no tally; it fills only on the next failure. */
        #expect(await supervisor.status().errorSummary == nil)
        _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
    }

    @Test func errorSummaryRehydratesFromStateFile() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let id = serverID(project: env.projectPath, name: "web")
        /** A prior daemon left a crashed row with a tally; a fresh supervisor for
            the same server surfaces it without re-running anything. */
        let seed = Registry(paths: paths)
        try await seed.updateState(serverID: id) { entry in
            entry.errorSummary = ErrorSummary(
                count: 4,
                firstAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastAt: Date(timeIntervalSince1970: 1_700_000_009))
            entry.phase = .crashed
        }
        let registry = Registry(paths: paths)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web"))
        let status = await supervisor.status()
        #expect(status.phase == .crashed)
        #expect(status.errorSummary?.count == 4)
    }

    /** A rehydrated crashed server has no `recentLogTail` in memory (only
        `errorSummary` and `terminalEvidence` are persisted), so status() must
        read the log family once and serve every later call from that cache.
        Proven without a stopwatch: the family is appended to between the two
        status() calls, so a second read (the bug) would surface the new line
        while the cached answer (the fix) would not. */
    @Test func statusCachesTheLogTailAfterRehydrate() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let id = serverID(project: env.projectPath, name: "web")
        let logURL = paths.structuredLogFile(project: env.projectPath, server: "web")
        let seedLog = LogStore(currentURL: logURL)
        await seedLog.append(stream: .out, text: "rehydrate-marker-original")
        let seed = Registry(paths: paths)
        try await seed.updateState(serverID: id) { entry in
            entry.phase = .crashed
        }
        let registry = Registry(paths: paths)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web"))
        let first = await supervisor.status()
        #expect(first.phase == .crashed)
        #expect(first.recentLogTail?.contains { $0.contains("rehydrate-marker-original") } == true)
        /** A second, independent writer appends after the first status() call;
            a live reread would pick this line up, a cached answer would not. */
        let laterLog = LogStore(currentURL: logURL)
        await laterLog.append(stream: .out, text: "rehydrate-marker-appended-after-first-read")
        let second = await supervisor.status()
        #expect(second.recentLogTail == first.recentLogTail)
    }

    @Test func concurrentStartsSingleFlight() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "solo")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        async let a = supervisor.start()
        async let b = supervisor.start()
        let (first, second) = await (a, b)
        #expect(first.pid == second.pid)
        _ = await supervisor.stop(graceSeconds: 1, reason: "test cleanup")
    }

    /** `startedAt` carried into `adopt` is what the persisted state and the
        run's own uptime clock use, not the moment adoption ran: a jetsam
        restart must not reset a server's reported uptime back to zero. */
    @Test func adoptCarriesStartedAtForwardWithoutResettingUptime() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web")
        let supervisor = ServerSupervisor(
            launcher: LaunchdJobLauncher(labelPrefix: testLaunchdJobLabelPrefix), paths: paths,
            projectPath: env.projectPath,
            registry: registry, spec: spec)
        let survivor = try spawnSurvivor()
        defer { kill(survivor, SIGKILL) }
        let priorStartedAt = Date().addingTimeInterval(-500)
        let adopted = await supervisor.adopt(
            pid: survivor, label: "dev.quantizor.directa.job.uptime-test", boundPort: nil,
            startedAt: priorStartedAt)
        #expect(adopted)
        let status = await supervisor.status()
        #expect(status.pid == Int(survivor))
        #expect((status.uptimeSec ?? 0) >= 495)
        let persisted = await registry.persistedState(
            serverID: serverID(project: env.projectPath, name: "web"))
        #expect(persisted?.startedAt == priorStartedAt)
        _ = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
    }

    /** A `startedAt` the caller never had (pre-feature state, or a persisted
        row with no timestamp) still produces a usable run: adoption falls back
        to now rather than leaving the clock unset. */
    @Test func adoptFallsBackToNowWhenStartedAtIsMissing() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web")
        let supervisor = ServerSupervisor(
            launcher: LaunchdJobLauncher(labelPrefix: testLaunchdJobLabelPrefix), paths: paths,
            projectPath: env.projectPath,
            registry: registry, spec: spec)
        let survivor = try spawnSurvivor()
        defer { kill(survivor, SIGKILL) }
        #expect(
            await supervisor.adopt(
                pid: survivor, label: "dev.quantizor.directa.job.uptime-fallback", boundPort: nil,
                startedAt: nil))
        let status = await supervisor.status()
        #expect((status.uptimeSec ?? -1) >= 0)
        #expect((status.uptimeSec ?? .max) < 5)
        _ = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
    }

    /** The hole this feature closes: an adopted child that later dies must
        still reach `recordOutcome`, exactly as a spawned one does through
        `runTask`. The fake launcher's `adopt()` is signalled directly, with
        the real process left running throughout, which proves the phase
        transition is driven by the exit-watch task and not by the process
        actually dying. */
    @Test func adoptedChildExitReachesRecordOutcomeThroughTheExitWatch() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web")
        let gate = AdoptGate()
        let supervisor = ServerSupervisor(
            launcher: FakeAdoptLauncher(gate: gate), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        let survivor = try spawnSurvivor()
        defer { kill(survivor, SIGKILL) }
        #expect(
            await supervisor.adopt(
                pid: survivor, label: "dev.quantizor.directa.job.exit-test", boundPort: nil,
                startedAt: nil))
        let adopted = await supervisor.status()
        #expect(adopted.phase == .starting)
        #expect(adopted.pid == Int(survivor))
        /** The exit-watch task's first `await` races this assertion; poll
            briefly rather than asserting the instant `adopt()` returns. */
        for _ in 0..<50 where await gate.callCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await gate.callCount == 1)
        /** The real process is untouched; only the exit-watch fake fires. */
        #expect(kill(survivor, 0) == 0)
        /** SIGKILL rather than SIGTERM: this test is about the exit-watch wiring
            reaching recordOutcome at all, not about signal classification (see
            externalSIGTERMLandsStoppedWithTheSignalNamedAsExternal for that), so
            it uses the one signal that stays `crashed` regardless of who sent it. */
        await gate.signal(.signaled(signal: Int(SIGKILL)))
        let crashed = try await waitForPhase(supervisor, .crashed)
        #expect(crashed.phase == .crashed)
        #expect(crashed.lastExit?.signal == Int(SIGKILL))
        #expect(crashed.pid == nil)
        let persisted = await registry.persistedState(
            serverID: serverID(project: env.projectPath, name: "web"))
        #expect(persisted?.phase == .crashed)
        #expect(persisted?.lastExit?.signal == Int(SIGKILL))
    }

    /** An adopt whose exit watch cannot be armed must record nothing, so the
        router's bounce+respawn fallback starts from a clean supervisor: no
        pid, no phase change, no state row (and so no boot intent written by
        this attempt), and no tailer ingesting the survivor's spool. */
    @Test func adoptWhoseExitWatchCannotBeArmedRecordsNothing() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web")
        let launcher = UnwatchableAdoptLauncher()
        let supervisor = ServerSupervisor(
            launcher: launcher, paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        let survivor = try spawnSurvivor()
        defer { kill(survivor, SIGKILL) }
        let spool = paths.spoolOutFile(project: env.projectPath, server: "web")
        try FileManager.default.createDirectory(
            at: spool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: spool)

        let adopted = await supervisor.adopt(
            pid: survivor, label: "dev.quantizor.directa.job.unwatchable", boundPort: nil,
            startedAt: Date())
        #expect(adopted == false)
        #expect(launcher.prepareCallCount == 1)
        let status = await supervisor.status()
        #expect(status.phase == .stopped)
        #expect(status.pid == nil)
        #expect(
            await registry.persistedState(
                serverID: serverID(project: env.projectPath, name: "web")) == nil)

        let handle = try FileHandle(forWritingTo: spool)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("written after a refused adopt\n".utf8))
        try handle.close()
        /** A running tailer polls the spool well inside this window. */
        try await Task.sleep(for: .milliseconds(500))
        let lines = await supervisor.logQuery(LogQueryOptions(streams: [.out, .sys])).lines
        #expect(lines.isEmpty, "log after a refused adopt: \(lines.map(\.text))")
    }

    /** Group teardown after adoption must reach the same escaped session
        grandchild a spawned run's teardown reaches: adoption's
        `refreshDescendantSnapshot` and `startDescendantWatch` populate the same
        fields `recordSpawn` does, so `stop`'s session-sweep-plus-snapshot union
        has what it needs even though this supervisor never spawned the root.
        Uses the real `LaunchdJobLauncher` for the adopting supervisor so the
        exit-watch that unblocks `stop`'s wait is the genuine kqueue mechanism,
        not a stand-in. */
    @Test func groupTeardownAfterAdoptSweepsTheWholeSessionTree() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: [fixture, "--orphan-grandchild"], name: "web")
        /** Stands in for the prior daemon: spawns the tree, then is abandoned
            without stopping it, exactly as a jetsam SIGKILL of the daemon would
            leave it. */
        let priorDaemon = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        let started = await priorDaemon.start()
        let root = try #require(started.pid.flatMap { pid_t(exactly: $0) })
        var grandchild: pid_t?
        for _ in 0..<40 {
            let spool =
                (try? String(
                    contentsOf: paths.structuredLogFile(project: env.projectPath, server: "web"),
                    encoding: .utf8)) ?? ""
            if let match = spool.range(of: #"grandchild pid (\d+)"#, options: .regularExpression) {
                grandchild = String(spool[match]).split(separator: " ").last.flatMap { pid_t($0) }
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let child = try #require(grandchild)
        #expect(kill(child, 0) == 0)
        let supervisor = ServerSupervisor(
            launcher: LaunchdJobLauncher(labelPrefix: testLaunchdJobLabelPrefix), paths: paths,
            projectPath: env.projectPath,
            registry: registry, spec: spec)
        #expect(
            await supervisor.adopt(
                pid: root, label: "dev.quantizor.directa.job.teardown-test", boundPort: nil,
                startedAt: nil))
        #expect(await supervisor.status().pid == Int(root))
        /** Same precondition as the spawned-run session test: no longer a
            parent-chain descendant of the root, so only the session sweep
            (seeded by `adopt`'s own `refreshDescendantSnapshot`) finds it. */
        #expect(!ProcessTree.descendants(of: root).identities.contains { $0.pid == child })
        let stopped = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
        #expect(stopped.phase == .stopped)
        #expect(kill(root, 0) != 0)
        var reaped = false
        for _ in 0..<100 where !reaped {
            if kill(child, 0) != 0 { reaped = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(
            reaped,
            "grandchild \(child) survived group teardown after adopt (state: \(processState(of: child)))")
        if !reaped { kill(child, SIGKILL) }
    }

    /** A launchd job whose command exits instantly (a typo'd binary, a
        config error caught before the server binds) must still get its own
        stderr into the structured log `logs`/`why` read, whichever way it
        races this daemon: through an armed watch (`onSpawn`), or through
        `onExitedBeforeWatch` when it died before the arm or before launchd
        ever showed its pid. Under load the last case is common, and it is
        a crash with launchd's exit code, never a spawn failure. */
    @Test func launchdInstantExitOutputReachesTheStructuredLog() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "echo boom >&2; exit 7"], name: "web")
        let supervisor = ServerSupervisor(
            launcher: LaunchdJobLauncher(labelPrefix: testLaunchdJobLabelPrefix), paths: paths,
            projectPath: env.projectPath,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let status = try await waitForPhase(supervisor, .crashed)
        #expect(status.phase == .crashed)
        switch (status.lastExit?.code, status.lastExit?.signal) {
        case (7, nil), (nil, nil): break
        default: Issue.record("expected exit 7 or an unknown exit, got \(String(describing: status.lastExit))")
        }
        let spool = try String(
            contentsOf: paths.structuredLogFile(project: env.projectPath, server: "web"),
            encoding: .utf8)
        #expect(spool.contains("boom"))
    }

    /** A command that exits before the launcher can watch it was never
        supervised, so it must not become boot intent: otherwise every later
        daemon launch starts it again. Its output still reaches the log, and
        the phase still reads crashed so `why` has something to explain. */
    @Test(arguments: [nil, Int32.max] as [pid_t?])
    func exitBeforeWatchDrainsOutputWithoutRecordingBootIntent(pid: pid_t?) async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let supervisor = ServerSupervisor(
            launcher: ExitedBeforeWatchLauncher(pid: pid, stderrText: "boom before watch\n"),
            paths: paths,
            projectPath: env.projectPath, registry: registry,
            spec: ServerSpec(command: ["/bin/sh", "-c", "exit 1"], name: "web"))
        _ = await supervisor.start()
        let status = try await waitForPhase(supervisor, .crashed)
        #expect(status.phase == .crashed)
        #expect(status.pid == nil)
        #expect(status.lastExit?.code == nil)
        #expect(status.lastExit?.signal == nil)
        let persisted = await registry.persistedState(
            serverID: serverID(project: env.projectPath, name: "web"))
        #expect(persisted?.phase == .crashed)
        #expect(persisted?.resumeOnBoot == nil)
        let errLines = await supervisor.logQuery(LogQueryOptions(streams: [.err])).lines
        #expect(errLines.map(\.text) == ["boom before watch"])
    }

    /** The other side of the same line: a run whose exit watch was armed was
        supervised, so an exit, even an instant one that still reported its
        code, keeps the boot intent `recordSpawn` wrote. */
    @Test func armedInstantExitKeepsBootIntent() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let gate = AdoptGate()
        await gate.signal(.exited(code: 1))
        let supervisor = ServerSupervisor(
            launcher: StuckRunLauncher(gate: gate), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: ServerSpec(command: ["/bin/true"], name: "web"))
        let started = await supervisor.start()
        defer { if let pid = started.pid { kill(pid_t(pid), SIGKILL) } }
        let status = try await waitForPhase(supervisor, .crashed)
        #expect(status.lastExit?.code == 1)
        let persisted = await registry.persistedState(
            serverID: serverID(project: env.projectPath, name: "web"))
        #expect(persisted?.phase == .crashed)
        #expect(persisted?.resumeOnBoot == true)
    }

    /** A server that reached `.running` and then crashed keeps its boot intent,
        so the next daemon launch restores it. */
    @Test func runningServerThatCrashesKeepsBootIntent() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let gate = AdoptGate()
        let port = 45482
        let supervisor = ServerSupervisor(
            launcher: StuckRunLauncher(gate: gate), paths: paths, prober: AlwaysHealthyProber(),
            projectPath: env.projectPath, registry: registry,
            spec: ServerSpec(
                command: ["/bin/true"], healthcheck: HealthCheckSpec(port: port, type: .tcp),
                name: "web", port: port))
        let started = await supervisor.start()
        defer { if let pid = started.pid { kill(pid_t(pid), SIGKILL) } }
        #expect(try await waitForPhase(supervisor, .running).phase == .running)
        await gate.signal(.exited(code: 1))
        #expect(try await waitForPhase(supervisor, .crashed).phase == .crashed)
        let persisted = await registry.persistedState(
            serverID: serverID(project: env.projectPath, name: "web"))
        #expect(persisted?.resumeOnBoot == true)
    }

    /** A stop that gives up still `.stopping` abandons the supervisor's state
        writes in the same turn, so the late `recordOutcome` (the gate opening)
        leaves the row the caller settled alone. The row is settled with a
        plain `updateState` rather than `retireState`, so only the
        supervisor's own abandonment is under test: the late exit would
        otherwise stamp its `lastExit` onto the row. */
    @Test func stopForRemovalThatGivesUpAbandonsLateStateWrites() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let gate = AdoptGate()
        let id = serverID(project: env.projectPath, name: "stuck")
        let supervisor = ServerSupervisor(
            launcher: StuckRunLauncher(gate: gate), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: ServerSpec(command: ["/bin/true"], name: "stuck"),
            stopTiming: StopTiming(graceSeconds: 0.05, overtimeSeconds: 0.1))
        #expect(await supervisor.start().pid != nil)
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)

        #expect(await supervisor.stopForRemoval(reason: "unregistered"))
        try await registry.updateState(serverID: id) { $0 = PersistedServerState(phase: .stopped) }

        await gate.signal(.signaled(signal: Int(SIGKILL)))
        let settled = try await waitForPhase(supervisor, .stopped)
        #expect(settled.phase == .stopped)
        #expect(settled.lastExit?.signal == Int(SIGKILL))
        let persisted = await registry.persistedState(serverID: id)
        #expect(persisted?.phase == .stopped)
        #expect(persisted?.pid == nil)
        #expect(persisted?.resumeOnBoot == nil)
        #expect(persisted?.lastExit == nil)
    }

    /** A stop that finishes needs no retirement: its own `recordOutcome`
        already cleared the boot intent, and state writes stay live. */
    @Test func stopForRemovalThatFinishesKeepsStateWritesLive() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let id = serverID(project: env.projectPath, name: "web")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web"))
        _ = await supervisor.start()
        #expect(await supervisor.stopForRemoval(reason: "unregistered") == false)
        let persisted = await registry.persistedState(serverID: id)
        #expect(persisted?.phase == .stopped)
        #expect(persisted?.resumeOnBoot == nil)
    }

    /** A removal that joins a restart's non-deliberate stop returns false (the
        stop finished), and the restart then calls `ensure` on the same
        reference. The router has already dropped this supervisor, so a spawn
        here would run with nothing supervising it: `ensure` and `start` must
        read as stopped and spawn nothing. */
    @Test func removedSupervisorNeverSpawnsAgainAfterJoiningARestartStop() async throws {
        let env = try makeEnv()
        let gate = AdoptGate()
        let supervisor = ServerSupervisor(
            launcher: StuckRunLauncher(gate: gate), paths: env.paths, projectPath: env.projectPath,
            registry: Registry(paths: env.paths), spec: ServerSpec(command: ["/bin/true"], name: "web"),
            stopTiming: StopTiming(graceSeconds: 0.05, overtimeSeconds: 5))
        #expect(await supervisor.start().pid != nil)
        #expect(await gate.callCount == 1)

        async let restartStop = supervisor.stop(deliberate: false, reason: "requested by restart")
        #expect(try await waitForPhase(supervisor, .stopping).phase == .stopping)
        async let removal = supervisor.stopForRemoval(reason: "unregistered")
        /** Lets the removal join the stop in flight; the assertions below hold
            for either order. */
        try await Task.sleep(for: .milliseconds(100))
        await gate.signal(.signaled(signal: Int(SIGKILL)))
        _ = await restartStop
        #expect(await removal == false)

        let ensured = await supervisor.ensure(timeoutSeconds: 1)
        let started = await supervisor.start()
        defer {
            for pid in [ensured.server.pid, started.pid].compactMap({ $0 }) { kill(pid_t(pid), SIGKILL) }
        }
        #expect(ensured.reason == .stopped)
        #expect(ensured.server.pid == nil)
        #expect(started.pid == nil)
        #expect(await gate.callCount == 1)
    }

    /** Adoption is attachment, so a removed supervisor refuses it before the
        exit watch is armed (an armed watch nobody waits on would never be
        consumed). */
    @Test func removedSupervisorRefusesAdoption() async throws {
        let env = try makeEnv()
        let gate = AdoptGate()
        let supervisor = ServerSupervisor(
            launcher: FakeAdoptLauncher(gate: gate), paths: env.paths, projectPath: env.projectPath,
            registry: Registry(paths: env.paths), spec: ServerSpec(command: ["/bin/true"], name: "web"))
        #expect(await supervisor.stopForRemoval(reason: "unregistered") == false)
        let survivor = try spawnSurvivor()
        defer {
            kill(survivor, SIGKILL)
            Task { await gate.signal(.exitedStatusUnknown) }
        }
        let adopted = await supervisor.adopt(
            pid: survivor, label: "dev.quantizor.directa.job.removed", boundPort: nil, startedAt: nil)
        #expect(adopted == false)
        #expect(await supervisor.status().pid == nil)
        #expect(await supervisor.status().phase == .stopped)
    }

    /** A stop that lands while the launcher has not reported a pid yet (a
        launchd job publishes one up to a few seconds after bootstrap) waits for
        the spawn to settle and stops what it produced. Reading `.stopped` at
        once let that run come up under a stopped phase, where a later start
        spawned a second copy beside it. */
    @Test func stopBeforeThePidIsKnownStopsTheRunOnceItAppears() async throws {
        let env = try makeEnv()
        let gate = SpawnGate()
        let launcher = DelayedSpawnLauncher(gate: gate)
        let supervisor = ServerSupervisor(
            launcher: launcher, paths: env.paths, projectPath: env.projectPath,
            registry: Registry(paths: env.paths),
            spec: ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web"))
        defer { for pid in launcher.pids { kill(pid, SIGKILL) } }

        async let started = supervisor.start()
        for _ in 0..<100 where launcher.pids.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let child = try #require(launcher.pids.first)
        let pending = await supervisor.status()
        #expect(pending.phase == .starting)
        #expect(pending.pid == nil)

        let opener = Task {
            try? await Task.sleep(for: .milliseconds(200))
            await gate.open()
        }
        let stopped = await supervisor.stop(graceSeconds: 2, reason: "test")
        _ = await started
        await opener.value
        #expect(stopped.phase == .stopped)
        let settled = await supervisor.status()
        #expect(settled.phase == .stopped)
        #expect(settled.pid == nil)
        var gone = kill(child, 0) != 0
        for _ in 0..<50 where !gone {
            try await Task.sleep(for: .milliseconds(20))
            gone = kill(child, 0) != 0
        }
        #expect(gone, "pid \(child) kept running after a stop that reported stopped")
    }
}

private struct AlwaysHealthyProber: HealthProber {
    func probe(_ check: EffectiveHealthcheck) async -> Bool { true }
}

@Suite struct RegistryTests {
    @Test func registerPersistsAcrossReload() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["echo"], name: "web", port: 3000)
        try await registry.register(project: "/p", spec: spec)
        let reloaded = Registry(paths: paths)
        #expect(await reloaded.spec(project: "/p", name: "web") == spec)
    }

    @Test func unregisterRemovesEmptyProject() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        try await registry.register(project: "/p", spec: ServerSpec(command: ["echo"], name: "web"))
        try await registry.unregister(project: "/p", name: "web")
        #expect(await registry.project("/p") == nil)
    }

    /** A retired writer's every later `updateState` for that id is dropped,
        both a write to its settled row and, once `removeState` deleted that
        row, the insert that would recreate it; the settled row is what a
        reload reads, and `removeState` still deletes. */
    @Test func retiredWriterIsIgnoredButRemoveStateStillDeletes() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let id = serverID(project: env.projectPath, name: "web")
        let retired = UUID()
        try await registry.updateState(serverID: id, writer: retired) { entry in
            entry.phase = .running
            entry.pid = 4242
            entry.resumeOnBoot = true
        }
        try await registry.retireState(
            serverID: id, final: PersistedServerState(phase: .stopped), writer: retired)
        try await registry.updateState(serverID: id, writer: retired) { entry in
            entry.phase = .crashed
            entry.pid = 4243
            entry.resumeOnBoot = true
        }
        let settled = try #require(await registry.persistedState(serverID: id))
        #expect(settled.phase == .stopped)
        #expect(settled.pid == nil)
        #expect(settled.resumeOnBoot == nil)
        #expect(await Registry(paths: env.paths).persistedState(serverID: id)?.phase == .stopped)

        try await registry.removeState(serverID: id)
        #expect(await registry.persistedState(serverID: id) == nil)
        try await registry.updateState(serverID: id, writer: retired) { $0.resumeOnBoot = true }
        #expect(await registry.persistedState(serverID: id) == nil)
    }

    /** Retirement is scoped to the writer: a later supervisor for the same id
        and the router's own writes (writer nil) persist normally, including
        the insert of a row `removeState` deleted. */
    @Test func otherWritersStillPersistForARetiredID() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let id = serverID(project: env.projectPath, name: "web")
        try await registry.retireState(
            serverID: id, final: PersistedServerState(phase: .stopped), writer: UUID())
        try await registry.removeState(serverID: id)

        let successor = UUID()
        try await registry.updateState(serverID: id, writer: successor) { entry in
            entry.phase = .starting
            entry.pid = 4244
            entry.resumeOnBoot = true
        }
        let inserted = try #require(await registry.persistedState(serverID: id))
        #expect(inserted.pid == 4244)
        #expect(inserted.resumeOnBoot == true)

        try await registry.updateState(serverID: id) { $0.boundPort = 4000 }
        #expect(await registry.persistedState(serverID: id)?.boundPort == 4000)
        #expect(await Registry(paths: env.paths).persistedState(serverID: id)?.pid == 4244)
    }

    /** Retirements are keyed on the normalized id, so a `/var` vs
        `/private/var` spelling of the same project cannot slip a retired
        writer's write past it. */
    @Test func retiredWriterMatchesEitherSpellingOfTheProject() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let canonical = canonicalProjectPath(env.projectPath)
        let lexical = canonical.hasPrefix("/private/") ? String(canonical.dropFirst("/private".count)) : canonical
        let retired = UUID()
        try await registry.retireState(
            serverID: serverID(project: lexical, name: "web"), final: PersistedServerState(phase: .stopped),
            writer: retired)
        try await registry.updateState(serverID: serverID(project: canonical, name: "web"), writer: retired) {
            $0.resumeOnBoot = true
        }
        #expect(
            await registry.persistedState(serverID: serverID(project: canonical, name: "web"))?
                .resumeOnBoot == nil)
    }
}

