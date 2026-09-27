import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import directa

/** `Doctor.orphanLogDirFixFinding` turns one `logs.removeOrphan` answer into
    the `orphan-log-dir` finding `doctor --fix` reports: a removal is `fixed`,
    and a refusal or a failed delete is an `error` naming the directory, never
    reported as success. */
@Suite struct DoctorOrphanLogDirFindingTests {
    private let path = URL(fileURLWithPath: "/logs/myproj-abcd1234")

    @Test func aRemovedDirectoryIsFixed() {
        let finding = Doctor.orphanLogDirFixFinding(LogsRemoveOrphanResult(path: path, removal: .removed))
        #expect(
            finding
                == Doctor.Finding(
                    detail: "removed /logs/myproj-abcd1234, which matched no registered project",
                    kind: .orphanLogDir, severity: .fixed))
    }

    @Test func aRefusedDirectoryWithNothingLeftToDoNamesOnlyTheReason() {
        let finding = Doctor.orphanLogDirFixFinding(
            LogsRemoveOrphanResult(path: path, removal: .refused(.claimed)))
        #expect(
            finding
                == Doctor.Finding(
                    detail: "left /logs/myproj-abcd1234 in place: a registered project claims it",
                    kind: .orphanLogDir, severity: .error))
    }

    @Test func aRefusedLinkNamesTheReasonAndTheNextStep() {
        let finding = Doctor.orphanLogDirFixFinding(
            LogsRemoveOrphanResult(path: path, removal: .refused(.link)))
        #expect(
            finding.detail
                == "left /logs/myproj-abcd1234 in place: it is a link to another location, not a log directory directa created; remove the link yourself if nothing needs it"
        )
        #expect(finding.severity == .error)
    }

    @Test func aFailedDeleteKeepsTheSystemMessage() {
        let finding = Doctor.orphanLogDirFixFinding(
            LogsRemoveOrphanResult(path: path, removal: .failed("permission denied")))
        #expect(
            finding
                == Doctor.Finding(
                    detail: "could not remove /logs/myproj-abcd1234: permission denied",
                    kind: .orphanLogDir, severity: .error))
    }
}

/** `Doctor.orphanLogDirFindings` over a real temp logs root with a scripted
    daemon. `--fix` asks the daemon to remove each unclaimed directory by name
    and never deletes anything itself. */
@Suite(.temporaryTree) struct DoctorOrphanLogDirPassTests {
    private struct Dropped: Error, LocalizedError {
        var errorDescription: String? { "daemon went away" }
    }

    /** Collects the names `removeOrphan` was asked for. */
    private actor Requests {
        var names: [String] = []
        func record(_ name: String) { names.append(name) }
    }

    @Test func fixAsksTheDaemonForEachUnclaimedDirectoryByNameAndReportsItsAnswer() async throws {
        let fixture = try Fixture()
        let claimedProject = fixture.root.appending(path: "live").path
        let claimedDir = fixture.logsDir.appending(path: DirectaPaths.projectLogDirName(project: claimedProject))
        let first = fixture.logsDir.appending(path: "gone-aaaaaaaa")
        let second = fixture.logsDir.appending(path: "gone-bbbbbbbb")
        for directory in [claimedDir, first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let requests = Requests()

        let findings = await Doctor.orphanLogDirFindings(
            fix: true, info: fixture.info(claiming: [claimedProject])
        ) { name in
            await requests.record(name)
            return LogsRemoveOrphanResult(
                path: fixture.logsDir.appending(path: name),
                removal: name == "gone-aaaaaaaa" ? .removed : .refused(.claimed))
        }

        #expect(await requests.names == ["gone-aaaaaaaa", "gone-bbbbbbbb"])
        #expect(findings.map(\.detail) == [
            "removed \(first.path), which matched no registered project",
            "left \(second.path) in place: a registered project claims it",
        ])
        #expect(findings.map(\.severity) == [.fixed, .error])
        /** The scripted daemon deleted nothing, so every directory is still
            there: the client never removes one on its own. */
        for directory in [claimedDir, first, second] {
            #expect(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test func aDaemonThatPredatesTheMethodGetsTheReportAndOneRestartFinding() async throws {
        let fixture = try Fixture()
        let orphans = ["gone-aaaaaaaa", "gone-bbbbbbbb"].map { fixture.logsDir.appending(path: $0) }
        for orphan in orphans {
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        }
        let requests = Requests()

        let findings = await Doctor.orphanLogDirFindings(
            fix: true, info: fixture.info(claiming: [])
        ) { name in
            await requests.record(name)
            throw WireError(
                code: .usage, message: WireError.unknownMethodMessage(WireMethod.logsRemoveOrphan.rawValue))
        }

        #expect(await requests.names == ["gone-aaaaaaaa"])
        #expect(findings.map(\.detail) == [
            "\(orphans[0].path) (Zero KB) matches no registered project (run: directa doctor --fix)",
            "\(orphans[1].path) (Zero KB) matches no registered project (run: directa doctor --fix)",
            "removed no leftover log directories: the running daemon is too old to remove them safely; run: directa daemon restart, then directa doctor --fix",
        ])
        #expect(findings.map(\.severity) == [.warning, .warning, .error])
        for orphan in orphans {
            #expect(FileManager.default.fileExists(atPath: orphan.path))
        }
    }

    /** Any other failure is that directory's own error, and the pass goes on. */
    @Test func anotherFailureIsReportedPerDirectoryAndThePassContinues() async throws {
        let fixture = try Fixture()
        let first = fixture.logsDir.appending(path: "gone-aaaaaaaa")
        let second = fixture.logsDir.appending(path: "gone-bbbbbbbb")
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let findings = await Doctor.orphanLogDirFindings(
            fix: true, info: fixture.info(claiming: [])
        ) { name in
            if name == "gone-aaaaaaaa" {
                throw WireError(code: .daemonUnreachable, message: "daemon closed the connection")
            }
            if name == "gone-bbbbbbbb" { throw Dropped() }
            Issue.record("unexpected name \(name)")
            throw Dropped()
        }

        #expect(findings.map(\.detail) == [
            "could not remove \(first.path): daemon closed the connection",
            "could not remove \(second.path): daemon went away",
        ])
        #expect(findings.map(\.severity) == [.error, .error])
    }

    /** Report-only never deletes, so it never asks the daemon to. */
    @Test func reportOnlyWarnsAndNeverAsksForARemoval() async throws {
        let fixture = try Fixture()
        let orphan = fixture.logsDir.appending(path: "gone-project-abcd1234")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let findings = await Doctor.orphanLogDirFindings(
            fix: false, info: fixture.info(claiming: [])
        ) { name in
            Issue.record("report-only must not ask for a removal")
            return LogsRemoveOrphanResult(path: fixture.logsDir.appending(path: name), removal: .removed)
        }

        #expect(findings.map(\.detail) == [
            "\(orphan.path) (Zero KB) matches no registered project (run: directa doctor --fix)"
        ])
        #expect(findings.map(\.severity) == [.warning])
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func fixWithNothingUnclaimedAsksForNothing() async throws {
        let fixture = try Fixture()
        let findings = await Doctor.orphanLogDirFindings(
            fix: true, info: fixture.info(claiming: [])
        ) { name in
            Issue.record("nothing to remove, yet asked for \(name)")
            return LogsRemoveOrphanResult(path: fixture.logsDir.appending(path: name), removal: .removed)
        }
        #expect(findings.isEmpty)
    }

    private struct Fixture {
        let logsDir: URL
        let root: URL

        init() throws {
            root = try TemporaryTree.directory(named: "doctor-orphanlogs")
            logsDir = root.appending(path: "logs")
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }

        func info(claiming projects: [String]?) -> DaemonInfo {
            DaemonInfo(
                claimedProjects: projects, dataDir: root.appending(path: "data").path,
                daemonVersion: "0.0.0", logsDir: logsDir.path, pid: 1, proto: 1,
                socketPath: root.appending(path: "daemon.sock").path)
        }
    }
}
