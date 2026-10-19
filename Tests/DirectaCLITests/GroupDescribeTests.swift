import DirectaKit
import Foundation
import Testing

@testable import directa

/** `up`, `restart`, and `switch` print one shared group result shape. */
@Suite struct GroupDescribeTests {
    private static func status(_ name: String, _ phase: ServerPhase, pid: Int? = nil) -> ServerStatus {
        var status = ServerStatus(
            logPath: "/logs/\(name)/current.log", phase: phase, project: "/code/app", server: name)
        status.pid = pid
        return status
    }

    @Test func mixedResultsPrintOneLinePerServerWithTheReasonWhereItFellShort() {
        let results = [
            EnsureResult(server: Self.status("web", .running, pid: 812)),
            EnsureResult(reason: .crashed, server: Self.status("api", .crashed)),
            EnsureResult(reason: .timeout, server: Self.status("worker", .starting, pid: 901)),
        ]
        #expect(
            CLIRunner.describeGroup(results)
                == """
                web: running  ·  pid 812  ·  log /logs/web/current.log
                api: crashed  ·  log /logs/api/current.log  ·  FELL SHORT (crashed)
                worker: starting  ·  pid 901  ·  log /logs/worker/current.log  ·  FELL SHORT (timeout)  ·  still starting, not failed; to keep waiting: directa wait worker --timeout <seconds>
                """)
    }

    /** Only a timeout that caught the server mid-start says it is still
        starting: one that caught it running (its checks failing) or any other
        reason does not, and a name a shell would split is quoted. */
    @Test func onlyATimeoutMidStartNamesTheWaitCommand() {
        let results = [
            EnsureResult(reason: .timeout, server: Self.status("api", .running, pid: 7)),
            EnsureResult(reason: .failed, server: Self.status("db", .failed)),
            EnsureResult(reason: .timeout, server: Self.status("my app;x", .starting)),
        ]
        #expect(
            CLIRunner.describeGroup(results)
                == """
                api: running  ·  pid 7  ·  log /logs/api/current.log  ·  FELL SHORT (timeout)
                db: failed  ·  log /logs/db/current.log  ·  FELL SHORT (failed)
                my app;x: starting  ·  log /logs/my app;x/current.log  ·  FELL SHORT (timeout)  ·  still starting, not failed; to keep waiting: directa wait 'my app;x' --timeout <seconds>
                """)
    }

    @Test func ensureThatTimedOutMidStartSaysTheServerIsStillStarting() {
        #expect(
            Ensure.humanText(
                EnsureResult(reason: .timeout, server: Self.status("web", .starting, pid: 812)), name: "web")
                == """
                ensure fell short (timeout)
                web: starting  ·  pid 812  ·  log /logs/web/current.log
                hint: still starting, not failed; to keep waiting: directa wait web --timeout <seconds>
                """)
    }

    @Test func ensureThatCrashedOrMetCarriesNoWaitHint() {
        #expect(
            Ensure.humanText(EnsureResult(reason: .crashed, server: Self.status("web", .crashed)), name: "web")
                == """
                ensure fell short (crashed)
                web: crashed  ·  log /logs/web/current.log
                """)
        #expect(
            Ensure.humanText(EnsureResult(server: Self.status("web", .running, pid: 812)), name: "web")
                == "web: running  ·  pid 812  ·  log /logs/web/current.log")
    }

    /** A server whose phase reads `running` while its latest checks fail says
        so in the human line, so `status`, `ensure`, and `up` do not read as a
        healthy run. */
    @Test func aRunningServerWithAFailingCheckNamesIt() {
        var failing = Self.status("web", .running, pid: 812)
        failing.lastHealthCheck = HealthCheckResult(
            at: Date(timeIntervalSince1970: 0), detail: "HTTP 500", failures: 4, passed: false)
        #expect(
            CLIRunner.describe(failing)
                == "web: running  ·  pid 812  ·  4 health checks failed in a row (HTTP 500)  ·  log /logs/web/current.log")
        failing.lastHealthCheck = HealthCheckResult(
            at: Date(timeIntervalSince1970: 0), failures: 0, passed: true)
        #expect(CLIRunner.describe(failing) == "web: running  ·  pid 812  ·  log /logs/web/current.log")
    }

    @Test func anEmptyGroupPrintsNothing() {
        #expect(CLIRunner.describeGroup([]) == "")
    }
}
