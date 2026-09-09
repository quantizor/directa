import Foundation
import Testing

@testable import DirectaKit

@Suite struct ResourceIdentityTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "directa-res-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func hash8IsUnchangedByTheHashHexRefactor() {
        /** Log directory names on disk derive from this prefix, so it is pinned:
            a change here moves every project's log path. */
        #expect(DirectaPaths.hash8("/Users/x/code/shop") == String(DirectaPaths.hashHex(Array("/Users/x/code/shop".utf8)).prefix(8)))
        #expect(DirectaPaths.hash8("").count == 8)
        #expect(DirectaPaths.hashHex([]).count == 64)
    }

    /** Literal digests, not a self-comparison. Every other assertion here would
        pass just as happily against a wrong-but-consistent hash, which would
        move every project's log directory on disk with nothing to say so. The
        first two are the FIPS 180-4 published vectors for "" and "abc", so this
        pins the implementation to standard SHA-256 rather than to whatever it
        currently emits. */
    @Test func hashHexMatchesPublishedSHA256Vectors() {
        #expect(
            DirectaPaths.hashHex([])
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(
            DirectaPaths.hashHex(Array("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        /** Longer than one 64-byte block and not block-aligned, so a padding or
            multi-chunk bug cannot hide behind the two short vectors. */
        #expect(
            DirectaPaths.hashHex(Array(String(repeating: "x", count: 100_000).utf8))
                == "d69e68988157833272305aaf21f453c800346e8a3640db6578e260215542e5d4")
        #expect(DirectaPaths.hash8("/Users/x/code/shop") == "b71a7735")
    }

    @Test func aContentChangeAtEqualSizeIsDetected() throws {
        let dir = try scratch()
        let file = dir.appending(path: "db.sqlite")
        try Data("aaaa".utf8).write(to: file)
        let before = ResourceFingerprint.capture(path: file.path)
        try Data("bbbb".utf8).write(to: file)
        let after = ResourceFingerprint.capture(path: file.path)
        #expect(before.bytes == after.bytes)
        #expect(ResourceFingerprint.compare(after: after, before: before) != .unchanged)
    }

    /** The incident's shape: the file is removed and recreated, so a content
        hash alone can call it unchanged while the open handle still wins. */
    @Test func replacingAFileWithIdenticalBytesIsDetected() throws {
        let dir = try scratch()
        let file = dir.appending(path: "db.sqlite")
        try Data("same".utf8).write(to: file)
        let before = ResourceFingerprint.capture(path: file.path)
        try FileManager.default.removeItem(at: file)
        try Data("same".utf8).write(to: file)
        let after = ResourceFingerprint.capture(path: file.path)
        #expect(before.digest == after.digest)
        #expect(ResourceFingerprint.compare(after: after, before: before) == .changed(.inode))
    }

    @Test func repeatedCaptureOfAnUnchangedDirectoryIsIdentical() throws {
        let dir = try scratch()
        for name in ["b.sqlite", "a.sqlite", "Z.sqlite", "é.sqlite"] {
            try Data(name.utf8).write(to: dir.appending(path: name))
        }
        let first = ResourceFingerprint.capture(path: dir.path)
        let second = ResourceFingerprint.capture(path: dir.path)
        #expect(first == second)
        #expect(ResourceFingerprint.compare(after: second, before: first) == .unchanged)
        #expect(first.kind == .directory)
        #expect(first.entryCount == 4)
    }

    @Test func directoryChangesOnAddRemoveAndModify() throws {
        let dir = try scratch()
        try Data("one".utf8).write(to: dir.appending(path: "a.sqlite"))
        let base = ResourceFingerprint.capture(path: dir.path)

        try Data("two".utf8).write(to: dir.appending(path: "b.sqlite"))
        let added = ResourceFingerprint.capture(path: dir.path)
        #expect(ResourceFingerprint.compare(after: added, before: base) != .unchanged)

        try Data("changed".utf8).write(to: dir.appending(path: "a.sqlite"))
        let modified = ResourceFingerprint.capture(path: dir.path)
        #expect(ResourceFingerprint.compare(after: modified, before: added) != .unchanged)

        try FileManager.default.removeItem(at: dir.appending(path: "b.sqlite"))
        let removed = ResourceFingerprint.capture(path: dir.path)
        #expect(ResourceFingerprint.compare(after: removed, before: modified) != .unchanged)
    }

    /** A d1 state directory is wiped and rebuilt, which is exactly the incident. */
    @Test func aRecreatedDirectoryIsDetectedEvenWithIdenticalContents() throws {
        let dir = try scratch()
        let state = dir.appending(path: "state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("rows".utf8).write(to: state.appending(path: "db.sqlite"))
        let before = ResourceFingerprint.capture(path: state.path)
        try FileManager.default.removeItem(at: state)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("rows".utf8).write(to: state.appending(path: "db.sqlite"))
        let after = ResourceFingerprint.capture(path: state.path)
        #expect(ResourceFingerprint.compare(after: after, before: before) == .changed(.inode))
    }

    /** Over the entry cap the manifest is clipped, and the clip has to fall in
        the same place every time. Sorting before clipping is what guarantees
        that; stopping the walk early would pick a different subset run to run,
        because the enumerator's order is unspecified. */
    @Test func anOverCapDirectoryIsClippedDeterministically() throws {
        let dir = try scratch()
        for index in 0..<(ResourceFingerprint.maxEntries + 50) {
            try Data("x".utf8)
                .write(to: dir.appending(path: String(format: "f%05d", index)))
        }
        let first = ResourceFingerprint.capture(path: dir.path)
        let second = ResourceFingerprint.capture(path: dir.path)
        #expect(first.truncated)
        #expect(first.exact == false)
        #expect(first.entryCount == ResourceFingerprint.maxEntries)
        #expect(first == second)
    }

    @Test func aChangeInsideACrowdedDirectoryIsStillNoticed() throws {
        /** Wrangler-shaped: hundreds of small sqlite files, well under the
            8 MiB / 4096-entry caps, with the edit in the middle of the sorted
            walk so a head-and-tail sample of the tree would miss it. */
        let dir = try scratch()
        for index in 0..<240 {
            try Data("body-\(index)".utf8)
                .write(to: dir.appending(path: String(format: "f%04d.sqlite", index)))
        }
        let before = ResourceFingerprint.capture(path: dir.path)
        #expect(before.exact)
        #expect(!before.truncated)
        #expect(before.entryCount == 240)
        /** Same byte length so the comparison cannot exit on size and skip the
            digest, which is the only signal a middle-of-tree rewrite has. */
        try Data("BODY-120".utf8)
            .write(to: dir.appending(path: "f0120.sqlite"))
        let after = ResourceFingerprint.capture(path: dir.path)
        #expect(after.bytes == before.bytes)
        #expect(ResourceFingerprint.compare(after: after, before: before) == .changed(.content))
    }

    @Test func aFilePastMaxDepthDoesNotChangeTheFingerprint() throws {
        let dir = try scratch()
        func nest(_ levels: Int) throws -> URL {
            var url = dir
            for index in 1...levels { url.append(path: "d\(index)") }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let shallow = try nest(3)
        let deep = try nest(8)
        try Data("kept".utf8).write(to: shallow.appending(path: "kept.sqlite"))
        let before = ResourceFingerprint.capture(path: dir.path)
        try Data("deep".utf8).write(to: deep.appending(path: "too-deep.sqlite"))
        #expect(
            ResourceFingerprint.compare(
                after: ResourceFingerprint.capture(path: dir.path), before: before) == .unchanged)
        try Data("sib".utf8).write(to: shallow.appending(path: "sibling.sqlite"))
        #expect(
            ResourceFingerprint.compare(
                after: ResourceFingerprint.capture(path: dir.path), before: before) != .unchanged)
    }

    @Test func missingThenPresentIsAppearedAndTheReverseIsDisappeared() throws {
        let dir = try scratch()
        let file = dir.appending(path: "later.sqlite")
        let absent = ResourceFingerprint.capture(path: file.path)
        #expect(absent.kind == .missing)
        try Data("x".utf8).write(to: file)
        let present = ResourceFingerprint.capture(path: file.path)
        #expect(ResourceFingerprint.compare(after: present, before: absent) == .appeared)
        #expect(ResourceFingerprint.compare(after: absent, before: present) == .disappeared)
        #expect(ResourceFingerprint.compare(after: absent, before: absent) == .unchanged)
    }

    @Test func aFileReplacedByADirectoryIsAKindChange() throws {
        let dir = try scratch()
        let target = dir.appending(path: "thing")
        try Data("x".utf8).write(to: target)
        let before = ResourceFingerprint.capture(path: target.path)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let after = ResourceFingerprint.capture(path: target.path)
        #expect(ResourceFingerprint.compare(after: after, before: before) == .changed(.kind))
    }

    /** Retargeting the link changes identity; editing what it points at does
        not, because the walk never follows it. */
    @Test func symlinksAreNotFollowed() throws {
        let dir = try scratch()
        let a = dir.appending(path: "a")
        let b = dir.appending(path: "b")
        try Data("one".utf8).write(to: a)
        try Data("two".utf8).write(to: b)
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        let before = ResourceFingerprint.capture(path: link.path)
        #expect(before.kind == .symlink)
        try Data("one-edited".utf8).write(to: a)
        #expect(ResourceFingerprint.compare(after: ResourceFingerprint.capture(path: link.path), before: before) == .unchanged)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b)
        #expect(ResourceFingerprint.compare(after: ResourceFingerprint.capture(path: link.path), before: before) != .unchanged)
    }

    /** The incident shape, at a size that used to be sampled rather than read: a
        middle-only rewrite holding size and mtime steady. Head-and-tail sampling
        called this pair identical, which is the worst possible answer from a
        check whose only job is noticing a change to a database. */
    @Test func aMiddleOnlyRewriteOfALargeFileIsCaughtAtEqualSizeAndMtime() throws {
        let dir = try scratch()
        let file = dir.appending(path: "big.sqlite")
        /** Comfortably past the 8 MiB cap that used to switch this file to
            head-and-tail sampling, and past any plausible read chunk, so the
            digest has to span many chunks to be right. */
        let size = (8 << 20) + 4096
        var bytes = Data(repeating: 0x41, count: size)
        try bytes.write(to: file)
        let before = ResourceFingerprint.capture(path: file.path)
        #expect(before.exact == true)

        let stamp = try #require(
            try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)

        bytes[size / 2] = 0x43
        try bytes.write(to: file)
        /** Restored so size, mtime, head, and tail all match the baseline and the
            content digest is the only thing left that can differ. */
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        let after = ResourceFingerprint.capture(path: file.path)

        #expect(after.bytes == before.bytes)
        #expect(after.exact == true)
        #expect(after.digest != before.digest)
        #expect(ResourceFingerprint.compare(after: after, before: before) == .changed(.content))
    }

    /** The streaming reader on its own, against a whole-buffer digest of the same
        bytes. A chunk-boundary bug would show here as a mismatch even though
        every fingerprint comparison above still agreed with itself. */
    @Test func streamedFileDigestMatchesTheWholeBufferDigest() throws {
        let dir = try scratch()
        let file = dir.appending(path: "spans-chunks.bin")
        /** Deliberately not a multiple of the 1 MiB chunk, so the last read is
            short and padding lands mid-chunk. */
        var bytes = Data(repeating: 0x00, count: (3 << 20) + 12345)
        for index in stride(from: 0, to: bytes.count, by: 997) { bytes[index] = UInt8(index % 251) }
        try bytes.write(to: file)
        #expect(DirectaPaths.hashHex(contentsOf: file.path) == DirectaPaths.hashHex(Array(bytes)))
    }

    /** An unreadable file must not borrow the digest of an empty read, which
        every other unreadable file would also have and which compares equal. */
    @Test func anUnreadableFileIsInexactRatherThanEmptyDigested() throws {
        #expect(DirectaPaths.hashHex(contentsOf: "/nonexistent/directa/never") == nil)
    }
}
