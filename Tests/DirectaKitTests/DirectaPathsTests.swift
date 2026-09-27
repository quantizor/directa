import DirectaTestSupport
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

    /** The socket comes from the environment the layout was built from, never
        from this process's own, so an injected environment decides it. */
    @Test func theSocketFollowsTheInjectedEnvironment() {
        #expect(
            DirectaPaths.fromEnvironment(["DIRECTA_SOCKET": "/tmp/s/d.sock"]).socketPath == "/tmp/s/d.sock")
        #expect(
            DirectaPaths.fromEnvironment(["DIRECTA_DATA_DIR": "/tmp/s/data"]).socketPath
                == "/tmp/s/data/daemon.sock")
        #expect(
            DirectaPaths.fromEnvironment(["DIRECTA_DATA_DIR": "/tmp/s/data", "DIRECTA_SOCKET": ""]).socketPath
                == "/tmp/s/data/daemon.sock")
    }

    @Test func anyNonEmptyLayoutVariableIsAnOverride() {
        #expect(!DirectaPaths.hasEnvironmentOverride([:]))
        #expect(!DirectaPaths.hasEnvironmentOverride(["HOME": "/Users/x"]))
        #expect(
            !DirectaPaths.hasEnvironmentOverride([
                "DIRECTA_DATA_DIR": "", "DIRECTA_LOGS_DIR": "", "DIRECTA_SOCKET": "",
            ]))
        for key in ["DIRECTA_DATA_DIR", "DIRECTA_LOGS_DIR", "DIRECTA_SOCKET"] {
            #expect(DirectaPaths.hasEnvironmentOverride([key: "/tmp/x"]), "\(key)")
        }
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
        #expect(paths.socketPath == "/tmp/w/d.sock")
    }
}

/** A project path that no longer exists still canonicalizes to the spelling
    it was recorded under while it did: the nearest ancestor that still exists
    is resolved and the vanished rest re-appended. Without that, a discarded
    checkout asked for through a symlinked ancestor (`/var` for `/private/var`,
    or a link of the user's own) misses the key the registry stored. */
@Suite(.temporaryTree) struct CanonicalProjectPathTests {
    @Test func aVanishedPathKeepsItsRecordedSpellingThroughASymlinkedAncestor() throws {
        let base = try TemporaryTree.directory(named: "canonical")
        let real = base.appending(path: "real")
        let project = real.appending(path: "proj")
        try FileManager.default.createDirectory(
            at: project.appending(path: "app"), withIntermediateDirectories: true)
        let link = base.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let recorded = canonicalProjectPath(project.path)
        let recordedBelow = canonicalProjectPath(project.appending(path: "app").path)
        #expect(canonicalProjectPath(link.appending(path: "proj").path) == recorded)

        try FileManager.default.removeItem(at: project)

        #expect(canonicalProjectPath(link.appending(path: "proj").path) == recorded)
        #expect(canonicalProjectPath(project.path) == recorded)
        #expect(canonicalProjectPath(link.appending(path: "proj/app").path) == recordedBelow)
        #expect(canonicalProjectPath(recorded) == recorded)
    }

    /** The case seen in practice: macOS's temporary directory lives under
        `/private/var`, reached through the `/var` link, and a recorded key
        keeps `/private`. */
    @Test func aVanishedPathSpelledThroughVarFindsThePrivateVarKey() throws {
        let base = try TemporaryTree.directory(named: "canonical-var")
        let project = base.appending(path: "proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let recorded = canonicalProjectPath(project.path)
        try #require(recorded.hasPrefix("/private/var/"), "the temporary tree is not under /private/var: \(recorded)")
        let varSpelling = String(recorded.dropFirst("/private".count))
        #expect(canonicalProjectPath(varSpelling) == recorded)

        try FileManager.default.removeItem(at: project)

        #expect(canonicalProjectPath(varSpelling) == recorded)
        #expect(canonicalProjectPath(recorded) == recorded)
    }

    @Test func aPathWithNoExistingAncestorBelowTheRootStaysAsWritten() {
        let path = "/directa-nonexistent-\(UUID().uuidString)/a/b"
        #expect(canonicalProjectPath(path) == path)
        #expect(canonicalProjectPath(path + "/../b/./") == path)
    }
}
