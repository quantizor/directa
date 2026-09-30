import DirectaTestSupport
import Foundation
import Testing

private struct Planted: Error {}

@Suite struct TemporaryTreeTests {
    @Test func aReturningScopeRemovesItsWholeTree() async throws {
        let root = try await TemporaryTree.withScope { root in
            let nested = try TemporaryTree.directory(named: "nested")
            try Data("x".utf8).write(to: nested.appending(path: "file.txt"))
            #expect(nested.deletingLastPathComponent().path == root.path)
            return root
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func aThrowingScopeRemovesItsTreeAndRethrows() async throws {
        let seen = Locked<URL?>(nil)
        await #expect(throws: Planted.self) {
            try await TemporaryTree.withScope { root in
                seen.set(try TemporaryTree.directory(named: "thrown"))
                throw Planted()
            }
        }
        let dir = try #require(seen.get())
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().path))
    }

    @Test func aScopeWithAFailedExpectationStillRemovesItsTree() async throws {
        let root = try await TemporaryTree.withScope { root in
            _ = try TemporaryTree.directory(named: "failed")
            withKnownIssue { Issue.record("a failed expectation inside the scope") }
            return root
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func aReadOnlyDirectoryInsideTheTreeIsStillRemoved() async throws {
        let root = try await TemporaryTree.withScope { root in
            let locked = try TemporaryTree.directory(named: "locked")
            try Data("x".utf8).write(to: locked.appending(path: "file.txt"))
            #expect(chmod(locked.path, 0o500) == 0)
            return root
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func anImmutableFileInsideTheTreeIsStillRemoved() async throws {
        let root = try await TemporaryTree.withScope { root in
            let file = try TemporaryTree.directory(named: "flagged").appending(path: "state.json")
            try Data("{}".utf8).write(to: file)
            #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
            return root
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func askingOutsideAScopeThrowsAndNamesTheFix() {
        #expect(throws: TemporaryTreeError.self) { try TemporaryTree.directory(named: "stray") }
        #expect(
            TemporaryTreeError.outsideScope(name: "stray").description
                == #"TemporaryTree asked for "stray" outside a test scope; add .temporaryTree to the suite or test"#)
    }

    @Test(.temporaryTree) func theTraitGivesEachCallAFreshDirectoryUnderOneTestRoot() throws {
        let first = try TemporaryTree.directory(named: "a")
        let second = try TemporaryTree.directory(named: "a")
        let missing = try TemporaryTree.path(named: "absent")
        #expect(first != second)
        #expect(first.deletingLastPathComponent().path == second.deletingLastPathComponent().path)
        #expect(missing.deletingLastPathComponent().path == first.deletingLastPathComponent().path)
        #expect(
            first.deletingLastPathComponent().lastPathComponent
                .hasPrefix("directa-test-theTraitGivesEachCallAFreshDirectoryUnderOneTestRoot-"))
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    /** Every scratch directory a test makes goes through `TemporaryTree`, so
        none can outlive its test. This scans the test sources for the raw
        Foundation and libc temp-directory calls a new test would reach for. */
    @Test func noTestSourceCreatesTempDirectoriesOutsideTemporaryTree() throws {
        let testsRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        /** Split so this list does not match itself. */
        let banned = ["FileManager.default." + "temporaryDirectory", "NSTemporary" + "Directory()", "mkd" + "temp("]
        let walker = try #require(FileManager.default.enumerator(atPath: testsRoot.path))
        var offenders: [String] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            guard !relative.hasPrefix("DirectaTestSupport/") else { continue }
            let text = try String(contentsOf: testsRoot.appending(path: relative), encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where banned.contains(where: { line.contains($0) }) {
                offenders.append("\(relative):\(index + 1)")
            }
        }
        #expect(offenders == [], "use TemporaryTree.directory(named:) under a .temporaryTree suite instead")
    }
}

/** A tiny lock box so a `@Sendable` scope body can hand a value back out. */
private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.withLock { value } }

    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}
