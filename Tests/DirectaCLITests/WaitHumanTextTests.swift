import DirectaKit
import Testing

@testable import directa

/** `directa wait` in human mode: a `--healthy` wait that ends on a crash or a
    stop names `directa ensure` as the next step; nothing else does. */
@Suite struct WaitHumanTextTests {
    private static func result(_ phase: ServerPhase, reason: EnsureReason?) -> EnsureResult {
        EnsureResult(
            reason: reason,
            server: ServerStatus(logPath: "/logs/web/current.log", phase: phase, project: "/code/app", server: "web"))
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

    @Test func timeoutAndFailedCarryNoEnsureHint() {
        #expect(
            Wait.humanText(Self.result(.starting, reason: .timeout), condition: .healthy, name: "web")
                == """
                wait fell short (timeout)
                web: starting  ·  log /logs/web/current.log
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

    @Test func aMetWaitIsJustTheServerLine() {
        #expect(
            Wait.humanText(Self.result(.running, reason: nil), condition: .healthy, name: "web")
                == "web: running  ·  log /logs/web/current.log")
    }
}
