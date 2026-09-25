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
        let outcome = await LaunchdJobLauncher().run(
            argv: ["/bin/sleep", "8"],
            capture: SpawnCapture(
                stderrFD: errFD, stderrPath: errURL.path, stdoutFD: outFD, stdoutPath: outURL.path),
            cwd: nil,
            environment: [:],
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
            it), so this is the empirical case the kqueue man page's "valid only
            on child processes" caveat is about: `NOTE_EXITSTATUS` still carries
            the real wait(2) status here. Without it, `waitForExit` decodes
            every exit as `.exited(code: 0)`, which this exact signal (15, not
            0) would not catch if the decode were wrong. */
        switch outcome {
        case .signaled(let signal):
            #expect(signal == Int(SIGTERM))
        case .exited, .spawnFailed:
            Issue.record("expected .signaled(signal: \(SIGTERM)), got \(outcome)")
        }
    }

    /** The other half of the same empirical case: a launchd job (not a child
        of this process) that exits on its own with a nonzero code. Before
        `NOTE_EXITSTATUS` this always decoded as `.exited(code: 0)` regardless
        of the real status, masking every real failure a launchd-run dev server
        reported. */
    @Test func launchdJobReportsItsRealExitCode() async throws {
        let (outFD, outURL) = try openSpool()
        let (errFD, errURL) = try openSpool()
        defer {
            close(outFD)
            close(errFD)
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let outcome = await LaunchdJobLauncher().run(
            /** A brief sleep before exiting: `run` confirms the job's pid is
                published and has become a session leader before arming the
                exit watch, and a command that exits before that confirmation
                finishes races `run` into reporting `spawnFailed` instead of
                the real exit code, independent of this test's assertion. */
            argv: ["/bin/sh", "-c", "sleep 0.3; exit 3"],
            capture: SpawnCapture(
                stderrFD: errFD, stderrPath: errURL.path, stdoutFD: outFD, stdoutPath: outURL.path),
            cwd: nil,
            environment: [:],
            onSpawn: { _ in }
        )
        switch outcome {
        case .exited(let code):
            #expect(code == 3)
        case .signaled, .spawnFailed:
            Issue.record("expected .exited(code: 3), got \(outcome)")
        }
    }

    private func openSpool() throws -> (Int32, URL) {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "directa-job-\(UUID().uuidString).log")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        try #require(fd >= 0)
        return (fd, url)
    }
}
