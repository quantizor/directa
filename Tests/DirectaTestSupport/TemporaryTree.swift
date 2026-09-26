import Foundation
import Testing

/** The one home for a test's scratch directories. A suite or test carrying
    `.temporaryTree` gets a fresh directory per test case, and every
    `TemporaryTree.directory(named:)` or `TemporaryTree.path(named:)` call in
    that test lands inside it. The whole tree is removed when the test returns,
    throws, or records a failed expectation, so no test owns its own cleanup.

    The scope root sits under `DIRECTA_TEST_TEMP_ROOT` when that is set (make
    test points it at a per-run directory and fails the run if anything is left
    in it afterward), else under Foundation's user temp directory. On Darwin
    Foundation reads `confstr(_CS_DARWIN_USER_TEMP_DIR)` and ignores `TMPDIR`,
    which is why the per-run root is a variable of its own. Both spell the path
    under `/var`, the form a test comparing against `realpath` output expects.

    Asking for a directory outside the scope throws rather than falling back to
    an unmanaged location: a fallback is exactly how a suite leaks. */
public struct TemporaryTree: SuiteTrait, TestScoping, TestTrait {
    public static let rootVariable = "DIRECTA_TEST_TEMP_ROOT"

    @TaskLocal static var scope: URL?

    public var isRecursive: Bool { true }

    public init() {}

    /** A new, existing directory `named-<id>` inside the current test's tree. */
    public static func directory(named name: String) throws -> URL {
        let url = try path(named: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /** A unique path `named-<id>` inside the current test's tree that nothing
        has created, for a test about a missing file or directory. */
    public static func path(named name: String) throws -> URL {
        guard let scope else { throw TemporaryTreeError.outsideScope(name: name) }
        return scope.appending(path: "\(name)-\(UUID().uuidString.prefix(8))")
    }

    public static func baseDirectory() throws -> URL {
        guard let root = ProcessInfo.processInfo.environment[rootVariable], !root.isEmpty else {
            return FileManager.default.temporaryDirectory
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw TemporaryTreeError.missingRoot(path: root) }
        return URL(fileURLWithPath: root, isDirectory: true)
    }

    /** Runs `body` with a fresh tree in scope and removes the tree afterward,
        whatever `body` does. Public so a test of this type can drive a scope
        directly; suites use the trait. The tree's name carries `label` (the
        test's name under the trait), so a tree something rebuilt after its
        test returned names the test that owned it. */
    public static func withScope<Result: Sendable>(
        label: String = "scope", _ body: @Sendable (URL) async throws -> Result
    ) async throws -> Result {
        let readable = String(label.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(64))
        let root = try baseDirectory().appending(
            path: "directa-test-\(readable)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { remove(root) }
        return try await $scope.withValue(root) { try await body(root) }
    }

    /** Nil for the suite itself, so the tree is per test case and never shared
        between the cases of a suite that run in parallel. */
    public func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    public func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await Self.withScope(label: test.name) { _ in try await function() }
    }

    /** A test that took write permission off a directory or marked a file
        immutable makes a plain removal fail part way, so a failed removal
        clears both and tries once more. A removal that still fails is
        recorded as an issue: a quiet failure here is a leak. */
    static func remove(_ root: URL) {
        let manager = FileManager.default
        if (try? manager.removeItem(at: root)) != nil { return }
        if let walker = manager.enumerator(atPath: root.path) {
            for case let relative as String in walker {
                let path = root.appending(path: relative).path
                _ = chflags(path, 0)
                var isDirectory: ObjCBool = false
                if manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    _ = chmod(path, 0o700)
                }
            }
        }
        do {
            try manager.removeItem(at: root)
        } catch {
            Issue.record("could not remove the test's temporary tree at \(root.path): \(error)")
        }
    }
}

public enum TemporaryTreeError: Error, CustomStringConvertible {
    case missingRoot(path: String)
    case outsideScope(name: String)

    public var description: String {
        switch self {
        case .missingRoot(let path):
            "\(TemporaryTree.rootVariable) names \(path), which is not a directory; create it or unset the variable"
        case .outsideScope(let name):
            "TemporaryTree asked for \"\(name)\" outside a test scope; add .temporaryTree to the suite or test"
        }
    }
}

extension Trait where Self == TemporaryTree {
    /** Gives each test case its own scratch tree, removed when the case ends. */
    public static var temporaryTree: Self { TemporaryTree() }
}
