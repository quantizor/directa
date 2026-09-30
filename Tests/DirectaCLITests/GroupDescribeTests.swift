import DirectaKit
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
                worker: starting  ·  pid 901  ·  log /logs/worker/current.log  ·  FELL SHORT (timeout)
                """)
    }

    @Test func anEmptyGroupPrintsNothing() {
        #expect(CLIRunner.describeGroup([]) == "")
    }
}
