import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaKit

@Suite(.temporaryTree) struct OrphanProjectLogsTests {
    @Test func aClaimedSlugDirIsNotAnOrphan() {
        #expect(!OrphanProjectLogs.isUnclaimedName("myproj-abcd1234", claimedSlugDirs: ["myproj-abcd1234"]))
        #expect(OrphanProjectLogs.isUnclaimedName("myproj-abcd1234", claimedSlugDirs: ["other-abcd1234"]))
    }

    @Test func anUnclaimedSlugDirIsAnOrphanNamingItsSize() {
        let findings = OrphanProjectLogs.detect(
            entries: [(apparentBytes: 100, path: URL(fileURLWithPath: "/logs/myproj-abcd1234"))])
        #expect(findings == [
            OrphanProjectLogs.Finding(detail: "/logs/myproj-abcd1234 (100 bytes) matches no registered project")
        ])
        #expect(OrphanProjectLogs.remedy == "directa doctor --fix")
    }

    /** A logs root shared with other apps (`ddirecta --logs-dir
        ~/Library/Logs`) holds folders directa never made; only the
        `<slug>-<hash8>` shape `projectLogDir` produces is ever reported. */
    @Test func onlyNamesWithTheProjectLogDirShapeAreCandidates() {
        let names = [
            "DiagnosticReports", "com.apple.xpc.launchd", "myproj-abcd123", "myproj-ABCD1234",
            "myproj-abcd12345", "My App-abcd1234", "-abcd1234", "web-app-0123abcd",
        ]
        #expect(
            names.filter { OrphanProjectLogs.isUnclaimedName($0, claimedSlugDirs: []) }
                == ["-abcd1234", "web-app-0123abcd"])
    }

    @Test func aProjectLogDirNameMatchesTheShapeItDeclares() {
        let paths = DirectaPaths(
            dataDir: URL(fileURLWithPath: "/data"), logsDir: URL(fileURLWithPath: "/logs"))
        for project in ["/Users/x/My App", "/Users/x/web.app", "/", "/Users/x/ünïcode"] {
            let name = paths.projectLogDir(project: project).lastPathComponent
            #expect(DirectaPaths.isProjectLogDirName(name), "\(name) from \(project)")
        }
    }

    @Test func scanFindsOnlyTheDirectoryNoProjectClaims() throws {
        let fixture = try Fixture()
        try Data(repeating: 0x41, count: 100).write(to: fixture.orphaned.appending(path: "current.log"))

        /** A stray plain file directly under the logs root (never a slug
            directory itself) must not be mistaken for one. */
        try Data().write(to: fixture.logsDir.appending(path: "stray.log"))

        let findings = OrphanProjectLogs.scan(paths: fixture.paths, claimedSlugDirs: [Fixture.claimedName])

        #expect(findings.map(\.detail) == ["\(fixture.orphaned.path) (100 bytes) matches no registered project"])
    }

    @Test func scanSkipsAnotherAppsFolderUnderASharedLogsRoot() throws {
        let fixture = try Fixture()
        let foreign = fixture.logsDir.appending(path: "DiagnosticReports")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)

        let findings = OrphanProjectLogs.scan(paths: fixture.paths, claimedSlugDirs: [Fixture.claimedName])

        #expect(findings.map(\.detail) == [fixture.orphanedDetail])
    }

    /** A link is not a log directory directa created, and `--fix` refuses to
        remove one, so the report never names it as something `--fix` handles. */
    @Test func scanSkipsASymlinkEvenWhenItPointsAtADirectory() throws {
        let fixture = try Fixture()
        try FileManager.default.createSymbolicLink(
            at: fixture.logsDir.appending(path: "link-33333333"), withDestinationURL: fixture.claimed)

        let findings = OrphanProjectLogs.scan(paths: fixture.paths, claimedSlugDirs: [Fixture.claimedName])

        #expect(findings.map(\.detail) == [fixture.orphanedDetail])
    }

    /** `unclaimedDirectories`, the listing `doctor --fix` removes from
        without sizing anything, names exactly the directories `scan` reports,
        in the same order. */
    @Test func unclaimedDirectoriesNameExactlyWhatScanReports() throws {
        let fixture = try Fixture()
        let second = fixture.logsDir.appending(path: "another-33333333")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 100).write(to: fixture.orphaned.appending(path: "current.log"))
        try Data().write(to: fixture.logsDir.appending(path: "stray.log"))
        try FileManager.default.createDirectory(
            at: fixture.logsDir.appending(path: "DiagnosticReports"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.logsDir.appending(path: "link-44444444"), withDestinationURL: fixture.claimed)

        let unclaimed = OrphanProjectLogs.unclaimedDirectories(
            paths: fixture.paths, claimedSlugDirs: [Fixture.claimedName])
        let scanned = OrphanProjectLogs.scan(paths: fixture.paths, claimedSlugDirs: [Fixture.claimedName])

        #expect(unclaimed == [second, fixture.orphaned])
        #expect(scanned.map(\.detail) == [
            "\(second.path) (Zero KB) matches no registered project",
            "\(fixture.orphaned.path) (100 bytes) matches no registered project",
        ])
    }

    @Test func scanAnswersEmptyForAMissingLogsDirectory() throws {
        let missing = try TemporaryTree.path(named: "orphanlogs-missing")
        let paths = DirectaPaths(dataDir: missing.appending(path: "data"), logsDir: missing)
        #expect(OrphanProjectLogs.scan(paths: paths, claimedSlugDirs: []).isEmpty)
    }

    /** `temporaryDirectory` is spelled under /var, a link to /private/var.
        The logs root keeps that spelling while the child arrives in its
        `realpath` form, so the two only match once both are resolved. */
    @Test func anUnclaimedDirectoryUnderAVarSpelledRootIsRemovedAndItsClaimedSiblingKept() throws {
        let fixture = try Fixture()
        let realOrphan = try #require(realpath(fixture.orphaned.path, nil))
        defer { free(realOrphan) }
        let orphan = URL(fileURLWithPath: String(cString: realOrphan))
        try #require(orphan.path != fixture.orphaned.path)
        try Data(repeating: 0x41, count: 10).write(to: orphan.appending(path: "current.log"))

        #expect(
            OrphanProjectLogs.removalRefusal(
                of: orphan, logsDir: fixture.logsDir, claimedSlugDirs: [Fixture.claimedName])
                == nil)
        let outcome = OrphanProjectLogs.remove(
            orphan, logsDir: fixture.logsDir, claimedSlugDirs: [Fixture.claimedName])

        #expect(outcome == .removed)
        #expect(!FileManager.default.fileExists(atPath: fixture.orphaned.path))
        #expect(FileManager.default.fileExists(atPath: fixture.claimed.path))
    }

    /** Another app's unclaimed folder under a shared logs root is exactly
        what the location and claim checks alone would delete. */
    @Test func anotherAppsFolderUnderASharedLogsRootIsRefused() throws {
        let fixture = try Fixture()
        let foreign = fixture.logsDir.appending(path: "DiagnosticReports")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)

        let outcome = OrphanProjectLogs.remove(foreign, logsDir: fixture.logsDir, claimedSlugDirs: [])

        #expect(outcome == .refused(.notADirectaName))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    /** `removeItem` on a link whose target is a claimed project's log
        directory must never reach that target. */
    @Test func aSymlinkToAClaimedSiblingIsRefusedAndItsTargetSurvives() throws {
        let fixture = try Fixture()
        let link = fixture.logsDir.appending(path: "link-33333333")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.claimed)
        try Data().write(to: fixture.claimed.appending(path: "current.log"))

        let outcome = OrphanProjectLogs.remove(
            link, logsDir: fixture.logsDir, claimedSlugDirs: [Fixture.claimedName])

        #expect(outcome == .refused(.link))
        #expect(FileManager.default.fileExists(atPath: fixture.claimed.appending(path: "current.log").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test func aClaimedSlugIsRefused() throws {
        let fixture = try Fixture()

        let outcome = OrphanProjectLogs.remove(
            fixture.claimed, logsDir: fixture.logsDir, claimedSlugDirs: [Fixture.claimedName])

        #expect(outcome == .refused(.claimed))
        #expect(FileManager.default.fileExists(atPath: fixture.claimed.path))
    }

    @Test func aPlainFileUnderTheLogsRootIsRefused() throws {
        let fixture = try Fixture()
        let stray = fixture.logsDir.appending(path: "stray.log")
        try Data().write(to: stray)

        let outcome = OrphanProjectLogs.remove(stray, logsDir: fixture.logsDir, claimedSlugDirs: [])

        #expect(outcome == .refused(.notADirectory))
        #expect(FileManager.default.fileExists(atPath: stray.path))
    }

    @Test func aDirectoryOutsideTheLogsRootIsRefused() throws {
        let fixture = try Fixture()
        let outside = fixture.root.appending(path: "elsewhere/orphaned-44444444")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let outcome = OrphanProjectLogs.remove(outside, logsDir: fixture.logsDir, claimedSlugDirs: [])

        #expect(outcome == .refused(.outsideLogsRoot(fixture.logsDir.path)))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    /** A child spelled through a link and `..` resolves lexically to a path
        inside the logs root while the kernel follows the link first and lands
        outside it; any `.` or `..` component is refused outright. */
    @Test func aPathWhoseDotDotEscapesThroughALinkIsRefused() throws {
        let fixture = try Fixture()
        let victim = fixture.root.appending(path: "elsewhere/\(Fixture.orphanedName)")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.logsDir.appending(path: "hop"),
            withDestinationURL: fixture.root.appending(path: "elsewhere/inner"))
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: "elsewhere/inner"), withIntermediateDirectories: true)
        let spelled = URL(fileURLWithPath: fixture.logsDir.path + "/hop/../\(Fixture.orphanedName)")

        let outcome = OrphanProjectLogs.remove(spelled, logsDir: fixture.logsDir, claimedSlugDirs: [])

        #expect(outcome == .refused(.outsideLogsRoot(fixture.logsDir.path)))
        #expect(FileManager.default.fileExists(atPath: victim.path))
        #expect(FileManager.default.fileExists(atPath: fixture.orphaned.path))
    }

    /** `<logs>-x` shares the logs root's spelling as a string prefix but is a
        sibling of it, not a child. */
    @Test func aSiblingWhoseNameExtendsTheLogsRootIsRefused() throws {
        let fixture = try Fixture()
        let sibling = URL(fileURLWithPath: fixture.logsDir.path + "-x")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        let outcome = OrphanProjectLogs.remove(sibling, logsDir: fixture.logsDir, claimedSlugDirs: [])

        #expect(outcome == .refused(.outsideLogsRoot(fixture.logsDir.path)))
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }

    @Test func aDirectoryThatIsAlreadyGoneIsRefusedRatherThanReportedRemoved() throws {
        let fixture = try Fixture()
        let gone = fixture.logsDir.appending(path: "gone-55555555")

        let outcome = OrphanProjectLogs.remove(gone, logsDir: fixture.logsDir, claimedSlugDirs: [])

        #expect(outcome == .refused(.gone))
    }

    /** Every refusal's words, and a next step only where a person has one,
        never a deletion command. */
    @Test func eachRefusalNamesItsReasonAndRemedy() {
        let refusals: [OrphanProjectLogs.Refusal] = [
            .claimed, .gone, .link, .notADirectory, .notADirectaName, .outsideLogsRoot("/logs"),
        ]
        #expect(refusals.map(\.reason) == [
            "a registered project claims it",
            "it is no longer there",
            "it is a link to another location, not a log directory directa created",
            "it is not a directory",
            "its name is not one directa gives a log directory, so directa did not create it",
            "it is not directly inside directa's logs folder /logs",
        ])
        #expect(refusals.map(\.remedy) == [
            nil,
            nil,
            "remove the link yourself if nothing needs it",
            "move or remove it yourself if nothing needs it",
            "move or remove it yourself if nothing needs it",
            nil,
        ])
    }

    /** A logs root at `<test tree>/orphanlogs-<id>/logs` holding `claimedName`
        and `orphanedName`, spelled under /var the way the temp directory is. */
    private struct Fixture {
        static let claimedName = "claimed-11111111"
        static let orphanedName = "orphaned-22222222"

        let claimed: URL
        let logsDir: URL
        let orphaned: URL
        let paths: DirectaPaths
        let root: URL

        /** What `scan` reports for the empty `orphaned` directory. */
        var orphanedDetail: String {
            "\(orphaned.path) (Zero KB) matches no registered project"
        }

        init() throws {
            root = try TemporaryTree.directory(named: "orphanlogs")
            logsDir = root.appending(path: "logs")
            claimed = logsDir.appending(path: Self.claimedName)
            orphaned = logsDir.appending(path: Self.orphanedName)
            paths = DirectaPaths(dataDir: root.appending(path: "data"), logsDir: logsDir)
            try FileManager.default.createDirectory(at: claimed, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: orphaned, withIntermediateDirectories: true)
        }
    }
}
