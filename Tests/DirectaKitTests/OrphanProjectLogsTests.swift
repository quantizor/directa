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

    @Test func anUnclaimedSlugDirIsAnOrphanNamingSizeAndTheDoctorFixCommand() {
        let path = URL(fileURLWithPath: "/logs/myproj-abcd1234")
        let findings = OrphanProjectLogs.detect(
            entries: [(apparentBytes: 100, path: path)], claimedSlugDirs: [])
        #expect(findings == [
            OrphanProjectLogs.Finding(
                detail: "/logs/myproj-abcd1234 (100 bytes) matches no registered project",
                path: path,
                remedy: "directa doctor --fix"),
        ])
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
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try Data(repeating: 0x41, count: 100).write(to: fixture.orphaned.appending(path: "current.log"))

        /** A stray plain file directly under the logs root (never a slug
            directory itself) must not be mistaken for one. */
        try Data().write(to: fixture.logsDir.appending(path: "stray.log"))

        let findings = OrphanProjectLogs.scan(paths: fixture.paths, claimedSlugDirs: ["claimed-1111"])

        #expect(findings.count == 1)
        #expect(findings[0].detail.hasPrefix(fixture.orphaned.path))
        #expect(findings[0].detail.contains("100 bytes"))
        #expect(findings[0].path == fixture.orphaned)
        #expect(findings[0].remedy == "directa doctor --fix")
    }

    /** A link is not a log directory directa created, and `--fix` refuses to
        remove one, so the report never names it as something `--fix` handles. */
    @Test func scanSkipsASymlinkEvenWhenItPointsAtADirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createSymbolicLink(
            at: fixture.logsDir.appending(path: "link-3333"), withDestinationURL: fixture.claimed)

        let findings = OrphanProjectLogs.scan(paths: fixture.paths, claimedSlugDirs: ["claimed-1111"])

        #expect(findings.map(\.path) == [fixture.orphaned])
    }

    @Test func scanAnswersEmptyForAMissingLogsDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "directa-orphanlogs-missing-\(UUID().uuidString)")
        let paths = DirectaPaths(dataDir: missing.appending(path: "data"), logsDir: missing)
        #expect(OrphanProjectLogs.scan(paths: paths, claimedSlugDirs: []).isEmpty)
    }

    /** `temporaryDirectory` is spelled under /var, a link to /private/var.
        The logs root keeps that spelling while the child arrives in its
        `realpath` form, so the two only match once both are resolved. */
    @Test func anUnclaimedDirectoryUnderAVarSpelledRootIsRemovedAndItsClaimedSiblingKept() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let realOrphan = try #require(realpath(fixture.orphaned.path, nil))
        defer { free(realOrphan) }
        let orphan = URL(fileURLWithPath: String(cString: realOrphan))
        try #require(orphan.path != fixture.orphaned.path)
        try Data(repeating: 0x41, count: 10).write(to: orphan.appending(path: "current.log"))

        #expect(
            OrphanProjectLogs.removalRefusal(
                of: orphan, logsDir: fixture.logsDir, claimedSlugDirs: ["claimed-1111"])
                == nil)
        let outcome = OrphanProjectLogs.remove(
            orphan, logsDir: fixture.logsDir, claimedSlugDirs: ["claimed-1111"])

        #expect(outcome == .removed)
        #expect(!FileManager.default.fileExists(atPath: fixture.orphaned.path))
        #expect(FileManager.default.fileExists(atPath: fixture.claimed.path))
    }

    /** `removeItem` on a link whose target is a claimed project's log
        directory must never reach that target. */
    @Test func aSymlinkToAClaimedSiblingIsRefusedAndItsTargetSurvives() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let link = fixture.logsDir.appending(path: "link-3333")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.claimed)
        try Data().write(to: fixture.claimed.appending(path: "current.log"))

        let outcome = OrphanProjectLogs.remove(
            link, logsDir: fixture.logsDir, claimedSlugDirs: ["claimed-1111"])

        #expect(outcome == .refused("it is a link to another location, not a log directory directa created"))
        #expect(FileManager.default.fileExists(atPath: fixture.claimed.appending(path: "current.log").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test func aClaimedSlugIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let outcome = OrphanProjectLogs.remove(
            fixture.claimed, logsDir: fixture.logsDir, claimedSlugDirs: ["claimed-1111"])

        #expect(outcome == .refused("a registered project claims it"))
        #expect(FileManager.default.fileExists(atPath: fixture.claimed.path))
    }

    @Test func aPlainFileUnderTheLogsRootIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let stray = fixture.logsDir.appending(path: "stray.log")
        try Data().write(to: stray)

        let outcome = OrphanProjectLogs.remove(stray, logsDir: fixture.logsDir, claimedSlugDirs: [])

        #expect(outcome == .refused("it is not a directory"))
        #expect(FileManager.default.fileExists(atPath: stray.path))
    }

    @Test func aDirectoryOutsideTheLogsRootIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outside = fixture.root.appending(path: "elsewhere/orphaned-4444")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let outcome = OrphanProjectLogs.remove(outside, logsDir: fixture.logsDir, claimedSlugDirs: [])

        #expect(outcome == .refused("it is not directly inside directa's logs folder \(fixture.logsDir.path)"))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    /** A child spelled through a link and `..` resolves lexically to a path
        inside the logs root while the kernel follows the link first and lands
        outside it; any `.` or `..` component is refused outright. */
    @Test func aPathWhoseDotDotEscapesThroughALinkIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let victim = fixture.root.appending(path: "elsewhere/orphaned-2222")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.logsDir.appending(path: "hop"),
            withDestinationURL: fixture.root.appending(path: "elsewhere/inner"))
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: "elsewhere/inner"), withIntermediateDirectories: true)
        let spelled = URL(fileURLWithPath: fixture.logsDir.path + "/hop/../orphaned-2222")

        let outcome = OrphanProjectLogs.remove(spelled, logsDir: fixture.logsDir, claimedSlugDirs: [])

        #expect(outcome == .refused("it is not directly inside directa's logs folder \(fixture.logsDir.path)"))
        #expect(FileManager.default.fileExists(atPath: victim.path))
        #expect(FileManager.default.fileExists(atPath: fixture.orphaned.path))
    }

    /** `<logs>-x` shares the logs root's spelling as a string prefix but is a
        sibling of it, not a child. */
    @Test func aSiblingWhoseNameExtendsTheLogsRootIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sibling = URL(fileURLWithPath: fixture.logsDir.path + "-x")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        let outcome = OrphanProjectLogs.remove(sibling, logsDir: fixture.logsDir, claimedSlugDirs: [])

        #expect(outcome == .refused("it is not directly inside directa's logs folder \(fixture.logsDir.path)"))
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }

    @Test func aDirectoryThatIsAlreadyGoneIsRefusedRatherThanReportedRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let gone = fixture.logsDir.appending(path: "gone-5555")

        let outcome = OrphanProjectLogs.remove(gone, logsDir: fixture.logsDir, claimedSlugDirs: [])

        #expect(outcome == .refused("it is no longer there"))
    }

    /** A logs root at `<tmp>/<uuid>/logs` holding `claimed-1111` and
        `orphaned-2222`, spelled through `temporaryDirectory` (under /var). */
    private struct Fixture {
        let claimed: URL
        let logsDir: URL
        let orphaned: URL
        let paths: DirectaPaths
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "directa-orphanlogs-\(UUID().uuidString)")
            logsDir = root.appending(path: "logs")
            claimed = logsDir.appending(path: "claimed-1111")
            orphaned = logsDir.appending(path: "orphaned-2222")
            paths = DirectaPaths(dataDir: root.appending(path: "data"), logsDir: logsDir)
            try FileManager.default.createDirectory(at: claimed, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: orphaned, withIntermediateDirectories: true)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
