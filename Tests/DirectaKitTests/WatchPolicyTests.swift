import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaKit

@Suite struct WatchPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_752_868_000)

    private func print(_ entries: [String: (UInt64, Double, UInt64)]) -> WatchFingerprint {
        WatchFingerprint(
            stamps: entries.mapValues {
                WatchStamp(inode: $0.0, modifiedAt: $0.1, size: $0.2)
            })
    }

    @Test func noChangeIsIdle() {
        let base = print(["/p/vite.config.ts": (1, 100, 10)])
        #expect(
            WatchPolicy.decide(
                baseline: base, now: start, observed: base, pending: nil, recentRestarts: [])
                == .idle)
    }

    /** One save touching three files must be one restart, not three. */
    @Test func aBurstOfEditsSettlesIntoASingleRestart() {
        let base = print([
            "/p/a.ts": (1, 100, 10), "/p/b.ts": (2, 100, 10), "/p/c.ts": (3, 100, 10),
        ])
        let first = print([
            "/p/a.ts": (1, 101, 11), "/p/b.ts": (2, 100, 10), "/p/c.ts": (3, 100, 10),
        ])
        #expect(
            WatchPolicy.decide(
                baseline: base, now: start, observed: first, pending: nil, recentRestarts: [])
                == .waiting(changed: ["/p/a.ts"]))
        let second = print([
            "/p/a.ts": (1, 101, 11), "/p/b.ts": (2, 101, 11), "/p/c.ts": (3, 101, 11),
        ])
        /** The fingerprint moved again, so the quiet window re-arms. */
        #expect(
            WatchPolicy.decide(
                baseline: base, now: start.addingTimeInterval(0.4), observed: second,
                pending: (at: start, stamp: first), recentRestarts: [])
                == .waiting(changed: ["/p/a.ts", "/p/b.ts", "/p/c.ts"]))
        /** Held still past the window, it fires once for all three. */
        #expect(
            WatchPolicy.decide(
                baseline: base, now: start.addingTimeInterval(2), observed: second,
                pending: (at: start.addingTimeInterval(0.4), stamp: second), recentRestarts: [])
                == .restart(changed: ["/p/a.ts", "/p/b.ts", "/p/c.ts"]))
    }

    @Test func aRevertInsideTheQuietWindowCancelsTheArmedRestart() {
        let base = print(["/p/a.ts": (1, 100, 10)])
        let edited = print(["/p/a.ts": (1, 101, 11)])
        #expect(
            WatchPolicy.decide(
                baseline: base, now: start.addingTimeInterval(5), observed: base,
                pending: (at: start, stamp: edited), recentRestarts: [])
                == .idle)
    }

    /** The atomic-replace case: write a temp file and rename it over the target,
        which is how nearly every editor saves. Same mtime second, same size, new
        inode; an mtime-only stamp would call this no change. */
    @Test func anAtomicReplaceWithIdenticalMtimeAndSizeIsAChange() {
        let base = print(["/p/a.ts": (1, 100, 10)])
        let replaced = print(["/p/a.ts": (2, 100, 10)])
        #expect(
            WatchPolicy.decide(
                baseline: base, now: start.addingTimeInterval(2), observed: replaced,
                pending: (at: start, stamp: replaced), recentRestarts: [])
                == .restart(changed: ["/p/a.ts"]))
    }

    @Test func aPathAppearingOrDisappearingIsAChange() {
        let absent = WatchFingerprint()
        let present = print(["/p/generated.json": (1, 100, 10)])
        #expect(
            WatchPolicy.decide(
                baseline: absent, now: start.addingTimeInterval(2), observed: present,
                pending: (at: start, stamp: present), recentRestarts: [])
                == .restart(changed: ["/p/generated.json"]))
        #expect(
            WatchPolicy.decide(
                baseline: present, now: start.addingTimeInterval(2), observed: absent,
                pending: (at: start, stamp: absent), recentRestarts: [])
                == .restart(changed: ["/p/generated.json"]))
    }

    @Test func aBurstOfRestartsSuspendsTheWatch() {
        let base = print(["/p/a.ts": (1, 100, 10)])
        let edited = print(["/p/a.ts": (1, 101, 11)])
        let restarts = [
            start.addingTimeInterval(-3), start.addingTimeInterval(-2), start.addingTimeInterval(-1),
        ]
        #expect(
            WatchPolicy.decide(
                baseline: base, now: start.addingTimeInterval(2), observed: edited,
                pending: (at: start, stamp: edited), recentRestarts: restarts)
                == .suspend(changed: ["/p/a.ts"]))
    }

    /** A long-lived server that restarted a few times over an afternoon is not
        oscillating, so the breaker only counts a recent window. */
    @Test func restartsOutsideTheWindowDoNotCountTowardTheBurst() {
        let base = print(["/p/a.ts": (1, 100, 10)])
        let edited = print(["/p/a.ts": (1, 101, 11)])
        let old = [
            start.addingTimeInterval(-300), start.addingTimeInterval(-200),
            start.addingTimeInterval(-100),
        ]
        #expect(
            WatchPolicy.decide(
                baseline: base, now: start.addingTimeInterval(2), observed: edited,
                pending: (at: start, stamp: edited), recentRestarts: old)
                == .restart(changed: ["/p/a.ts"]))
    }
}

@Suite(.temporaryTree) struct WatchPathsTests {
    @Test func relativeEntriesResolveAgainstTheProjectRoot() {
        let resolved = WatchPaths.resolve(entries: ["vite.config.ts"], project: "/Users/x/proj")
        #expect(resolved.paths == ["/Users/x/proj/vite.config.ts"])
        #expect(resolved.warnings.isEmpty)
    }

    @Test func globsAbsolutePathsAndEscapesAreDroppedWithAReason() {
        let resolved = WatchPaths.resolve(
            entries: ["**/*.ts", "/etc/hosts", "../outside.ts", ""], project: "/Users/x/proj")
        #expect(resolved.paths.isEmpty)
        #expect(resolved.warnings.count == 4)
        #expect(resolved.warnings.contains { $0.contains("looks like a glob") })
        #expect(resolved.warnings.contains { $0.contains("is absolute") })
        #expect(resolved.warnings.contains { $0.contains("points outside the project") })
        #expect(resolved.warnings.contains { $0.contains("is empty") })
    }

    @Test func duplicatesCollapseAndSort() {
        let resolved = WatchPaths.resolve(
            entries: ["b.ts", "a.ts", "b.ts"], project: "/Users/x/proj")
        #expect(resolved.paths == ["/Users/x/proj/a.ts", "/Users/x/proj/b.ts"])
    }

    @Test func aDirectoryIsDroppedWithAReason() throws {
        let dir = try TemporaryTree.directory(named: "watch")
        try FileManager.default.createDirectory(
            at: dir.appending(path: "sub"), withIntermediateDirectories: true)
        let resolved = WatchPaths.resolve(entries: ["sub"], project: dir.path)
        #expect(resolved.paths.isEmpty)
        #expect(resolved.warnings.contains { $0.contains("is a directory") })
    }

    /** A config a build step has not produced yet is legal, and its appearance
        is the change worth restarting for. */
    @Test func aPathThatDoesNotExistYetIsKept() {
        let resolved = WatchPaths.resolve(entries: ["generated.json"], project: "/Users/x/proj")
        #expect(resolved.paths == ["/Users/x/proj/generated.json"])
        #expect(resolved.warnings.isEmpty)
    }
}
