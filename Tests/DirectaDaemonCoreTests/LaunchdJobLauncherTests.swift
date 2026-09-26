import Darwin
import DirectaKit
import Foundation
import Testing
import os

@testable import DirectaDaemonCore

/** launchctl bootstrap is a machine-wide gui-domain mutation. Serialized so two
    cases cannot share a label or race bootout. */
@Suite(.serialized)
struct LaunchdJobLauncherTests {
    @Test func launchdJobGetsItsOwnJetsamCoalition() async throws {
        let parent = try #require(CoalitionIDs.read(of: getpid()))
        let (outFD, outURL) = try openSpool()
        let (errFD, errURL) = try openSpool()
        defer {
            close(outFD)
            close(errFD)
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let spawned = OSAllocatedUnfairLock(initialState: pid_t(0))
        let outcome = await LaunchdJobLauncher(labelPrefix: testLaunchdJobLabelPrefix).run(
            argv: ["/bin/sleep", "8"],
            capture: SpawnCapture(
                stderrFD: errFD, stderrPath: errURL.path, stdoutFD: outFD, stdoutPath: outURL.path),
            cwd: nil,
            environment: [:],
            onExitedBeforeWatch: { pid in
                Issue.record("an 8 s sleep reported as exited before its watch (pid \(String(describing: pid)))")
            },
            onSpawn: { pid in
                spawned.withLock { $0 = pid }
                let ids = CoalitionIDs.read(of: pid)
                #expect(ids?.jetsam != parent.jetsam)
                #expect(ids?.resource != parent.resource)
                #expect(getpgid(pid) == pid)
                kill(pid, SIGTERM)
            }
        )
        try #require(spawned.withLock { $0 } > 0)
        /** The launchd job is not a child of this test process (launchd forked
            it), so this pins the actual `NOTE_EXITSTATUS` gate: the kqueue man
            page calls it "valid only on child processes", but the real check is
            whether this process may signal the target (same user, or root), and
            a launchd job run as the same user passes that check despite never
            being a child. Without `NOTE_EXITSTATUS`, `ExitWatcher.decode` would
            read a `data` of 0 on every exit and report `.exited(code: 0)`,
            which this exact signal (15, not 0) would not catch if the decode
            were wrong. */
        switch outcome {
        case .signaled(let signal):
            #expect(signal == Int(SIGTERM))
        case .exited, .exitedStatusUnknown, .spawnFailed:
            Issue.record("expected .signaled(signal: \(SIGTERM)), got \(outcome)")
        }
    }

    /** The other half of the same permission case: a launchd job (not a child
        of this process) that exits on its own with a nonzero code. Without
        `NOTE_EXITSTATUS`, this would decode as `.exited(code: 0)` regardless of
        the real status, masking every real failure a launchd-run dev server
        reports. */
    @Test func launchdJobReportsItsRealExitCode() async throws {
        let (outFD, outURL) = try openSpool()
        let (errFD, errURL) = try openSpool()
        defer {
            close(outFD)
            close(errFD)
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let outcome = await LaunchdJobLauncher(labelPrefix: testLaunchdJobLabelPrefix).run(
            argv: ["/bin/sh", "-c", "sleep 0.3; exit 3"],
            capture: SpawnCapture(
                stderrFD: errFD, stderrPath: errURL.path, stdoutFD: outFD, stdoutPath: outURL.path),
            cwd: nil,
            environment: [:],
            onExitedBeforeWatch: { _ in },
            onSpawn: { _ in }
        )
        switch outcome {
        case .exited(let code):
            #expect(code == 3)
        case .exitedStatusUnknown, .signaled, .spawnFailed:
            Issue.record("expected .exited(code: 3), got \(outcome)")
        }
    }

    /** A command that exits before `run` can confirm the job's pid has
        become a session leader used to lose its real exit to a manufactured
        `spawnFailed` ("never became a session leader"), since the session-
        leader poll kept retrying `getpgid` for its full budget instead of
        noticing the pid was already gone. It now notices within one poll
        (`kill(pid, 0)` answering ESRCH) and arms the exit watch at that point
        instead, so `spawnFailed` never happens here. `exit 7` is fast enough
        that this daemon's own two `/bin/launchctl` round trips (bootstrap,
        then the poll that confirms the pid) measure single-digit
        milliseconds each and land on either side of the race against launchd
        reaping the job, measured directly (repeated runs on one machine hit
        both `.leader` and `.died` roughly evenly): when the process is gone
        before the watch is armed, the code 7 comes from launchd's own
        record of the still-bootstrapped job; when this daemon wins the race,
        the armed watch reports it, unless the kernel withholds the status,
        which is the one case `.exitedStatusUnknown` stays honest.
        A slower failure (a command doing real work before a nonzero exit,
        `sleep 0.3; exit 3` above) always recovers the real code, since the
        process is reliably still alive when this daemon gets to register
        interest. */
    @Test func launchdJobReportsAnInstantExitAsExitedOrStatusUnknownNeverSpawnFailed() async throws {
        let (outFD, outURL) = try openSpool()
        let (errFD, errURL) = try openSpool()
        defer {
            close(outFD)
            close(errFD)
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let callbacks = OSAllocatedUnfairLock(initialState: [String]())
        let outcome = await LaunchdJobLauncher(labelPrefix: testLaunchdJobLabelPrefix).run(
            argv: ["/bin/sh", "-c", "exit 7"],
            capture: SpawnCapture(
                stderrFD: errFD, stderrPath: errURL.path, stdoutFD: outFD, stdoutPath: outURL.path),
            cwd: nil,
            environment: [:],
            onExitedBeforeWatch: { _ in callbacks.withLock { $0.append("exitedBeforeWatch") } },
            onSpawn: { _ in callbacks.withLock { $0.append("spawn") } }
        )
        /** Exactly one callback on every path: the armed watch reports a
            supervised spawn, and each exit this daemon saw only after the
            fact (the pid already gone, or never shown by launchd, whose own
            last exit code then carries the 7) reports the narrow one. */
        let fired = callbacks.withLock { $0 }
        #expect(fired.count == 1, "callbacks fired: \(fired)")
        switch outcome {
        case .exited(let code):
            #expect(code == 7)
        case .exitedStatusUnknown:
            #expect(fired != ["exitedBeforeWatch"], "an exit seen only after the fact lost launchd's recorded 7")
        case .signaled, .spawnFailed:
            Issue.record("expected .exited(code: 7) or .exitedStatusUnknown, got \(outcome)")
        }
    }

    /** A command that cannot be run (a typo'd path) reports why on its own
        stderr, which is what `logs` and `why` read, and exits 127 rather than
        looking like a clean exit 0. An exit this daemon saw only after the
        fact (`onExitedBeforeWatch`) still holds launchd's own record of it, so
        that path always reports the 127. Through an armed watch the kernel
        may withhold the status, so status-unknown is honest there; exit 0 or
        a spawn failure never is. */
    @Test func aCommandThatCannotRunSaysSoAndExits127() async throws {
        let (outFD, outURL) = try openSpool()
        let (errFD, errURL) = try openSpool()
        defer {
            close(outFD)
            close(errFD)
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let missing = "/nonexistent/directa-typo-\(UUID().uuidString)"
        let exitedBeforeWatch = OSAllocatedUnfairLock(initialState: false)
        let outcome = await LaunchdJobLauncher(labelPrefix: testLaunchdJobLabelPrefix).run(
            argv: [missing, "--port", "3000"],
            capture: SpawnCapture(
                stderrFD: errFD, stderrPath: errURL.path, stdoutFD: outFD, stdoutPath: outURL.path),
            cwd: nil,
            environment: [:],
            onExitedBeforeWatch: { _ in exitedBeforeWatch.withLock { $0 = true } },
            onSpawn: { _ in }
        )
        let stderr = try String(contentsOf: errURL, encoding: .utf8)
        #expect(stderr == "directa: cannot run \(missing): No such file or directory\n")
        switch outcome {
        case .exited(let code):
            #expect(code == 127)
        case .exitedStatusUnknown:
            #expect(
                !exitedBeforeWatch.withLock { $0 },
                "an exit seen only after the fact lost launchd's recorded 127")
        case .signaled, .spawnFailed:
            Issue.record("expected .exited(code: 127) or .exitedStatusUnknown, got \(outcome)")
        }
    }

    /** The wrapper script itself, run directly: a missing command and one that
        is not executable each name the command and the reason on stderr and
        exit 127; a real command runs with its own arguments and status. */
    @Test(arguments: [
        (["/nonexistent/directa-typo", "arg"], "", "directa: cannot run /nonexistent/directa-typo: No such file or directory\n", Int32(127)),
        (["/etc/hosts"], "", "directa: cannot run /etc/hosts: Permission denied\n", Int32(127)),
        (["/bin/echo", "hi"], "hi\n", "", Int32(0)),
        (["/bin/sh", "-c", "exit 3"], "", "", Int32(3)),
    ])
    func sessionWrapperReportsAFailedExec(
        argv: [String], stdout: String, stderr: String, status: Int32
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", LaunchdJobLauncher.sessionWrapperScript, "--"] + argv
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let complained = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(printed == stdout)
        #expect(complained == stderr)
        #expect(process.terminationStatus == status)
    }

    /** launchd's own record is what remains of a job reaped before its pid was
        ever seen: a terminating signal wins, then the exit code, else unknown. */
    @Test func unseenExitOutcomeReadsSignalThenCodeThenUnknown() {
        let signaled = LaunchdJobLauncher.unseenExitOutcome(
            LaunchdJobs.AgentStatus(lastTerminatingSignal: 9, runs: 1))
        let exited = LaunchdJobLauncher.unseenExitOutcome(
            LaunchdJobs.AgentStatus(lastExitCode: 64, runs: 1))
        let unknown = LaunchdJobLauncher.unseenExitOutcome(LaunchdJobs.AgentStatus(runs: 1))
        #expect("\(signaled)" == "signaled(signal: 9)")
        #expect("\(exited)" == "exited(code: 64)")
        #expect("\(unknown)" == "exitedStatusUnknown")
    }

    /** A job whose process died before its watch was armed is still
        bootstrapped, so its exit is read from `launchctl print`: reads that
        fail, or that still show a pid or no exit record, are polled past, and
        the first record of a job not running decides the outcome. */
    @Test(arguments: [
        ([nil, LaunchdJobs.AgentStatus(pid: 4242, runs: 1), LaunchdJobs.AgentStatus(runs: 1),
          LaunchdJobs.AgentStatus(lastExitCode: 127, runs: 1)], "exited(code: 127)", 4),
        ([LaunchdJobs.AgentStatus(lastTerminatingSignal: 9, runs: 1)], "signaled(signal: 9)", 1),
        ([LaunchdJobs.AgentStatus(lastExitCode: 0, runs: 1)], "exited(code: 0)", 1),
        ([LaunchdJobs.AgentStatus(lastExitCode: 3, pid: 4242, runs: 1)], "exitedStatusUnknown", 5),
        ([nil], "exitedStatusUnknown", 5),
    ] as [([LaunchdJobs.AgentStatus?], String, Int)])
    func exitRecordPollsUntilLaunchdShowsTheExit(
        reads: [LaunchdJobs.AgentStatus?], expected: String, readCount: Int
    ) async {
        let made = OSAllocatedUnfairLock(initialState: 0)
        let outcome = await LaunchdJobLauncher.exitRecord(attempts: 5, interval: .zero) {
            let index = made.withLock { count in
                defer { count += 1 }
                return count
            }
            return reads[min(index, reads.count - 1)]
        }
        #expect("\(outcome)" == expected)
        #expect(made.withLock { $0 } == readCount)
    }

    /** An armed watch whose exit status the kernel withheld (the NOTE_EXIT-only
        fallback) takes launchd's own record of the still-bootstrapped job;
        any outcome the watch did report stands without a launchd read. */
    @Test(arguments: [
        ("exitedStatusUnknown", [LaunchdJobs.AgentStatus(lastExitCode: 3, runs: 1)], "exited(code: 3)", 1),
        ("exitedStatusUnknown", [LaunchdJobs.AgentStatus(lastTerminatingSignal: 15, runs: 1)], "signaled(signal: 15)", 1),
        ("exitedStatusUnknown", [nil], "exitedStatusUnknown", 3),
        ("exited", [LaunchdJobs.AgentStatus(lastExitCode: 3, runs: 1)], "exited(code: 0)", 0),
        ("signaled", [LaunchdJobs.AgentStatus(lastExitCode: 3, runs: 1)], "signaled(signal: 9)", 0),
    ] as [(String, [LaunchdJobs.AgentStatus?], String, Int)])
    func armedOutcomeReadsLaunchdOnlyWhenTheStatusIsUnknown(
        watched: String, reads: [LaunchdJobs.AgentStatus?], expected: String, readCount: Int
    ) async {
        let outcome: ProcessOutcome =
            switch watched {
            case "exited": .exited(code: 0)
            case "signaled": .signaled(signal: 9)
            default: .exitedStatusUnknown
            }
        let made = OSAllocatedUnfairLock(initialState: 0)
        let resolved = await LaunchdJobLauncher.armedOutcome(outcome) {
            await LaunchdJobLauncher.exitRecord(attempts: 3, interval: .zero) {
                let index = made.withLock { count in
                    defer { count += 1 }
                    return count
                }
                return reads[min(index, reads.count - 1)]
            }
        }
        #expect("\(resolved)" == expected)
        #expect(made.withLock { $0 } == readCount)
    }

    private func openSpool() throws -> (Int32, URL) {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "directa-job-\(UUID().uuidString).log")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        try #require(fd >= 0)
        return (fd, url)
    }
}
