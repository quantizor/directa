import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaKit

private struct Box: Codable, Equatable {
    var value: Int
}

@Suite(.temporaryTree) struct AtomicFileTests {
    private func tempURL() throws -> URL {
        try TemporaryTree.path(named: "atomicfile").appending(path: "store.json")
    }

    @Test func loadReturnsNilForAMissingFile() throws {
        #expect(try AtomicFile.load(Box.self, from: tempURL()) == nil)
    }

    @Test func loadDecodesAValidFile() throws {
        let url = try tempURL()
        try AtomicFile.write(Data(#"{"value":7}"#.utf8), to: url)
        #expect(try AtomicFile.load(Box.self, from: url) == Box(value: 7))
    }

    @Test func loadQuarantinesCorruptBytesAndReturnsNil() throws {
        let url = try tempURL()
        try AtomicFile.write(Data("not json at all".utf8), to: url)
        #expect(try AtomicFile.load(Box.self, from: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path)
        #expect(siblings.contains { $0.contains("corrupt") })
    }

    /** A file that exists but cannot be read as data (here a directory at the
        store path) must throw, so the daemon refuses to start rather than
        treating real data as absent and erasing it on the next write. */
    @Test func loadThrowsWhenTheStoreExistsButCannotBeRead() throws {
        let url = try tempURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            _ = try AtomicFile.load(Box.self, from: url)
        }
    }

    /** loadDefensively is the opposite contract: any failure, including the read
        failure above, collapses to nil. It is only safe where losing the value
        does no harm. */
    @Test func loadDefensivelySwallowsAReadFailure() throws {
        let url = try tempURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(AtomicFile.loadDefensively(Box.self, from: url) == nil)
    }
}
