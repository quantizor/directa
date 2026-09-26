import Foundation
import Testing

@testable import DirectaKit

@Suite struct LaunchdAdminShellTests {
    @Test func capturesStatusAndOutput() {
        let result = LaunchdAdmin.shell("/bin/echo", ["hello"])
        #expect(result.status == 0)
        #expect(result.output == "hello\n")
    }

    @Test func nonZeroExitIsReported() {
        let result = LaunchdAdmin.shell("/usr/bin/false", [])
        #expect(result.status != 0)
    }

    /** A child that writes more than one pipe buffer (macOS defaults to 64 KB)
        before exiting must not deadlock the caller: waiting for the child to
        exit before reading the pipe blocks the child on a full buffer it can
        never drain, and blocks this process on an exit that can now never
        happen. `shell` drains the pipe on another thread concurrently with
        waiting, so the child's writes always have somewhere to go. */
    @Test func aChildWritingPastOnePipeBufferStillReturnsInFull() {
        let target = 200_000
        let result = LaunchdAdmin.shell("/bin/sh", ["-c", "yes | head -c \(target)"])
        #expect(result.status == 0)
        #expect(result.output.utf8.count == target)
    }

    /** The timed path drains on a helper thread while it waits on
        termination; it returns the same full output. */
    @Test func aTimedChildWritingPastOnePipeBufferStillReturnsInFull() {
        let target = 200_000
        let result = LaunchdAdmin.shell(
            "/bin/sh", ["-c", "yes | head -c \(target)"], timeoutSeconds: 10)
        #expect(result.status == 0)
        #expect(result.output.utf8.count == target)
    }

    @Test func aCommandThatCannotStartReportsMinusOneOnEitherPath() {
        let missing = "/nonexistent/directa-shell-\(UUID().uuidString)"
        #expect(LaunchdAdmin.shell(missing, []).status == -1)
        #expect(LaunchdAdmin.shell(missing, [], timeoutSeconds: 1).status == -1)
    }

    /** The form async code calls answers exactly like the synchronous one. */
    @Test func theAsyncFormReturnsStatusAndFullOutput() async {
        let target = 200_000
        let result = await LaunchdAdmin.shell("/bin/sh", ["-c", "yes | head -c \(target); exit 4"])
        #expect(result.status == 4)
        #expect(result.output.utf8.count == target)
    }
}
