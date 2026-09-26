import Foundation
import Testing

@testable import DirectaKit

/** Declared-port collisions across projects. The host-keyed signature check in
    doctor cannot see these: two servers advertising myproj.localhost:3010 and
    otherproj.localhost:3010 are different signatures and the same bind. */
struct PortCollisionTests {
    private func status(
        effective: Int? = nil, host: String, port: Int?, project: String, server: String
    ) -> ServerStatus {
        ServerStatus(
            declaredPort: port,
            effectivePort: effective ?? port,
            logPath: "/tmp/\(server).log",
            phase: .stopped,
            project: project,
            server: server,
            url: port.map { "http://\(host):\($0)/" })
    }

    /** `declaredPort` is the committed port before override or rebind, so two
        projects can share it while binding different ports. Reporting that as a
        collision is a false alarm, and a warning that cries wolf gets ignored. */
    @Test func aLocalOverrideAwayFromTheSharedPortIsNotACollision() {
        let pairs = PortCollision.detect([
            status(effective: 3999, host: "a.localhost", port: 3010, project: "/code/a", server: "a"),
            status(host: "b.localhost", port: 3010, project: "/code/b", server: "b"),
        ])
        #expect(pairs.isEmpty)
    }

    /** The mirror case: different committed ports, both overridden onto one
        port, really do collide. */
    @Test func overridesOntoOnePortCollide() {
        let pairs = PortCollision.detect([
            status(effective: 7000, host: "a.localhost", port: 3010, project: "/code/a", server: "a"),
            status(effective: 7000, host: "b.localhost", port: 3020, project: "/code/b", server: "b"),
        ])
        #expect(pairs.count == 1)
        #expect(pairs.first?.port == 7000)
    }

    @Test func differentHostsOnOnePortCollide() {
        let pairs = PortCollision.detect([
            status(host: "myproj.localhost", port: 3010, project: "/code/myproj", server: "web"),
            status(host: "otherproj.localhost", port: 3010, project: "/code/otherproj", server: "sandbox"),
        ])
        #expect(pairs.count == 1)
        let pair = pairs.first
        #expect(pair?.port == 3010)
        #expect(pair?.detail.contains("/code/myproj") == true)
        #expect(pair?.detail.contains("/code/otherproj") == true)
    }

    @Test func distinctPortsDoNotCollide() {
        let pairs = PortCollision.detect([
            status(host: "myproj.localhost", port: 3010, project: "/code/myproj", server: "web"),
            status(host: "otherproj.localhost", port: 3011, project: "/code/otherproj", server: "sandbox"),
        ])
        #expect(pairs.isEmpty)
    }

    @Test func serversWithoutADeclaredPortAreIgnored() {
        let pairs = PortCollision.detect([
            status(host: "a.localhost", port: nil, project: "/code/a", server: "worker"),
            status(host: "b.localhost", port: nil, project: "/code/b", server: "worker"),
        ])
        #expect(pairs.isEmpty)
    }

    /** Two servers in one project share a host, so the existing signature check
        already reports them; a second finding would be noise. */
    @Test func sameProjectIsLeftToTheSignatureCheck() {
        let pairs = PortCollision.detect([
            status(host: "app.localhost", port: 4000, project: "/code/app", server: "web"),
            status(host: "app.localhost", port: 4000, project: "/code/app", server: "api"),
        ])
        #expect(pairs.isEmpty)
    }

    /** Three unrelated projects on one port report against the first holder
        rather than every unordered pair, so the output stays readable. */
    @Test func threeHoldersReportAgainstOneOwner() {
        let pairs = PortCollision.detect([
            status(host: "a.localhost", port: 5000, project: "/code/a", server: "a"),
            status(host: "b.localhost", port: 5000, project: "/code/b", server: "b"),
            status(host: "c.localhost", port: 5000, project: "/code/c", server: "c"),
        ])
        #expect(pairs.count == 2)
        #expect(pairs.allSatisfy { $0.first == "a (/code/a)" })
    }
}

/** Sibling worktrees share a committed port deliberately and rebind on ensure,
    so a collision between them is the design working, not a fault. Needs real
    git checkouts because the exclusion asks git for the common dir. */
@Suite(.serialized) struct PortCollisionSiblingTests {
    @Test func siblingWorktreesAreNotReported() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "directa-collide-\(UUID().uuidString)")
        let main = base.appending(path: "main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        /** Fail at the callsite that broke. A git command that quietly exits
            nonzero (no git, no worktree support, a permissions problem) otherwise
            surfaces as a confusing assertion several lines later. */
        func run(_ args: [String], cwd: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = cwd
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(
                process.terminationStatus == 0,
                "git \(args.joined(separator: " ")) exited \(process.terminationStatus)")
        }
        try run(["init", "-q"], cwd: main)
        try run(["config", "user.email", "t@example.com"], cwd: main)
        try run(["config", "user.name", "t"], cwd: main)
        try Data("x".utf8).write(to: main.appending(path: "file.txt"))
        try run(["add", "."], cwd: main)
        try run(["commit", "-qm", "seed"], cwd: main)
        let linked = base.appending(path: "linked")
        try run(["worktree", "add", "-q", linked.path], cwd: main)

        /** Control: the two paths really are siblings, so the exclusion below is
            exercised rather than passing because git said no to everything. */
        #expect(CheckoutIdentity.shareCommonDir(main.path, linked.path))

        let pairs = PortCollision.detect([
            ServerStatus(
                declaredPort: 6000, logPath: "/tmp/a.log", phase: .stopped, project: main.path,
                server: "web"),
            ServerStatus(
                declaredPort: 6000, logPath: "/tmp/b.log", phase: .stopped, project: linked.path,
                server: "web"),
        ])
        #expect(pairs.isEmpty)
    }
}
