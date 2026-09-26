import Foundation
import Testing

@testable import DirectaKit

/** Where the CLI's data and logs directories come from: the environment
    overrides for local paths, and the answering daemon's own report for
    everything that daemon owns. */
@Suite struct DirectaPathsTests {
    private let defaults = DirectaPaths()

    @Test func noOverridesKeepTheDefaults() {
        let paths = DirectaPaths.fromEnvironment([:])
        #expect(paths.dataDir == defaults.dataDir)
        #expect(paths.logsDir == defaults.logsDir)
    }

    @Test func bothOverridesApply() {
        let paths = DirectaPaths.fromEnvironment([
            "DIRECTA_DATA_DIR": "/tmp/smoke/data", "DIRECTA_LOGS_DIR": "/tmp/smoke/logs",
        ])
        #expect(paths.dataDir.path == "/tmp/smoke/data")
        #expect(paths.logsDir.path == "/tmp/smoke/logs")
        #expect(paths.agentPathFile.path == "/tmp/smoke/data/agent.path")
        #expect(paths.stoppedIntentFile.path == "/tmp/smoke/data/stopped.intent")
    }

    @Test func eachOverrideIsIndependent() {
        let dataOnly = DirectaPaths.fromEnvironment(["DIRECTA_DATA_DIR": "/tmp/d"])
        #expect(dataOnly.dataDir.path == "/tmp/d")
        #expect(dataOnly.logsDir == defaults.logsDir)

        let logsOnly = DirectaPaths.fromEnvironment(["DIRECTA_LOGS_DIR": "/tmp/l"])
        #expect(logsOnly.dataDir == defaults.dataDir)
        #expect(logsOnly.logsDir.path == "/tmp/l")
    }

    @Test func anEmptyValueIsUnset() {
        let paths = DirectaPaths.fromEnvironment(["DIRECTA_DATA_DIR": "", "DIRECTA_LOGS_DIR": ""])
        #expect(paths.dataDir == defaults.dataDir)
        #expect(paths.logsDir == defaults.logsDir)
    }

    @Test func dotSegmentsAreResolved() {
        let paths = DirectaPaths.fromEnvironment(["DIRECTA_DATA_DIR": "/tmp/a/../b/./data"])
        #expect(paths.dataDir.path == "/tmp/b/data")
    }

    @Test func theDaemonReportDecidesBothDirectories() {
        let info = DaemonInfo(
            dataDir: "/tmp/w/data", daemonVersion: "1", logsDir: "/tmp/w/logs", pid: 1, proto: 1,
            socketPath: "/tmp/w/d.sock")
        let paths = DirectaPaths(daemon: info)
        #expect(paths.dataDir.path == "/tmp/w/data")
        #expect(paths.logsDir.path == "/tmp/w/logs")
        #expect(
            paths.projectLogDir(project: "/code/app").deletingLastPathComponent().path == "/tmp/w/logs")
    }
}
