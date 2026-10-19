import Darwin
import DirectaKit
import DirectaTestSupport
import Foundation
import Testing

@testable import directa

/** `directa lock <resource> -- <cmd>` used to run `<cmd>` in the resolved
    project's root rather than the directory the caller actually stood in, so
    a relative file argument, or a tool that finds its own config by walking up
    from cwd, saw the wrong directory (a monorepo subpackage below the project
    root, or an explicit `--project` pointing elsewhere both diverge from cwd). */
@Suite(.temporaryTree) struct LockGuardedCommandTests {
    private func inScratchDir(_ body: (URL) throws -> Void) throws {
        try body(try TemporaryTree.directory(named: "lock-cwd"))
    }

    /** `getcwd(3)` (what `Process.currentDirectoryURL` and the child's own
        `pwd -P` both read from) reports the physical path with every symlink
        resolved, `/var` and `/tmp` included; `URL.resolvingSymlinksInPath()`
        deliberately leaves those two aliases alone, so it is the wrong tool
        for this comparison. `realpath(3)` matches `getcwd(3)` without
        mutating the test process's own working directory, which a parallel
        suite must not touch. */
    private func physicalPath(_ path: String) -> String {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /** The guarded command writes its own cwd to a marker file rather than
        stdout: `Lock.runGuardedCommand` inherits stdio, which a real lock run
        wants (the guarded command's output streams live), so capturing via a
        pipe here would change what is under test. */
    @Test func theGuardedCommandRunsInTheGivenDirectoryNotSomeOtherOne() throws {
        try inScratchDir { dir in
            let marker = dir.appending(path: "pwd.txt")
            let status = Lock.runGuardedCommand(
                ["/bin/sh", "-c", "pwd -P > '\(marker.path)'"], run: inheriting(cwd: dir.path))
            #expect(status == 0)
            let seen = try String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(seen == physicalPath(dir.path))
        }
    }

    private func inheriting(cwd: String) -> Lock.GuardedRun {
        Lock.GuardedRun(cwd: cwd, environment: ProcessInfo.processInfo.environment)
    }

    /** What a real child sees in `DIRECTA_LOCKS`, written to a marker file for
        the same reason as the cwd above. A key is the project's canonical
        path, so a project spelled through a symlink reads as the path the
        daemon keys its holds on. */
    private func locksSeenByChild(
        in dir: URL, inherited: String?, project: String, resource: String
    ) throws -> String {
        var base = ProcessInfo.processInfo.environment
        base[LockResource.environmentKey] = inherited
        let marker = dir.appending(path: "locks.txt")
        let status = Lock.runGuardedCommand(
            ["/bin/sh", "-c", "printenv DIRECTA_LOCKS > '\(marker.path)'"],
            run: Lock.GuardedRun(
                cwd: dir.path,
                environment: Lock.guardedEnvironment(
                    inherited: base, project: project, resource: resource)))
        #expect(status == 0)
        return try String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func theGuardedCommandSeesTheLockItIsHeldUnder() throws {
        try inScratchDir { dir in
            let seen = try locksSeenByChild(
                in: dir, inherited: nil, project: dir.path, resource: "d1")
            #expect(seen == "\(physicalPath(dir.path))::d1")
        }
    }

    /** A lock already held around this run stays listed ahead of the new one,
        and an inherited empty value adds no stray comma. */
    @Test func theLockIsAppendedToAnInheritedValue() throws {
        try inScratchDir { dir in
            let seen = try locksSeenByChild(
                in: dir, inherited: "/other/checkout::cache", project: dir.path, resource: "d1")
            #expect(seen == "/other/checkout::cache,\(physicalPath(dir.path))::d1")
            let fromEmpty = try locksSeenByChild(
                in: dir, inherited: "", project: dir.path, resource: "d1")
            #expect(fromEmpty == "\(physicalPath(dir.path))::d1")
        }
    }

    @Test func aSubdirectoryIsDistinctFromItsParent() throws {
        try inScratchDir { dir in
            let sub = dir.appending(path: "sub")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let marker = dir.appending(path: "pwd.txt")
            _ = Lock.runGuardedCommand(
                ["/bin/sh", "-c", "pwd -P > '\(marker.path)'"], run: inheriting(cwd: sub.path))
            let seen = try String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(seen == physicalPath(sub.path))
            #expect(seen != physicalPath(dir.path))
        }
    }

    /** `env` itself always exists, so a bad *command* argument is `env`'s own
        exit 127, never a `Process.run()` throw; a nonexistent *working
        directory* is what actually fails the spawn (Foundation refuses to
        chdir into it), which is the path `runGuardedCommand`'s catch reports. */
    @Test func aNonexistentWorkingDirectoryFailsTheSpawnAndReturnsOne() {
        let status = Lock.runGuardedCommand(
            ["true"], run: inheriting(cwd: "/no/such/directory/at/all"))
        #expect(status == 1)
    }
}
