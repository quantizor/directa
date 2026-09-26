import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaKit

/** A server name comes from a repo's committed devservers.json, so it reaches
    the log path as attacker-supplied text. `URL.appending(path:)` keeps `..` and
    `/` verbatim and the kernel resolves them at `createDirectory` and `open`, so
    an unsanitized name let a config choose where the daemon wrote raw child
    output. */
@Suite struct ServerPathComponentTests {
    @Test func anOrdinaryNameIsUntouched() {
        #expect(DirectaPaths.serverPathComponent("web") == "web")
        #expect(DirectaPaths.serverPathComponent("api-v2_3") == "api-v2_3")
    }

    @Test(arguments: [
        "../../../etc", "a/b", "/absolute", "..", ".", "", "with:colon",
    ])
    func nothingEscapesItsDirectory(name: String) {
        let component = DirectaPaths.serverPathComponent(name)
        #expect(!component.contains("/"))
        #expect(component != "." && component != "..")
        #expect(!component.isEmpty)
    }

    /** The proof that matters is about the filesystem, not the string: resolving
        the built URL must stay under the logs directory. */
    @Test(.temporaryTree) func aTraversingNameStaysUnderTheLogsDirectory() throws {
        let base = try TemporaryTree.path(named: "paths")
        let paths = DirectaPaths(
            dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs"))
        let dir = paths.serverLogDir(
            project: "/tmp/proj", server: "../../../../directa-escape-probe")
        let resolved = URL(fileURLWithPath: dir.path).standardizedFileURL.path
        let root = URL(fileURLWithPath: paths.logsDir.path).standardizedFileURL.path
        #expect(resolved.hasPrefix(root + "/"), "escaped to \(resolved)")
    }

    /** Two names that flatten to the same text must not share a log directory,
        or one server's output lands in another's file.

        The pairs matter: `.` against `..` proves nothing here, because those two
        do not flatten to the same text and take the dot-only branch anyway. Each
        pair below genuinely collides after separator replacement, which is the
        property the name claims. */
    @Test(arguments: [
        ("a/b", "a_b"),
        ("x:y", "x_y"),
        ("p/q", "p:q"),
        ("../x", ".._x"),
    ])
    func namesThatFlattenAlikeStayApart(first: String, second: String) {
        #expect(
            DirectaPaths.serverPathComponent(first)
                != DirectaPaths.serverPathComponent(second))
    }

    /** The dot-only cases keep their own branch, and still have to differ. */
    @Test func dotOnlyNamesStayApart() {
        #expect(
            DirectaPaths.serverPathComponent(".")
                != DirectaPaths.serverPathComponent(".."))
    }

    /** The control. Without it the collision tests above pass just as well
        against an implementation that hashes every name, which would make every
        log directory unreadable. */
    @Test(arguments: ["web", "api-2", "worker_3"])
    func anOrdinaryNameIsItsOwnDirectory(name: String) {
        #expect(DirectaPaths.serverPathComponent(name) == name)
    }
}
