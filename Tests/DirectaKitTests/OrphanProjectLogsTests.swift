import Foundation
import Testing

@testable import DirectaKit

@Suite struct OrphanProjectLogsTests {
    @Test func aClaimedSlugDirIsNotAnOrphan() {
        let findings = OrphanProjectLogs.detect(
            entries: [(apparentBytes: 100, path: URL(fileURLWithPath: "/logs/myproj-abcd1234"))],
            claimedSlugDirs: ["myproj-abcd1234"])
        #expect(findings.isEmpty)
    }

    @Test func anUnclaimedSlugDirIsAnOrphanNamingSizeAndRemovalCommand() {
        let findings = OrphanProjectLogs.detect(
            entries: [(apparentBytes: 100, path: URL(fileURLWithPath: "/logs/myproj-abcd1234"))],
            claimedSlugDirs: [])
        #expect(findings.count == 1)
        #expect(findings[0].detail == "/logs/myproj-abcd1234 (100 bytes) matches no registered project")
        #expect(findings[0].remedy == "rm -rf /logs/myproj-abcd1234")
    }

    @Test func multipleOrphansSortByPath() {
        let findings = OrphanProjectLogs.detect(
            entries: [
                (apparentBytes: 0, path: URL(fileURLWithPath: "/logs/zproj-1111")),
                (apparentBytes: 0, path: URL(fileURLWithPath: "/logs/aproj-2222")),
            ],
            claimedSlugDirs: [])
        #expect(findings.map(\.detail) == [
            "/logs/aproj-2222 (Zero KB) matches no registered project",
            "/logs/zproj-1111 (Zero KB) matches no registered project",
        ])
    }

    @Test func scanFindsOnlyTheDirectoryNoProjectClaims() throws {
        let logsDir = FileManager.default.temporaryDirectory
            .appending(path: "directa-orphanlogs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logsDir) }

        let claimed = logsDir.appending(path: "claimed-1111")
        let orphaned = logsDir.appending(path: "orphaned-2222")
        try FileManager.default.createDirectory(at: claimed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orphaned, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 100).write(to: orphaned.appending(path: "current.log"))

        /** A stray plain file directly under the logs root (never a slug
            directory itself) must not be mistaken for one. */
        try Data().write(to: logsDir.appending(path: "stray.log"))

        let paths = DirectaPaths(dataDir: logsDir.appending(path: "data"), logsDir: logsDir)
        let findings = OrphanProjectLogs.scan(paths: paths, claimedSlugDirs: ["claimed-1111"])

        #expect(findings.count == 1)
        #expect(findings[0].detail.hasPrefix(orphaned.path))
        #expect(findings[0].detail.contains("100 bytes"))
        #expect(findings[0].remedy == "rm -rf \(orphaned.path)")
    }

    @Test func scanAnswersEmptyForAMissingLogsDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "directa-orphanlogs-missing-\(UUID().uuidString)")
        let paths = DirectaPaths(dataDir: missing.appending(path: "data"), logsDir: missing)
        #expect(OrphanProjectLogs.scan(paths: paths, claimedSlugDirs: []).isEmpty)
    }
}
