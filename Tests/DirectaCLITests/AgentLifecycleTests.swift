import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import directa

/** The background agent runs only the default layout, so the commands that
    manage it refuse while `DIRECTA_SOCKET`, `DIRECTA_DATA_DIR`, or
    `DIRECTA_LOGS_DIR` points the CLI at another one, and `uninstall --purge`
    never deletes the default folders on behalf of an overridden layout. */
@Suite(.temporaryTree) struct AgentLifecycleTests {
    @Test(arguments: ["DIRECTA_DATA_DIR", "DIRECTA_LOGS_DIR", "DIRECTA_SOCKET"])
    func anyLayoutOverrideRefusesTheLifecycleCommands(key: String) throws {
        let refusal = try #require(
            AgentLifecycle.overrideRefusal(command: "uninstall", environment: [key: "/tmp/elsewhere"]))
        #expect(refusal.code == .usage)
        #expect(refusal.hint == "run: env -u DIRECTA_DATA_DIR -u DIRECTA_LOGS_DIR -u DIRECTA_SOCKET directa uninstall")
        #expect(
            refusal.message
                == "uninstall manages the background agent, which runs only the default data, logs, and socket locations, but \(key) points this CLI at another layout; unset it to manage the agent (a daemon started by hand with --socket, --data-dir, or --logs-dir stops with directa daemon stop)"
        )
    }

    @Test func theDefaultLayoutIsNotRefused() {
        #expect(AgentLifecycle.overrideRefusal(command: "daemon install", environment: [:]) == nil)
        #expect(
            AgentLifecycle.overrideRefusal(
                command: "daemon install",
                environment: ["DIRECTA_DATA_DIR": "", "DIRECTA_LOGS_DIR": "", "DIRECTA_SOCKET": ""]) == nil)
    }

    @Test func twoOverridesAreBothNamed() throws {
        let refusal = try #require(
            AgentLifecycle.overrideRefusal(
                command: "daemon start",
                environment: ["DIRECTA_DATA_DIR": "/d", "DIRECTA_SOCKET": "/s.sock"]))
        #expect(refusal.message.contains("DIRECTA_DATA_DIR and DIRECTA_SOCKET point this CLI"))
        #expect(refusal.message.contains("unset them"))
    }

    /** Stand-ins for the default folders live in a temp tree; with an
        override set, the purge touches none of them. */
    @Test func purgeUnderAnOverrideTouchesNothing() throws {
        let fixture = try Fixture()
        let refusal = Uninstall.purgeData(
            environment: ["DIRECTA_DATA_DIR": fixture.root.appending(path: "throwaway").path],
            paths: fixture.paths, home: fixture.home)
        #expect(refusal?.code == .usage)
        for url in fixture.everything {
            #expect(FileManager.default.fileExists(atPath: url.path), "\(url.path)")
        }
    }

    @Test func purgeOfTheDefaultLayoutRemovesItsFoldersAndResidue() throws {
        let fixture = try Fixture()
        #expect(Uninstall.purgeData(environment: [:], paths: fixture.paths, home: fixture.home) == nil)
        for url in fixture.everything {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.path)")
        }
    }

    private struct Fixture {
        let home: URL
        let paths: DirectaPaths
        let root: URL

        var everything: [URL] {
            [paths.dataDir, paths.logsDir] + DirectaPaths.userLibraryResidue(home: home)
        }

        init() throws {
            root = try TemporaryTree.directory(named: "lifecycle")
            home = root.appending(path: "home")
            paths = DirectaPaths(dataDir: root.appending(path: "data"), logsDir: root.appending(path: "logs"))
            for url in [paths.dataDir, paths.logsDir] + DirectaPaths.userLibraryResidue(home: home) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }
}
