import DirectaKit
import DirectaTestSupport
import Foundation
import Testing
import os

@testable import DirectaDaemonCore

private func makeEnv() throws -> RouterEnv {
    try makeRouterEnv(named: "sup")
}

@Suite(.temporaryTree) struct SupervisorTests {
    @Test func startCapturesOutputAndStopKillsGroup() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(
            command: ["/bin/sh", "-c", "echo started; sleep 30"], name: "web")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        /** start() settles at spawn; health promotion to `running` follows. */
        #expect(started.phase == .starting)
        #expect(started.pid != nil)
        let spool = paths.structuredLogFile(project: env.project, server: "web")
        #expect(
            try await eventually(within: .seconds(3)) {
                ((try? String(contentsOf: spool, encoding: .utf8)) ?? "").contains("started")
            })
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
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
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
        let id = serverID(project: env.project, name: "web")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
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
        let id = serverID(project: env.project, name: "web")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
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
        let port = TestPorts.port(480)
        let spec = ServerSpec(
            command: [fixture, "--flood", "--listen-tcp", "\(port)"],
            healthcheck: HealthCheckSpec(port: port, type: .tcp), name: "flood", port: port)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        let outcome = await supervisor.wait(for: .healthy, timeoutSeconds: 5)
        #expect(outcome == nil)

        async let stopped: ServerStatus = supervisor.stop(
            graceSeconds: 2, deliberate: false, reason: "test")
        #expect(try await awaitPhase(supervisor, .stopping, within: .seconds(2)).phase == .stopping)

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
        let port = TestPorts.port(481)
        let spec = ServerSpec(
            command: [fixture, "--flood", "--listen-tcp", "\(port)"],
            healthcheck: HealthCheckSpec(port: port, type: .tcp), name: "flood", port: port)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        let outcome = await supervisor.wait(for: .healthy, timeoutSeconds: 5)
        #expect(outcome == nil)

        async let stopped: ServerStatus = supervisor.stop(
            graceSeconds: 2, deliberate: false, reason: "test")
        #expect(try await awaitPhase(supervisor, .stopping, within: .seconds(2)).phase == .stopping)

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
            launcher: StuckRunLauncher(gate: gate), paths: paths, projectPath: env.project,
            registry: registry, spec: spec,
            stopTiming: StopTiming(graceSeconds: StopTiming.standard.graceSeconds, overtimeSeconds: 0.2))
        defer { gate.signal(.exitedStatusUnknown) }
        let started = await supervisor.start()
        #expect(started.pid != nil)

        let stopped = await supervisor.stop(graceSeconds: 0.1, reason: "test")
        #expect(stopped.phase == .stopping)

        let logs = await supervisor.logQuery(LogQueryOptions(streams: [.sys])).lines
        #expect(logs.contains { $0.text.contains("stop did not complete within") })

        /** Let the fake `run()` resolve now, so recordOutcome can actually
            finish and nothing is left suspended past the test. */
        gate.signal(.signaled(signal: Int(SIGKILL)))
        let cleared = try await eventually(within: .seconds(5)) { await supervisor.status().phase != .stopping }
        #expect(cleared, "server never left .stopping after the bounded wait gave up")
    }

    /** A `start()` that joins a stop which never lands gives up with the
        stop's own bound (grace plus overtime, 0.15 s here) and reports the
        honest `.stopping`, rather than holding its caller until the run
        finally exits. The run stays stuck until the test releases it after
        `start()` returns, so a bounded join returns while it is still stuck
        and an unbounded one can only return once the safety valve releases
        it, however loaded the machine is. The valve exists so a regression
        fails instead of hanging. Releasing the run lets the stop's own
        recordOutcome finish, and the test waits for it to land `.stopped`,
        since that is the run's last write into the test's tree. */
    @Test func startWaitingOnAHungStopGivesUpWhenTheStopDoes() async throws {
        let env = try makeEnv()
        let gate = AdoptGate()
        let supervisor = ServerSupervisor(
            launcher: StuckRunLauncher(gate: gate), paths: env.paths, projectPath: env.project,
            registry: Registry(paths: env.paths), spec: ServerSpec(command: ["/bin/true"], name: "stuck"),
            stopTiming: StopTiming(graceSeconds: StopTiming.standard.graceSeconds, overtimeSeconds: 0.1))
        #expect(await supervisor.start().pid != nil)

        async let stopped = supervisor.stop(graceSeconds: 0.05, reason: "test")
        defer { gate.signal(.exitedStatusUnknown) }
        #expect(try await awaitPhase(supervisor, .stopping, within: .seconds(1)).phase == .stopping)
        let valveOpened = OSAllocatedUnfairLock(initialState: false)
        let safetyValve = Task {
            try? await Task.sleep(for: .seconds(10))
            valveOpened.withLock { $0 = true }
            gate.signal(.signaled(signal: Int(SIGKILL)))
        }

        let joined = await supervisor.start()
        let returnedWhileStuck = !valveOpened.withLock { $0 }
        #expect(joined.phase == .stopping)
        #expect(returnedWhileStuck, "start held its caller until the stuck run was released")

        /** Cancelling the valve ends its sleep early, and it then releases
            the run. */
        safetyValve.cancel()
        await safetyValve.value
        _ = await stopped
        /** The released run's recordOutcome writes the log, the event, and the
            state row before the phase leaves `.stopping`; returning earlier
            leaves it writing into a tree the trait is already removing. */
        #expect(try await awaitPhase(supervisor, .stopped, within: .seconds(5)).phase == .stopped)
    }

    /** An `ensure()` that first waits out a stop spends only what is left of
        its timeout on the fresh run, so the whole call lasts its timeout, not
        the stop wait plus a second full timeout. The fresh run can never turn
        healthy, so the call always ends by timing out. Both bounds hold
        however slowly the machine schedules the test: a whole call is never
        shorter than its timeout (what is left is measured from when the
        call began), and one that spent a full timeout after the stop cleared
        lasts at least the time until the run was released plus that timeout,
        which a remaining-time ensure stays under by the release delay, less
        the fresh start and one 100 ms health poll. */
    @Test func ensureAfterAStopClearsSpendsOnlyTheRemainingTimeout() async throws {
        let env = try makeEnv()
        let gate = AdoptGate()
        let freshRunGate = AdoptGate()
        let port = TestPorts.port(483)
        let supervisor = ServerSupervisor(
            launcher: StuckRunLauncher(gate: gate, laterRunsGate: freshRunGate), paths: env.paths, prober: NeverHealthyProber(),
            projectPath: env.project, registry: Registry(paths: env.paths),
            spec: ServerSpec(
                command: ["/bin/true"], healthcheck: HealthCheckSpec(port: port, type: .tcp),
                name: "stuck", port: port),
            stopTiming: StopTiming(graceSeconds: StopTiming.standard.graceSeconds, overtimeSeconds: 0.1))
        let first = await supervisor.start()
        #expect(first.pid != nil)

        async let stopped = supervisor.stop(graceSeconds: 0.05, reason: "test")
        defer {
            gate.signal(.exitedStatusUnknown)
            freshRunGate.signal(.exitedStatusUnknown)
        }
        #expect(try await awaitPhase(supervisor, .stopping, within: .seconds(1)).phase == .stopping)
        let timeout = Duration.seconds(3)
        let releasedAt = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
        let release = Task {
            try? await Task.sleep(for: .milliseconds(1_500))
            releasedAt.withLock { $0 = .now }
            gate.signal(.signaled(signal: Int(SIGKILL)))
        }

        let ensureStart = ContinuousClock.now
        let result = await supervisor.ensure(timeoutSeconds: timeout / .seconds(1))
        let waited = ensureStart.duration(to: .now)
        await release.value
        let releasedAfter = ensureStart.duration(to: try #require(releasedAt.withLock { $0 }))
        #expect(result.reason == .timeout)
        /** The stop cleared inside the call and a fresh run began. */
        #expect(result.server.phase == .starting)
        #expect(result.server.pid != nil && result.server.pid != first.pid)
        #expect(waited >= timeout, "ensure returned after \(waited), before its \(timeout) timeout")
        #expect(
            waited < releasedAfter + timeout,
            "ensure took \(waited), a full \(timeout) past the stop clearing at \(releasedAfter)")

        _ = await stopped
        /** The fresh run's survivor dies to this stop's SIGKILL; the fresh
            run's gate lets its fake `run()` return, and the wait for
            `.stopped` keeps the run's last write inside the test. */
        async let cleanup = supervisor.stop(graceSeconds: 0.05, reason: "test cleanup")
        freshRunGate.signal(.signaled(signal: Int(SIGKILL)))
        _ = await cleanup
        #expect(try await awaitPhase(supervisor, .stopped, within: .seconds(5)).phase == .stopped)
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
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
            registry: registry, spec: spec, stallBounds: bounds)
        let id = serverID(project: env.project, name: "auth-stall")

        func awaitCrashed() async throws -> ServerStatus {
            try await awaitPhase(supervisor, .crashed, within: .seconds(8))
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
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
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
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        #expect(try await awaitPhase(supervisor, .crashed).phase == .crashed)

        let spool = paths.spoolOutFile(project: env.project, server: "ignorer")
        let pid = try #require(try await printedPid("grandchild", in: spool, within: .seconds(3)))
        /** This grandchild ignores SIGTERM, so its death is itself the proof the
            SIGKILL pass ran. Polled rather than checked at one instant: the
            pass fires on the product's own grace timer after the phase turns. */
        let reaped = try await awaitExit(pid, within: .seconds(5))
        #expect(
            reaped,
            "grandchild \(pid) survived the crash escalation (pgid \(getpgid(pid)), state \(processState(of: pid)))")
        if !reaped { kill(pid, SIGKILL) }
    }

    @Test func crashRecordsExitForensics() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "exit 3"], name: "flaky")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let status = try await awaitPhase(supervisor, .crashed)
        #expect(status.phase == .crashed)
        #expect(status.lastExit?.code == 3)
        /** Forensics survive into the persisted state file. */
        let persisted = await registry.persistedState(serverID: serverID(project: env.project, name: "flaky"))
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
        let id = serverID(project: env.project, name: "web")
        let supervisor = ServerSupervisor(
            events: events, launcher: SubprocessLauncher(), paths: paths,
            projectPath: env.project, registry: registry, spec: spec)
        let started = await supervisor.start()
        let pid = try #require(started.pid)
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)

        kill(pid_t(pid), SIGTERM)
        let status = try await awaitPhase(supervisor, .stopped)
        #expect(status.phase == .stopped)
        #expect(status.lastExit?.signal == Int(SIGTERM))

        /** An external signal is not a directa decision, so it must not retire
            the intent to come back on the next boot. */
        let persisted = await registry.persistedState(serverID: id)
        #expect(persisted?.phase == .stopped)
        #expect(persisted?.resumeOnBoot == true)

        /** Queried unfiltered: the supervisor canonicalizes projectPath at
            construction (`/private/var` vs `/var` on a symlinked temp dir), so
            filtering on env.project's raw spelling would silently match
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
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        let pid = try #require(started.pid)

        kill(pid_t(pid), SIGKILL)
        let status = try await awaitPhase(supervisor, .crashed)
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
        let id = serverID(project: env.project, name: "web")
        let supervisor = ServerSupervisor(
            events: events, launcher: SubprocessLauncher(), paths: paths,
            projectPath: env.project, registry: registry, spec: spec)
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
        descendant sweep must still fire (gated on a directa-requested stop, not phase) or
        a session-escaped grandchild like this one outlives the exit. */
    @Test func externalSIGTERMStillEscalatesOrphanedDescendants() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: [fixture, "--spawn-grandchild"], name: "composite")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        let root = try #require(started.pid)
        let log = paths.structuredLogFile(project: env.project, server: "composite")
        let child = try #require(try await printedPid("grandchild", in: log, within: .seconds(2)))
        #expect(kill(child, 0) == 0)

        kill(pid_t(root), SIGTERM)
        let status = try await awaitPhase(supervisor, .stopped, within: .seconds(8))
        #expect(status.phase == .stopped)

        let reaped = try await awaitExit(child, within: .seconds(5))
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
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        #expect(started.pid != nil)
        let log = paths.structuredLogFile(project: env.project, server: "composite")
        let child = try #require(try await printedPid("grandchild", in: log, within: .seconds(2)))
        #expect(kill(child, 0) == 0)
        let crashed = try await awaitPhase(supervisor, .crashed, within: .seconds(8))
        #expect(crashed.phase == .crashed)
        /** The descendant sweep runs after the phase turns, so the outcome is
            polled rather than checked at one instant. */
        let reaped = try await awaitExit(child, within: .seconds(5))
        /** The message names the survivor's group, parent, and state: the
            facts that separate a missed snapshot from a group-kill that could
            never have reached it. */
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
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        let root = pid_t(exactly: try #require(started.pid))
        let log = paths.structuredLogFile(project: env.project, server: "web")
        let child = try #require(try await printedPid("grandchild", in: log, within: .seconds(2)))
        #expect(kill(child, 0) == 0)
        /** The precondition that makes this a session-only case: the sleep is no
            longer a parent-chain descendant of the root, so only a session sweep
            finds it. */
        if let root {
            #expect(!ProcessTree.descendants(of: root).identities.contains { $0.pid == child })
        }
        let stopped = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
        #expect(stopped.phase == .stopped)
        let reaped = try await awaitExit(child, within: .seconds(5))
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
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
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

    /** A launchd job's root is reaped by launchd the moment it exits, so by
        the time a stop runs its pid can name a stranger that happens to lead a
        process group. Stop must revalidate against the root recorded at spawn,
        never against a read of whatever wears the pid at stop time. The
        injected reader records a different start time and unique id for the
        real root, which is the view teardown gets of a recycled pid: the live
        process must come through the stop unsignaled, with the stop giving up
        honestly as `.stopping`. */
    @Test func stopNeverSignalsAGroupWhosePidNoLongerNamesTheSpawnedRoot() async throws {
        let env = try makeEnv()
        let gate = AdoptGate()
        let supervisor = ServerSupervisor(
            launcher: StuckRunLauncher(gate: gate), paths: env.paths, projectPath: env.project,
            readIdentity: { pid in
                ProcessTree.identity(of: pid).map {
                    ProcessIdentity(
                        pid: $0.pid, startMicroseconds: $0.startMicroseconds,
                        startSeconds: $0.startSeconds - 60, uniqueID: unissuedUniqueID)
                }
            },
            registry: Registry(paths: env.paths), spec: ServerSpec(command: ["/bin/true"], name: "web"),
            stopTiming: StopTiming(graceSeconds: 0.2, overtimeSeconds: 0.2))
        defer { gate.signal(.exitedStatusUnknown) }
        let root = try #require(await supervisor.start().pid.flatMap { pid_t(exactly: $0) })
        defer { kill(root, SIGKILL) }

        let stopped = await supervisor.stop(reason: "test")
        #expect(stopped.phase == .stopping)
        #expect(kill(root, 0) == 0, "stop signaled pid \(root), which no longer names the spawned root")

        kill(root, SIGKILL)
        gate.signal(.signaled(signal: Int(SIGKILL)))
        #expect(try await awaitPhase(supervisor, .stopped).phase == .stopped)
    }

    /** The grace window belongs to every process the SIGTERM reached, not only
        the root: a worker that needs a second to shut down after its root has
        already exited must get that second, not a SIGKILL the moment the root
        is gone. The root exits at once on SIGTERM; its background subshell
        takes about a second, then writes a marker the SIGKILL would have
        prevented. */
    @Test func stopGivesADescendantItsGraceAfterTheRootExits() async throws {
        let env = try makeEnv()
        let marker = URL(fileURLWithPath: env.project).appending(path: "cleaned")
        let spec = ServerSpec(
            command: [
                "/bin/sh", "-c",
                #"trap "exit 0" TERM; (trap "sleep 1; echo done > cleaned; exit 0" TERM; : > ready; while :; do sleep 0.1; done) & while :; do sleep 0.1; done"#,
            ],
            name: "slow-worker")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.project,
            registry: Registry(paths: env.paths), spec: spec)
        #expect(await supervisor.start().pid != nil)
        /** The subshell writes `ready` once its trap is installed. */
        let ready = URL(fileURLWithPath: env.project).appending(path: "ready")
        try #require(
            try await eventually(within: .seconds(5)) { FileManager.default.fileExists(atPath: ready.path) },
            "the worker never installed its trap")

        let stopped = await supervisor.stop(graceSeconds: 4, reason: "test")
        #expect(stopped.phase == .stopped)
        let written = try? String(contentsOf: marker, encoding: .utf8)
        #expect(written == "done\n", "the worker was killed before its graceful shutdown finished")
    }

    /** A worker that daemonized away from the root (its parent exited, so
        launchd adopted it) is still this server's own process when the
        startup snapshot recorded it, and its listener must read as the
        server's port rather than as a foreign holder. The healthcheck targets
        a second port the test opens only after it has killed the listener's
        parent, so the first healthy scan runs once the listener has left the
        root's parent chain, and the startup snapshot has had the whole
        starting window to record it. */
    @Test func aListenerThatLeftTheRootsParentChainIsStillTheServersPort() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let env = try makeEnv()
        let port = TestPorts.port(490)
        let healthPort = TestPorts.port(491)
        let spec = ServerSpec(
            command: [
                "/bin/sh", "-c",
                "\(ShellWord.singleQuoted(fixture)) --setsid-listener \(port) & exec /bin/sleep 30",
            ],
            healthcheck: HealthCheckSpec(intervalMs: 200, port: healthPort, type: .tcp),
            name: "daemonizer", port: port)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.project,
            registry: Registry(paths: env.paths), spec: spec)
        let root = try #require(await supervisor.start().pid.flatMap { pid_t(exactly: $0) })
        let spool = env.paths.spoolOutFile(project: env.project, server: "daemonizer")
        let worker = try #require(
            try await printedPid("setsid listener", in: spool, within: .seconds(2)),
            "the fixture never reported its setsid listener")
        defer { kill(worker, SIGKILL) }
        /** Several descendant refreshes while the listener's parent still
            parents it, then that parent goes. */
        try await Task.sleep(for: .seconds(1))
        let parent = try #require(ProcessTree.descendants(of: root).pids.first { $0 != worker })
        kill(parent, SIGKILL)
        /** The premise: the listener is no longer in the root's parent chain. */
        #expect(try await eventually(within: .seconds(2)) { !ProcessTree.descendants(of: root).pids.contains(worker) })
        #expect(await supervisor.status().phase == .starting)

        let health = try spawnReapedSessionLeader([fixture, "--listen-tcp", "\(healthPort)"])
        defer { kill(health, SIGKILL) }
        #expect(try await awaitPhase(supervisor, .running).phase == .running)
        let status = try await firstAnswer(within: .seconds(3)) {
            let current = await supervisor.status()
            return current.observedPort == nil && current.portConflict == nil ? nil : current
        }
        #expect(status?.observedPort == port)
        #expect(status?.portConflict == nil)
        _ = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
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
        (try? captureOutput(argv))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /** The same teardown guarantee with the timing made explicit. Foundation's
        `Process` puts its child in a new process group, so the crash path's
        group-directed kill cannot reach this grandchild and only a descendant
        source can. It appears 400ms after spawn, past the early snapshot and
        before a server with no healthcheck gets its first probe, so only the
        starting-window refresh (or a later source) records it. */
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
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
            registry: registry, spec: spec)
        #expect(await supervisor.start().pid != nil)

        let child = try #require(
            try await printedPid(
                "grandchild", in: paths.structuredLogFile(project: env.project, server: "late"),
                within: .seconds(3)),
            "fixture never reported a grandchild pid")
        /** The premise, asserted rather than assumed: if this ever spawned into
            the root's group, the group kill would cover it and this test would
            be proving nothing. */
        #expect(getpgid(child) == child)

        let crashed = try await awaitPhase(supervisor, .crashed, within: .seconds(8))
        #expect(crashed.phase == .crashed)

        let reaped = try await awaitExit(child, within: .seconds(5))
        if !reaped { kill(child, SIGKILL) }
        #expect(reaped, "grandchild \(child) survived the crash teardown (pgid \(getpgid(child)))")
    }

    /** The launcher publishes the pid through an async hop, and under load
        that hop can land after a short-lived root has already exited. By then
        `getsid` on the root answers ESRCH (a zombie included) and the root no
        longer parents anything, so neither the session key nor the snapshot
        can be read from the live process: the session has to come from the
        spawn contract itself. The gate holds the hop until the root is gone,
        which makes that ordering deterministic. */
    @Test func crashSweepReachesTheSessionWhenThePidArrivesAfterTheRootExited() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let env = try makeEnv()
        let gate = SpawnGate()
        let launcher = DelayedSpawnLauncher(gate: gate)
        let supervisor = ServerSupervisor(
            launcher: launcher, paths: env.paths, projectPath: env.project,
            registry: Registry(paths: env.paths),
            spec: ServerSpec(
                command: [fixture, "--spawn-grandchild", "--exit-after", "0.2", "--code", "1"],
                name: "late-pid"))

        async let started = supervisor.start()
        defer { gate.open() }
        let root = try #require(try await launcher.firstPid(within: .seconds(2)))
        let spool = env.paths.spoolOutFile(project: env.project, server: "late-pid")
        let child = try #require(
            try await printedPid("grandchild", in: spool, within: .seconds(2)),
            "fixture never reported a grandchild pid")
        defer { kill(child, SIGKILL) }
        try #require(try await eventually(within: .seconds(5)) { getsid(root) == -1 }, "root \(root) never exited")

        gate.open()
        _ = await started
        #expect(try await awaitPhase(supervisor, .crashed, within: .seconds(8)).phase == .crashed)
        let reaped = try await awaitExit(child, within: .seconds(5))
        #expect(
            reaped,
            "grandchild \(child) survived a crash whose pid arrived after the root exited (pgid \(getpgid(child)))")
    }

    /** A setsid descendant has left the root's group and session, so once the
        root exits the snapshot is its only handle. A refresh that lands after
        the root exits but before its outcome is recorded walks a parent chain
        the root no longer heads (its children reparent to launchd at exit),
        and must not erase what earlier refreshes recorded. `StuckRunLauncher`
        withholds the outcome while the starting-phase watch keeps refreshing
        over the dead root; the pause spans several watch intervals. The child
        pid comes from the root's own stdout, and the root lives until this
        test ends it, a few watch intervals after the child is known, so the
        premise never depends on winning a race against the root's exit. */
    @Test func aRefreshAfterTheRootExitsKeepsTheSetsidDescendantItRecorded() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let env = try makeEnv()
        let gate = AdoptGate()
        let port = TestPorts.port(487)
        let (readEnd, writeEnd) = try makeOutputPipe()
        defer { close(readEnd) }
        let launcher = StuckRunLauncher(
            gate: gate,
            spawnRoot: {
                try spawnReapedSessionLeader(
                    [fixture, "--setsid-listener", "\(port)"], stdoutFD: writeEnd)
            })
        let supervisor = ServerSupervisor(
            launcher: launcher, paths: env.paths, projectPath: env.project,
            registry: Registry(paths: env.paths),
            spec: ServerSpec(command: ["/bin/true"], name: "setsid"))
        defer { gate.signal(.exitedStatusUnknown) }
        let root = try #require(await supervisor.start().pid.flatMap { pid_t(exactly: $0) })
        close(writeEnd)
        defer { kill(root, SIGKILL) }
        let child = try #require(
            await readSetsidListenerPid(from: readEnd), "root \(root) never spawned its setsid listener")
        defer { kill(child, SIGKILL) }
        /** The premise: a session of its own, so the session sweep cannot
            stand in for the snapshot. */
        #expect(getsid(child) == child)
        try await Task.sleep(for: .milliseconds(600))
        kill(root, SIGKILL)
        try #require(try await eventually(within: .seconds(5)) { getsid(root) == -1 }, "root \(root) never exited")
        try await Task.sleep(for: .milliseconds(600))

        gate.signal(.exited(code: 1))
        #expect(try await awaitPhase(supervisor, .crashed, within: .seconds(8)).phase == .crashed)
        let reaped = try await awaitExit(child, within: .seconds(5))
        #expect(reaped, "setsid listener \(child) survived a crash its snapshot had recorded")
    }

    /** A setsid child spawned after the last snapshot refresh, by a root that
        exits the same instant: it left the group and the session, and the
        root's exit reparented it to launchd before any refresh could record
        it, so the snapshot, the parent chain, and the session all miss it.
        Only the kernel's parent unique id, which reparenting leaves alone,
        still ties it to this run. The root spawns it at 500ms, between the
        200ms refreshes, and `--exit-after-spawn` leaves no gap for one. */
    @Test func crashKillsASetsidChildTheRootSpawnedAsItExited() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let env = try makeEnv()
        let gate = AdoptGate()
        let (readEnd, writeEnd) = try makeOutputPipe()
        defer { close(readEnd) }
        let launcher = StuckRunLauncher(
            gate: gate,
            spawnRoot: {
                try spawnReapedSessionLeader(
                    [
                        fixture, "--setsid-listener", "\(TestPorts.port(489))", "--grandchild-after", "0.5",
                        "--exit-after-spawn", "--code", "1",
                    ],
                    stdoutFD: writeEnd)
            })
        let supervisor = ServerSupervisor(
            launcher: launcher, paths: env.paths, projectPath: env.project,
            registry: Registry(paths: env.paths),
            spec: ServerSpec(command: ["/bin/true"], name: "late-setsid"))
        defer { gate.signal(.exitedStatusUnknown) }
        let root = try #require(await supervisor.start().pid.flatMap { pid_t(exactly: $0) })
        close(writeEnd)
        let child = try #require(
            await readSetsidListenerPid(from: readEnd), "root \(root) never spawned its setsid listener")
        defer { kill(child, SIGKILL) }
        try #require(try await eventually(within: .seconds(5)) { getsid(root) == -1 }, "root \(root) never exited")
        /** The premise: a session of its own, alive after the root is gone. */
        #expect(getsid(child) == child)
        #expect(kill(child, 0) == 0)

        gate.signal(.exited(code: 1))
        #expect(try await awaitPhase(supervisor, .crashed, within: .seconds(8)).phase == .crashed)
        let reaped = try await awaitExit(child, within: .seconds(5))
        #expect(reaped, "setsid child \(child) outlived a crash (ppid \(parentPid(of: child)))")
    }

    @Test func crashCapturesErrorLineTally() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(
            command: ["/bin/sh", "-c", "echo boom >&2; echo bang >&2; exit 1"], name: "noisy")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let status = try await awaitPhase(supervisor, .crashed)
        #expect(status.phase == .crashed)
        /** Two stderr lines this run: directa's own count, not the lines. */
        #expect(status.errorSummary?.count == 2)
        #expect(status.errorSummary.map { $0.lastAt >= $0.firstAt } == true)
        /** And it survives into the state file for a post-restart read. */
        let persisted = await registry.persistedState(
            serverID: serverID(project: env.project, name: "noisy"))
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
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let crashed = try await awaitPhase(supervisor, .crashed)
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
        let id = serverID(project: env.project, name: "web")
        /** A prior daemon left a crashed row with a tally; a fresh supervisor for
            the same server surfaces it without re-running anything. */
        let seed = Registry(paths: paths)
        try await seed.updateState(serverID: id, writer: .router) { entry in
            entry.errorSummary = ErrorSummary(
                count: 4,
                firstAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastAt: Date(timeIntervalSince1970: 1_700_000_009))
            entry.phase = .crashed
        }
        let registry = Registry(paths: paths)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
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
        let id = serverID(project: env.project, name: "web")
        let logURL = paths.structuredLogFile(project: env.project, server: "web")
        let seedLog = LogStore(currentURL: logURL)
        await seedLog.append(stream: .out, text: "rehydrate-marker-original")
        let seed = Registry(paths: paths)
        try await seed.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .crashed
        }
        let registry = Registry(paths: paths)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
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
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
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
            launcher: testLaunchdJobLauncher(), paths: paths,
            projectPath: env.project,
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
            serverID: serverID(project: env.project, name: "web"))
        #expect(persisted?.startedAt == priorStartedAt)
        _ = await supervisor.stop(graceSeconds: 2, reason: "test cleanup")
    }

    /** A `startedAt` the caller never had (pre-feature state, or a persisted
        row with no timestamp) still produces a usable run: adoption falls back
        to now rather than leaving the clock unset. "Now" is bracketed by the
        wall clock read just before the adopt call and just after the status
        read, so the check holds however long a loaded machine takes between
        them. */
    @Test func adoptFallsBackToNowWhenStartedAtIsMissing() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web")
        let supervisor = ServerSupervisor(
            launcher: testLaunchdJobLauncher(), paths: paths,
            projectPath: env.project,
            registry: registry, spec: spec)
        let survivor = try spawnSurvivor()
        defer { kill(survivor, SIGKILL) }
        let beforeAdopt = Date()
        #expect(
            await supervisor.adopt(
                pid: survivor, label: "dev.quantizor.directa.job.uptime-fallback", boundPort: nil,
                startedAt: nil))
        let status = await supervisor.status()
        let afterStatus = Date()
        let startedAt = try #require(
            await registry.persistedState(serverID: serverID(project: env.project, name: "web"))?.startedAt)
        #expect((beforeAdopt...afterStatus).contains(startedAt))
        let uptime = try #require(status.uptimeSec)
        #expect((0...Int(afterStatus.timeIntervalSince(beforeAdopt))).contains(uptime))
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
            launcher: FakeAdoptLauncher(gate: gate), paths: paths, projectPath: env.project,
            registry: registry, spec: spec)
        defer { gate.signal(.exitedStatusUnknown) }
        let survivor = try spawnSurvivor()
        defer { kill(survivor, SIGKILL) }
        #expect(
            await supervisor.adopt(
                pid: survivor, label: "dev.quantizor.directa.job.exit-test", boundPort: nil,
                startedAt: nil))
        let adopted = await supervisor.status()
        #expect(adopted.phase == .starting)
        #expect(adopted.pid == Int(survivor))
        /** The exit-watch task's first `await` races `adopt()` returning. */
        await gate.awaitFirstCall()
        #expect(await gate.callCount == 1)
        /** The real process is untouched; only the exit-watch fake fires. */
        #expect(kill(survivor, 0) == 0)
        /** SIGKILL rather than SIGTERM: this test is about the exit-watch wiring
            reaching recordOutcome at all, not about signal classification (see
            externalSIGTERMLandsStoppedWithTheSignalNamedAsExternal for that), so
            it uses the one signal that stays `crashed` regardless of who sent it. */
        gate.signal(.signaled(signal: Int(SIGKILL)))
        let crashed = try await awaitPhase(supervisor, .crashed)
        #expect(crashed.phase == .crashed)
        #expect(crashed.lastExit?.signal == Int(SIGKILL))
        #expect(crashed.pid == nil)
        let persisted = await registry.persistedState(
            serverID: serverID(project: env.project, name: "web"))
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
            launcher: launcher, paths: paths, projectPath: env.project,
            registry: registry, spec: spec)
        let survivor = try spawnSurvivor()
        defer { kill(survivor, SIGKILL) }
        let spool = paths.spoolOutFile(project: env.project, server: "web")
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
                serverID: serverID(project: env.project, name: "web")) == nil)

        let handle = try FileHandle(forWritingTo: spool)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("written after a refused adopt\n".utf8))
        try handle.close()
        /** A running tailer polls the spool well inside this window. */
        let ingested = try await eventually(within: .milliseconds(500)) {
            await !supervisor.logQuery(LogQueryOptions(streams: [.out, .sys])).lines.isEmpty
        }
        let lines = await supervisor.logQuery(LogQueryOptions(streams: [.out, .sys])).lines
        #expect(!ingested, "log after a refused adopt: \(lines.map(\.text))")
    }

    /** A stop that lands while `adopt` is still recording the run (its pid is
        already set, its tailers and state write not yet done) gets the same
        SIGTERM grace a stop of a finished adoption does. The survivor takes
        half a second to shut down on SIGTERM and writes a marker when it
        does; a stop that skipped the grace would SIGKILL it first. The stop is
        queued from inside `prepareAdopt`, so it reaches the actor at one of
        adoption's own awaits. */
    @Test func stopDuringAdoptionKeepsTheGrace() async throws {
        let env = try makeEnv()
        let gate = AdoptGate()
        let launcher = StopOnPrepareLauncher(gate: gate)
        let supervisor = ServerSupervisor(
            launcher: launcher, paths: env.paths, projectPath: env.project,
            registry: Registry(paths: env.paths), spec: ServerSpec(command: ["/bin/true"], name: "web"))
        defer { gate.signal(.exitedStatusUnknown) }
        let stopTask = OSAllocatedUnfairLock<Task<ServerStatus, Never>?>(initialState: nil)
        launcher.onPrepare {
            stopTask.withLock { $0 = Task { await supervisor.stop(graceSeconds: 3, reason: "test") } }
        }
        let marker = URL(fileURLWithPath: env.project).appending(path: "cleaned")
        let ready = URL(fileURLWithPath: env.project).appending(path: "ready")
        let survivor = try spawnReapedSessionLeader([
            "/bin/sh", "-c",
            "trap 'sleep 0.5; echo done > \"\(marker.path)\"; exit 0' TERM; : > \"\(ready.path)\"; while :; do sleep 0.1; done",
        ])
        defer { kill(survivor, SIGKILL) }
        /** The survivor writes `ready` once its trap is installed. */
        try #require(
            try await eventually(within: .seconds(5)) { FileManager.default.fileExists(atPath: ready.path) },
            "the survivor never installed its trap")

        #expect(
            await supervisor.adopt(
                pid: survivor, label: "dev.quantizor.directa.job.adopt-stop", boundPort: nil,
                startedAt: nil))
        #expect(try await awaitExit(survivor, within: .seconds(5)))
        gate.signal(.signaled(signal: Int(SIGTERM)))
        let stop = try #require(stopTask.withLock { $0 })
        #expect(await stop.value.phase == .stopped)
        let written = try? String(contentsOf: marker, encoding: .utf8)
        #expect(written == "done\n", "the adopted run was killed before its graceful shutdown finished")
    }

    /** An adopted run whose exit watch reports at once is recorded only after
        its adoption finished recording it: the crash lands last, so neither
        the phase nor the state row is left saying `.starting` for a run that
        is gone. Whether the outcome would otherwise overtake adoption depends
        on how long adoption's own awaits take, so this passes against an
        unordered outcome whenever they happen to be quick. */
    @Test func anAdoptedRunThatExitsAtOnceIsRecordedAfterItsAdoption() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let supervisor = ServerSupervisor(
            launcher: ExitsAtOnceAdoptLauncher(), paths: env.paths, projectPath: env.project,
            registry: registry, spec: ServerSpec(command: ["/bin/true"], name: "web"))
        let survivor = try spawnSurvivor()
        defer { kill(survivor, SIGKILL) }

        #expect(
            await supervisor.adopt(
                pid: survivor, label: "dev.quantizor.directa.job.instant", boundPort: nil,
                startedAt: nil))
        let crashed = try await awaitPhase(supervisor, .crashed)
        #expect(crashed.phase == .crashed)
        #expect(crashed.pid == nil)
        let persisted = await registry.persistedState(
            serverID: serverID(project: env.project, name: "web"))
        #expect(persisted?.phase == .crashed)
        #expect(persisted?.pid == nil)
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
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
            registry: registry, spec: spec)
        let started = await priorDaemon.start()
        let root = try #require(started.pid.flatMap { pid_t(exactly: $0) })
        let child = try #require(
            try await printedPid(
                "grandchild", in: paths.structuredLogFile(project: env.project, server: "web"),
                within: .seconds(2)))
        #expect(kill(child, 0) == 0)
        let supervisor = ServerSupervisor(
            launcher: testLaunchdJobLauncher(), paths: paths,
            projectPath: env.project,
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
        /** The root is the abandoned supervisor's own child, so it lingers as
            a zombie, still answering `kill(root, 0)`, until that supervisor's
            run task reaps it, which a loaded machine can delay past the stop. */
        #expect(try await awaitExit(root, within: .seconds(5)))
        /** The abandoned supervisor still awaits the root it spawned, so the
            stop above ends that run for it too, and its recordOutcome then
            drains its tailers and writes its log and state row into this
            test's tree. It sets its phase only after those writes, so waiting
            for the phase keeps them from landing after the tree is removed. */
        let priorEnded = try await awaitPhase(priorDaemon, .stopped, within: .seconds(8))
        #expect(priorEnded.phase == .stopped)
        let reaped = try await awaitExit(child, within: .seconds(5))
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
            launcher: testLaunchdJobLauncher(), paths: paths,
            projectPath: env.project,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let status = try await awaitPhase(supervisor, .crashed)
        #expect(status.phase == .crashed)
        switch (status.lastExit?.code, status.lastExit?.signal) {
        case (7, nil), (nil, nil): break
        default: Issue.record("expected exit 7 or an unknown exit, got \(String(describing: status.lastExit))")
        }
        let spool = try String(
            contentsOf: paths.structuredLogFile(project: env.project, server: "web"),
            encoding: .utf8)
        #expect(spool.contains("boom"))
    }

    /** A command that exits before the launcher can watch it was never
        supervised, so it must not become boot intent: otherwise every later
        daemon launch starts it again. Its output still reaches the log, and
        the phase still reads crashed so `why` has something to explain. */
    @Test(arguments: ExitedBeforeWatchLauncher.ReportedPid.allCases)
    func exitBeforeWatchDrainsOutputWithoutRecordingBootIntent(reported: ExitedBeforeWatchLauncher.ReportedPid)
        async throws
    {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let supervisor = ServerSupervisor(
            launcher: ExitedBeforeWatchLauncher(reported: reported, stderrText: "boom before watch\n"),
            paths: paths,
            projectPath: env.project, registry: registry,
            spec: ServerSpec(command: ["/bin/sh", "-c", "exit 1"], name: "web"))
        _ = await supervisor.start()
        let status = try await awaitPhase(supervisor, .crashed)
        #expect(status.phase == .crashed)
        #expect(status.pid == nil)
        #expect(status.lastExit?.code == nil)
        #expect(status.lastExit?.signal == nil)
        let persisted = await registry.persistedState(
            serverID: serverID(project: env.project, name: "web"))
        #expect(persisted?.phase == .crashed)
        #expect(persisted?.resumeOnBoot == nil)
        let errLines = await supervisor.logQuery(LogQueryOptions(streams: [.err])).lines
        #expect(errLines.map(\.text) == ["boom before watch"])
    }

    /** Exiting before the watch writes no intent of its own, so it keeps
        whatever an earlier supervised run left: a server already set to
        restore at launch stays set. */
    @Test func exitBeforeWatchKeepsAnEarlierRunsBootIntent() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let id = serverID(project: env.project, name: "web")
        try await registry.updateState(serverID: id, writer: .router) { entry in
            entry.phase = .stopped
            entry.resumeOnBoot = true
        }
        let supervisor = ServerSupervisor(
            launcher: ExitedBeforeWatchLauncher(reported: .neverShown, stderrText: "boom before watch\n"),
            paths: paths,
            projectPath: env.project, registry: registry,
            spec: ServerSpec(command: ["/bin/sh", "-c", "exit 1"], name: "web"))
        _ = await supervisor.start()
        #expect(try await awaitPhase(supervisor, .crashed).phase == .crashed)
        let persisted = await registry.persistedState(serverID: id)
        #expect(persisted?.phase == .crashed)
        #expect(persisted?.lastExit != nil)
        #expect(persisted?.resumeOnBoot == true)
    }

    /** The other side of the same line: a run whose exit watch was armed was
        supervised, so an exit, even an instant one that still reported its
        code, keeps the boot intent `recordSpawn` wrote. */
    @Test func armedInstantExitKeepsBootIntent() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let gate = AdoptGate()
        gate.signal(.exited(code: 1))
        let supervisor = ServerSupervisor(
            launcher: StuckRunLauncher(gate: gate), paths: paths, projectPath: env.project,
            registry: registry, spec: ServerSpec(command: ["/bin/true"], name: "web"))
        let started = await supervisor.start()
        defer { if let pid = started.pid { kill(pid_t(pid), SIGKILL) } }
        let status = try await awaitPhase(supervisor, .crashed)
        #expect(status.lastExit?.code == 1)
        let persisted = await registry.persistedState(
            serverID: serverID(project: env.project, name: "web"))
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
        let port = TestPorts.port(482)
        let supervisor = ServerSupervisor(
            launcher: StuckRunLauncher(gate: gate), paths: paths, prober: AlwaysHealthyProber(),
            projectPath: env.project, registry: registry,
            spec: ServerSpec(
                command: ["/bin/true"], healthcheck: HealthCheckSpec(port: port, type: .tcp),
                name: "web", port: port))
        defer { gate.signal(.exitedStatusUnknown) }
        let started = await supervisor.start()
        defer { if let pid = started.pid { kill(pid_t(pid), SIGKILL) } }
        #expect(try await awaitPhase(supervisor, .running).phase == .running)
        gate.signal(.exited(code: 1))
        #expect(try await awaitPhase(supervisor, .crashed).phase == .crashed)
        let persisted = await registry.persistedState(
            serverID: serverID(project: env.project, name: "web"))
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
        let id = serverID(project: env.project, name: "stuck")
        let supervisor = ServerSupervisor(
            launcher: StuckRunLauncher(gate: gate), paths: paths, projectPath: env.project,
            registry: registry, spec: ServerSpec(command: ["/bin/true"], name: "stuck"),
            stopTiming: StopTiming(graceSeconds: 0.05, overtimeSeconds: 0.1))
        defer { gate.signal(.exitedStatusUnknown) }
        #expect(await supervisor.start().pid != nil)
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)

        #expect(await supervisor.stopForRemoval(reason: "unregistered") == .gaveUp)
        try await registry.updateState(serverID: id, writer: .router) { $0 = PersistedServerState(phase: .stopped) }

        gate.signal(.signaled(signal: Int(SIGKILL)))
        let settled = try await awaitPhase(supervisor, .stopped)
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
        let id = serverID(project: env.project, name: "web")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.project,
            registry: registry, spec: ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web"))
        _ = await supervisor.start()
        #expect(await supervisor.stopForRemoval(reason: "unregistered") == .stopped)
        let persisted = await registry.persistedState(serverID: id)
        #expect(persisted?.phase == .stopped)
        #expect(persisted?.resumeOnBoot == nil)
    }

    /** A removal that joins a restart's non-deliberate stop returns `.stopped`
        (the stop finished), and the restart then calls `ensure` on the same
        reference. The router has already dropped this supervisor, so a spawn
        here would run with nothing supervising it: `ensure` and `start` must
        read as stopped and spawn nothing. */
    @Test func removedSupervisorNeverSpawnsAgainAfterJoiningARestartStop() async throws {
        let env = try makeEnv()
        let gate = AdoptGate()
        let supervisor = ServerSupervisor(
            launcher: StuckRunLauncher(gate: gate), paths: env.paths, projectPath: env.project,
            registry: Registry(paths: env.paths), spec: ServerSpec(command: ["/bin/true"], name: "web"),
            stopTiming: StopTiming(graceSeconds: 0.05, overtimeSeconds: 5))
        #expect(await supervisor.start().pid != nil)
        #expect(await gate.callCount == 1)

        async let restartStop = supervisor.stop(deliberate: false, reason: "requested by restart")
        defer { gate.signal(.exitedStatusUnknown) }
        #expect(try await awaitPhase(supervisor, .stopping).phase == .stopping)
        async let removal = supervisor.stopForRemoval(reason: "unregistered")
        defer { gate.signal(.exitedStatusUnknown) }
        /** Lets the removal join the stop in flight; the assertions below hold
            for either order. */
        try await Task.sleep(for: .milliseconds(100))
        gate.signal(.signaled(signal: Int(SIGKILL)))
        _ = await restartStop
        #expect(await removal == .stopped)

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
            launcher: FakeAdoptLauncher(gate: gate), paths: env.paths, projectPath: env.project,
            registry: Registry(paths: env.paths), spec: ServerSpec(command: ["/bin/true"], name: "web"))
        defer { gate.signal(.exitedStatusUnknown) }
        #expect(await supervisor.stopForRemoval(reason: "unregistered") == .alreadyTerminal)
        let survivor = try spawnSurvivor()
        defer { kill(survivor, SIGKILL) }
        let adopted = await supervisor.adopt(
            pid: survivor, label: "dev.quantizor.directa.job.removed", boundPort: nil, startedAt: nil)
        #expect(adopted == false)
        #expect(await gate.callCount == 0)
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
            launcher: launcher, paths: env.paths, projectPath: env.project,
            registry: Registry(paths: env.paths),
            spec: ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web"))
        defer { for pid in launcher.pids { kill(pid, SIGKILL) } }

        async let started = supervisor.start()
        defer { gate.open() }
        let child = try #require(try await launcher.firstPid(within: .seconds(2)))
        let pending = await supervisor.status()
        #expect(pending.phase == .starting)
        #expect(pending.pid == nil)

        let opener = Task {
            try? await Task.sleep(for: .milliseconds(200))
            gate.open()
        }
        let stopped = await supervisor.stop(graceSeconds: 2, reason: "test")
        _ = await started
        await opener.value
        #expect(stopped.phase == .stopped)
        let settled = await supervisor.status()
        #expect(settled.phase == .stopped)
        #expect(settled.pid == nil)
        #expect(
            try await awaitExit(child, within: .seconds(1)), "pid \(child) kept running after a stop that reported stopped")
    }

    /** A removal whose stop gives up while the launcher has not reported a
        pid yet still abandons state writes, and the run that appears later
        is stopped the moment its pid arrives rather than recorded: nothing
        supervises it any more, so it must neither keep running nor write a
        restore-at-launch intent. */
    @Test func removalThatGivesUpBeforeThePidIsKnownStopsTheRunWhenItAppears() async throws {
        let env = try makeEnv()
        let gate = SpawnGate()
        let launcher = DelayedSpawnLauncher(gate: gate)
        let registry = Registry(paths: env.paths)
        let id = serverID(project: env.project, name: "web")
        let supervisor = ServerSupervisor(
            launcher: launcher, paths: env.paths, projectPath: env.project,
            registry: registry, spec: ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web"),
            stopTiming: StopTiming(graceSeconds: 0.05, overtimeSeconds: 0.1))
        defer { for pid in launcher.pids { kill(pid, SIGKILL) } }

        async let started = supervisor.start()
        defer { gate.open() }
        let child = try #require(try await launcher.firstPid(within: .seconds(2)))
        #expect(await supervisor.stopForRemoval(reason: "unregistered") == .gaveUp)
        #expect(await supervisor.status().phase == .starting)

        gate.open()
        _ = await started
        #expect(
            try await awaitExit(child, within: .seconds(2)), "pid \(child) kept running after its supervisor was removed")
        let settled = try await awaitPhase(supervisor, .stopped)
        #expect(settled.phase == .stopped)
        #expect(settled.pid == nil)
        #expect(await registry.persistedState(serverID: id) == nil)
    }
}

/** Adopts through `gate` like `FakeAdoptLauncher`, and runs a test's hook from
    inside `prepareAdopt`, the one moment a test can act while `adopt` is
    certainly still in progress. Never spawns. */
private final class StopOnPrepareLauncher: ProcessLauncher {
    let gate: AdoptGate
    private let hook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    init(gate: AdoptGate) {
        self.gate = gate
    }

    func onPrepare(_ action: @escaping @Sendable () -> Void) {
        hook.withLock { $0 = action }
    }

    func run(
        argv: [String], capture: SpawnCapture, cwd: String?, environment: [String: String],
        onExitedBeforeWatch: @escaping @Sendable (pid_t?) async -> Void,
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome {
        .spawnFailed(SpawnError(message: "StopOnPrepareLauncher never spawns"))
    }

    func prepareAdopt(pid: pid_t) -> Bool {
        hook.withLock { $0 }?()
        return true
    }

    func adopt(pid: pid_t, label: String) async -> ProcessOutcome {
        await gate.outcome()
    }
}

/** An adopted child whose exit watch fires the instant it is awaited, without
    a hop through another actor, so its outcome reaches the supervisor while
    `adopt` is still at its first await. Never spawns. */
private struct ExitsAtOnceAdoptLauncher: ProcessLauncher {
    func run(
        argv: [String], capture: SpawnCapture, cwd: String?, environment: [String: String],
        onExitedBeforeWatch: @escaping @Sendable (pid_t?) async -> Void,
        onSpawn: @escaping @Sendable (pid_t) async -> Void
    ) async -> ProcessOutcome {
        .spawnFailed(SpawnError(message: "ExitsAtOnceAdoptLauncher never spawns"))
    }

    func prepareAdopt(pid: pid_t) -> Bool { true }

    func adopt(pid: pid_t, label: String) async -> ProcessOutcome {
        .signaled(signal: Int(SIGKILL))
    }
}

private struct AlwaysHealthyProber: HealthProber {
    func probe(_ check: EffectiveHealthcheck) async -> Bool { true }
}

private struct NeverHealthyProber: HealthProber {
    func probe(_ check: EffectiveHealthcheck) async -> Bool { false }
}

@Suite(.temporaryTree) struct RegistryTests {
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
        let id = serverID(project: env.project, name: "web")
        let retired = UUID()
        try await registry.updateState(serverID: id, writer: .supervisor(retired)) { entry in
            entry.phase = .running
            entry.pid = 4242
            entry.resumeOnBoot = true
        }
        try await registry.retireState(
            serverID: id, final: PersistedServerState(phase: .stopped), writer: retired)
        try await registry.updateState(serverID: id, writer: .supervisor(retired)) { entry in
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
        try await registry.updateState(serverID: id, writer: .supervisor(retired)) { $0.resumeOnBoot = true }
        #expect(await registry.persistedState(serverID: id) == nil)
    }

    /** Retirement is scoped to the writer: a later supervisor for the same id
        and the router's own writes persist normally, including
        the insert of a row `removeState` deleted. */
    @Test func otherWritersStillPersistForARetiredID() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let id = serverID(project: env.project, name: "web")
        try await registry.retireState(
            serverID: id, final: PersistedServerState(phase: .stopped), writer: UUID())
        try await registry.removeState(serverID: id)

        let successor = UUID()
        try await registry.updateState(serverID: id, writer: .supervisor(successor)) { entry in
            entry.phase = .starting
            entry.pid = 4244
            entry.resumeOnBoot = true
        }
        let inserted = try #require(await registry.persistedState(serverID: id))
        #expect(inserted.pid == 4244)
        #expect(inserted.resumeOnBoot == true)

        try await registry.updateState(serverID: id, writer: .router) { $0.boundPort = 4000 }
        #expect(await registry.persistedState(serverID: id)?.boundPort == 4000)
        #expect(await Registry(paths: env.paths).persistedState(serverID: id)?.pid == 4244)
    }

    /** Retirements are keyed on the normalized id, so a `/var` vs
        `/private/var` spelling of the same project cannot slip a retired
        writer's write past it. */
    @Test func retiredWriterMatchesEitherSpellingOfTheProject() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        let canonical = canonicalProjectPath(env.project)
        let lexical = canonical.hasPrefix("/private/") ? String(canonical.dropFirst("/private".count)) : canonical
        let retired = UUID()
        try await registry.retireState(
            serverID: serverID(project: lexical, name: "web"), final: PersistedServerState(phase: .stopped),
            writer: retired)
        try await registry.updateState(
            serverID: serverID(project: canonical, name: "web"), writer: .supervisor(retired)
        ) {
            $0.resumeOnBoot = true
        }
        #expect(
            await registry.persistedState(serverID: serverID(project: canonical, name: "web"))?
                .resumeOnBoot == nil)
    }
}

