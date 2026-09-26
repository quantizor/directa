import DirectaKit
import Foundation
import Testing

@testable import directa

/** `Doctor.orphanLogDirFixFinding` turns one `OrphanProjectLogs.remove`
    outcome into the `orphan-log-dir` finding `doctor --fix` reports: a removal
    is `fixed`, and a refusal or a failed delete is an `error` naming the
    directory, never reported as success. */
@Suite struct DoctorOrphanLogDirFindingTests {
    private let path = URL(fileURLWithPath: "/logs/myproj-abcd1234")

    @Test func aRemovedDirectoryIsFixed() {
        let finding = Doctor.orphanLogDirFixFinding(path: path, outcome: .removed)
        #expect(finding.detail == "removed /logs/myproj-abcd1234, which matched no registered project")
        #expect(finding.kind == "orphan-log-dir")
        #expect(finding.severity == "fixed")
    }

    @Test func aRefusedDirectoryWithNothingLeftToDoNamesOnlyTheReason() {
        let finding = Doctor.orphanLogDirFixFinding(path: path, outcome: .refused(.claimed))
        #expect(finding.detail == "left /logs/myproj-abcd1234 in place: a registered project claims it")
        #expect(finding.kind == "orphan-log-dir")
        #expect(finding.severity == "error")
    }

    @Test func aRefusedLinkNamesTheReasonAndTheNextStep() {
        let finding = Doctor.orphanLogDirFixFinding(path: path, outcome: .refused(.link))
        #expect(
            finding.detail
                == "left /logs/myproj-abcd1234 in place: it is a link to another location, not a log directory directa created; remove the link yourself if nothing needs it"
        )
        #expect(finding.severity == "error")
    }

    @Test func aFailedDeleteKeepsTheSystemMessage() {
        let finding = Doctor.orphanLogDirFixFinding(
            path: path, outcome: .failed("permission denied"))
        #expect(finding.detail == "could not remove /logs/myproj-abcd1234: permission denied")
        #expect(finding.kind == "orphan-log-dir")
        #expect(finding.severity == "error")
    }
}

/** `Doctor.orphanLogDirFindings` over a real temp logs root. `--fix` deletes
    only against the claimed set it re-reads right before removing, never the
    one fetched when doctor began. */
@Suite struct DoctorOrphanLogDirPassTests {
    private struct RefetchFailed: Error, LocalizedError {
        var errorDescription: String? { "daemon went away" }
    }

    /** A project first started after doctor's opening `daemon.info` owns a
        log directory the opening claimed set does not name. */
    @Test func fixKeepsALogDirectoryClaimedSinceDoctorBegan() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let started = fixture.root.appending(path: "started-late").path
        let startedLogDir = fixture.logsDir.appending(
            path: DirectaPaths().projectLogDir(project: started).lastPathComponent)
        try FileManager.default.createDirectory(at: startedLogDir, withIntermediateDirectories: true)

        let findings = await Doctor.orphanLogDirFindings(
            fix: true, info: fixture.info(claiming: [])
        ) { fixture.info(claiming: [started]) }

        #expect(findings.isEmpty)
        #expect(FileManager.default.fileExists(atPath: startedLogDir.path))
    }

    @Test func fixRemovesALogDirectoryStillUnclaimedAfterTheRecheck() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let orphan = fixture.logsDir.appending(path: "gone-project-abcd1234")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let findings = await Doctor.orphanLogDirFindings(
            fix: true, info: fixture.info(claiming: [])
        ) { fixture.info(claiming: []) }

        #expect(findings.map(\.detail) == ["removed \(orphan.path), which matched no registered project"])
        #expect(findings.map(\.severity) == ["fixed"])
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func fixRemovesNothingWhenTheRecheckFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let orphan = fixture.logsDir.appending(path: "gone-project-abcd1234")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let findings = await Doctor.orphanLogDirFindings(
            fix: true, info: fixture.info(claiming: [])
        ) { throw RefetchFailed() }

        #expect(findings.map(\.detail) == [
            "removed no leftover log directories: could not re-check which projects the daemon uses right before removing (daemon went away); run: directa doctor --fix"
        ])
        #expect(findings.map(\.severity) == ["error"])
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func fixRemovesNothingWhenTheRecheckLacksClaimedProjects() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let orphan = fixture.logsDir.appending(path: "gone-project-abcd1234")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let findings = await Doctor.orphanLogDirFindings(
            fix: true, info: fixture.info(claiming: [])
        ) { fixture.info(claiming: nil) }

        #expect(findings.map(\.detail) == [
            "removed no leftover log directories: the daemon stopped reporting which projects it uses; run: directa daemon restart, then directa doctor --fix"
        ])
        #expect(findings.map(\.severity) == ["error"])
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    /** Report-only never deletes, so it reads the opening claimed set and
        never asks the daemon again. */
    @Test func reportOnlyWarnsAndNeverRechecks() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let orphan = fixture.logsDir.appending(path: "gone-project-abcd1234")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let findings = await Doctor.orphanLogDirFindings(
            fix: false, info: fixture.info(claiming: [])
        ) {
            Issue.record("report-only must not re-fetch daemon.info")
            return fixture.info(claiming: [])
        }

        #expect(findings.map(\.detail) == [
            "\(orphan.path) (Zero KB) matches no registered project (run: directa doctor --fix)"
        ])
        #expect(findings.map(\.severity) == ["warning"])
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    private struct Fixture {
        let logsDir: URL
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "directa-doctor-orphanlogs-\(UUID().uuidString)")
            logsDir = root.appending(path: "logs")
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }

        func info(claiming projects: [String]?) -> DaemonInfo {
            DaemonInfo(
                claimedProjects: projects, dataDir: root.appending(path: "data").path,
                daemonVersion: "0.0.0", logsDir: logsDir.path, pid: 1, proto: 1,
                socketPath: root.appending(path: "daemon.sock").path)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
