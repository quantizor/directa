import DirectaKit
import Testing

@testable import directa

/** `directa wait` in human mode: a `--healthy` wait that ends on a crash or a
    stop names `directa ensure` as the next step; nothing else does. */
@Suite struct WaitHumanTextTests {
    private static func result(
        _ phase: ServerPhase, reason: EnsureReason?, name: String = "web", pid: Int? = nil
    ) -> EnsureResult {
        EnsureResult(
            reason: reason,
            server: ServerStatus(
                logPath: "/logs/web/current.log", phase: phase, pid: pid, project: "/code/app", server: name))
    }

    @Test func healthyWaitThatCrashedNamesEnsure() {
        #expect(
            Wait.humanText(Self.result(.crashed, reason: .crashed), condition: .healthy, name: "web")
                == """
                wait fell short (crashed)
                web: crashed  ·  log /logs/web/current.log
                hint: directa ensure web
                """)
    }

    @Test func healthyWaitThatStoppedNamesEnsure() {
        #expect(
            Wait.humanText(Self.result(.stopped, reason: .stopped), condition: .healthy, name: "web")
                == """
                wait fell short (stopped)
                web: stopped  ·  log /logs/web/current.log
                hint: directa ensure web
                """)
    }

    @Test func aNameWithShellCharactersIsQuoted() {
        #expect(
            Wait.humanText(Self.result(.crashed, reason: .crashed), condition: .healthy, name: "my app;x")
                .hasSuffix("\nhint: directa ensure 'my app;x'"))
    }

    @Test func timeoutMidStartSaysStillStartingAndNamesTheWaitCommand() {
        #expect(
            Wait.humanText(Self.result(.starting, reason: .timeout), condition: .healthy, name: "web")
                == """
                wait fell short (timeout)
                web: starting  ·  log /logs/web/current.log
                hint: still starting, not failed; to keep waiting: directa wait web --timeout <seconds>
                """)
        #expect(
            Wait.humanText(Self.result(.starting, reason: .timeout), condition: .healthy, name: "my app;x")
                .hasSuffix("\nhint: still starting, not failed; to keep waiting: directa wait 'my app;x' --timeout <seconds>"))
    }

    @Test func timeoutOfAStoppedWaitAndFailedCarryNoHint() {
        #expect(
            Wait.humanText(Self.result(.starting, reason: .timeout), condition: .stopped, name: "web")
                == """
                wait fell short (timeout)
                web: starting  ·  log /logs/web/current.log
                """)
        #expect(
            Wait.humanText(Self.result(.running, reason: .timeout), condition: .healthy, name: "web")
                == """
                wait fell short (timeout)
                web: running  ·  log /logs/web/current.log
                """)
        #expect(
            Wait.humanText(Self.result(.failed, reason: .failed), condition: .healthy, name: "web")
                == """
                wait fell short (failed)
                web: failed  ·  log /logs/web/current.log
                """)
    }

    @Test func stoppedWaitCarriesNoEnsureHint() {
        #expect(
            Wait.humanText(Self.result(.crashed, reason: .crashed), condition: .stopped, name: "web")
                == """
                wait fell short (crashed)
                web: crashed  ·  log /logs/web/current.log
                """)
    }

    @Test func stoppedTimeoutOnAFailedRunWithALiveProcessNamesStop() {
        #expect(
            Wait.humanText(
                Self.result(.failed, reason: .timeout, pid: 4242), condition: .stopped, name: "web")
                == """
                wait fell short (timeout)
                web: failed  ·  pid 4242  ·  log /logs/web/current.log
                hint: directa stop web
                """)
    }

    /** Quoted like the other hints in this text, so the line pastes as one
        command. */
    @Test func stoppedTimeoutQuotesAnUnsafeServerName() {
        #expect(
            Wait.humanText(
                Self.result(.failed, reason: .timeout, name: "my app;x", pid: 4242), condition: .stopped,
                name: "my app;x"
            )
            .hasSuffix("\nhint: directa stop 'my app;x'"))
    }

    @Test func stoppedTimeoutOnAFailedRunWithNoProcessCarriesNoStopHint() {
        #expect(
            Wait.humanText(Self.result(.failed, reason: .timeout), condition: .stopped, name: "web")
                == """
                wait fell short (timeout)
                web: failed  ·  log /logs/web/current.log
                """)
    }

    @Test func aMetWaitIsJustTheServerLine() {
        #expect(
            Wait.humanText(Self.result(.running, reason: nil), condition: .healthy, name: "web")
                == "web: running  ·  log /logs/web/current.log")
    }
}
