import Foundation

/** One watched path's identity as a stat can tell it. Inode is load-bearing: an
    atomic replace, which is how nearly every editor and build tool saves, can
    land the same mtime second and the same size, and an mtime-only fingerprint
    calls that no change. Never persisted, so the fingerprint is simply retaken
    at every spawn. */
public struct WatchStamp: Equatable, Sendable {
    public var inode: UInt64
    public var modifiedAt: Double
    public var size: UInt64

    public init(inode: UInt64, modifiedAt: Double, size: UInt64) {
        self.inode = inode
        self.modifiedAt = modifiedAt
        self.size = size
    }
}

/** Absolute path to stamp. An absent path is simply missing from the map, which
    is what makes a config a build step has not generated yet legal, and its
    appearance a change. */
public struct WatchFingerprint: Equatable, Sendable {
    public var stamps: [String: WatchStamp]

    public init(stamps: [String: WatchStamp] = [:]) {
        self.stamps = stamps
    }

    public static func take(paths: [String]) -> WatchFingerprint {
        var stamps: [String: WatchStamp] = [:]
        for path in paths {
            var info = stat()
            guard stat(path, &info) == 0 else { continue }
            stamps[path] = WatchStamp(
                inode: UInt64(info.st_ino),
                modifiedAt: Double(info.st_mtimespec.tv_sec)
                    + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000,
                size: UInt64(info.st_size))
        }
        return WatchFingerprint(stamps: stamps)
    }

    public func changed(from other: WatchFingerprint) -> [String] {
        var names = Set(stamps.keys)
        names.formUnion(other.stamps.keys)
        return names.filter { stamps[$0] != other.stamps[$0] }.sorted()
    }
}

/** Whether a watched change has settled enough to act on. Pure and clock-driven
    so the debounce is exercised without sleeping on a real timer. */
public enum WatchPolicy {
    /** "1" in the daemon's environment turns the watch sweep off for every
        server. */
    public static let disableEnvironmentKey = "DIRECTA_NO_WATCH"

    public struct Limits: Equatable, Sendable {
        /** Auto-restarts allowed inside `burstWindowSeconds` before the watch
            suspends itself. */
        public var burstLimit: Int
        public var burstWindowSeconds: Double
        /** How long the fingerprint must hold still before a restart fires, so
            one save touching several files is one restart. */
        public var quietSeconds: Double
        /** How long a run must be up before its baseline is taken, so a server
            that writes its own watched file during boot does not bounce itself. */
        public var settleSeconds: Double

        public init(
            burstLimit: Int = 3, burstWindowSeconds: Double = 60, quietSeconds: Double = 1,
            settleSeconds: Double = 2
        ) {
            self.burstLimit = burstLimit
            self.burstWindowSeconds = burstWindowSeconds
            self.quietSeconds = quietSeconds
            self.settleSeconds = settleSeconds
        }
    }

    public enum Decision: Equatable, Sendable {
        case idle
        case restart(changed: [String])
        /** Changing faster than a person saves, which usually means the server
            is writing its own watched file. directa cannot tell those apart, so
            it stops and says which paths keep moving rather than bouncing
            forever or quietly rate-limiting. */
        case suspend(changed: [String])
        case waiting(changed: [String])
    }

    public static func decide(
        baseline: WatchFingerprint,
        limits: Limits = Limits(),
        now: Date,
        observed: WatchFingerprint,
        pending: (at: Date, stamp: WatchFingerprint)?,
        recentRestarts: [Date]
    ) -> Decision {
        let changed = observed.changed(from: baseline)
        /** A revert back to the baseline cancels an armed restart: nothing the
            server would read differently, so nothing to bounce for. */
        guard !changed.isEmpty else { return .idle }
        let burst = recentRestarts.filter { now.timeIntervalSince($0) < limits.burstWindowSeconds }
        guard burst.count < limits.burstLimit else { return .suspend(changed: changed) }
        guard let pending, pending.stamp == observed else { return .waiting(changed: changed) }
        guard now.timeIntervalSince(pending.at) >= limits.quietSeconds else {
            return .waiting(changed: changed)
        }
        return .restart(changed: changed)
    }
}
