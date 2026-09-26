import DirectaKit
import Foundation
import Testing

@testable import directa

/** `GlobalOptions.resolveProject` against real git layouts: the
    devservers.json ancestor search stops at a linked worktree's root and
    crosses `.git` directories and submodule `.git` files. */
@Suite struct ProjectResolutionTests {
    private func makeBase() throws -> URL {
        let base = URL(fileURLWithPath: canonicalProjectPath(FileManager.default.temporaryDirectory.path))
            .appending(path: "directa-resolve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func directory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeConfig(in directory: URL) throws {
        try Data(#"{"servers":{"web":{"command":["bun","dev"]}},"version":1}"#.utf8)
            .write(to: directory.appending(path: "devservers.json"))
    }

    private func git(_ args: [String], in cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "protocol.file.allow=always",
        ] + args
        process.currentDirectoryURL = cwd
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(
            process.terminationStatus == 0, "git \(args.joined(separator: " ")) exited \(process.terminationStatus)")
    }

    private func repository(at url: URL) throws -> URL {
        let repo = try directory(url)
        try git(["init", "-q"], in: repo)
        try git(["commit", "-q", "--allow-empty", "-m", "seed"], in: repo)
        return repo
    }

    /** The Claude Code layout: the worktree sits inside the main checkout,
        whose devservers.json is untracked, so the worktree has none. */
    @Test func aLinkedWorktreeWithAnUntrackedMainCheckoutConfigResolvesToTheWorktree() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let main = try repository(at: base.appending(path: "main"))
        try writeConfig(in: main)
        let worktree = main.appending(path: ".claude/worktrees/review")
        try git(["worktree", "add", "-q", worktree.path], in: main)
        let deep = try directory(worktree.appending(path: "src/app"))
        #expect(GlobalOptions.resolveProject(from: deep.path) == worktree.path)
        #expect(GlobalOptions.resolveProject(from: worktree.path) == worktree.path)
    }

    @Test func aLinkedWorktreeWithItsOwnConfigInASubdirectoryResolvesToThatSubdirectory() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let main = try repository(at: base.appending(path: "main"))
        let worktree = base.appending(path: "review")
        try git(["worktree", "add", "-q", worktree.path], in: main)
        let app = try directory(worktree.appending(path: "apps/web"))
        try writeConfig(in: app)
        let deep = try directory(app.appending(path: "src"))
        #expect(GlobalOptions.resolveProject(from: deep.path) == app.path)
    }

    @Test func aSubmoduleUnderASuperprojectConfigResolvesToTheSuperproject() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try repository(at: base.appending(path: "sub-source"))
        let main = try repository(at: base.appending(path: "main"))
        try git(["submodule", "-q", "add", source.path, "libs/sub"], in: main)
        try writeConfig(in: main)
        let deep = try directory(main.appending(path: "libs/sub/src"))
        #expect(GlobalOptions.resolveProject(from: deep.path) == main.path)
    }

    /** One devservers.json above several sibling repositories, each with its
        own `.git` directory. */
    @Test func anUmbrellaConfigAboveSeveralRepositoriesStillApplies() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let umbrella = try directory(base.appending(path: "umbrella"))
        try writeConfig(in: umbrella)
        let api = try repository(at: umbrella.appending(path: "api"))
        _ = try repository(at: umbrella.appending(path: "web"))
        let deep = try directory(api.appending(path: "src"))
        #expect(GlobalOptions.resolveProject(from: deep.path) == umbrella.path)
    }

    @Test func aPlainSubdirectoryResolvesToTheNearestConfig() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let main = try repository(at: base.appending(path: "main"))
        try writeConfig(in: main)
        let deep = try directory(main.appending(path: "src/components"))
        #expect(GlobalOptions.resolveProject(from: deep.path) == main.path)
    }

    @Test func withoutAConfigTheGitRootWins() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let main = try repository(at: base.appending(path: "main"))
        let deep = try directory(main.appending(path: "src"))
        #expect(GlobalOptions.resolveProject(from: deep.path) == main.path)
    }

    @Test func withNoConfigAndNoGitTheWorkingDirectoryWins() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let deep = try directory(base.appending(path: "a/b"))
        #expect(GlobalOptions.resolveProject(from: deep.path) == deep.path)
    }
}
