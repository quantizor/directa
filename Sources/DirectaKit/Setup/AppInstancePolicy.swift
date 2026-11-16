import Foundation

/** One running copy of the menu bar app, reduced to what the stand-down decision
    reads. Built from `NSRunningApplication` by the app; kept free of AppKit here
    so the decision is testable. */
public struct AppInstance: Equatable, Sendable {
    public var bundlePath: String
    public var launchDate: Date?
    public var processIdentifier: Int32

    public init(bundlePath: String, launchDate: Date?, processIdentifier: Int32) {
        self.bundlePath = bundlePath
        self.launchDate = launchDate
        self.processIdentifier = processIdentifier
    }
}

/** Whether a launching copy of the app should quit because the same bundle is
    already running.

    Two copies at the same path is always wrong: each parks a status wait on the daemon, each
    draws a menu bar item, and each posts its own crash notification, so the user
    sees doubled everything. Nothing prevented it, and `open -n` (which is what
    `NSWorkspace.OpenConfiguration.createsNewApplicationInstance` asks for, and
    what the DMG handoff asks for by name) produces it on demand.

    Scoped to the bundle path rather than the bundle id on purpose: the DMG copy
    and the Applications copy share an id and must overlap for the length of the
    handoff, which is the one time two copies are correct. */
public enum AppInstancePolicy {
    /** True when `own` should quit and leave the field to an older twin. */
    public static func shouldStandDown(own: AppInstance, running: [AppInstance]) -> Bool {
        running.contains { peer in
            peer.processIdentifier != own.processIdentifier
                && peer.bundlePath == own.bundlePath
                && precedes(peer, own)
        }
    }

    /** A total order over copies, so two that launch together reach opposite
        answers and exactly one quits. Comparing launch dates alone is not enough:
        two copies launched in the same instant would each see the other as no
        older and both would stay, which is the bug, or both would leave, which is
        worse. The pid tiebreak is arbitrary but decides. */
    static func precedes(_ lhs: AppInstance, _ rhs: AppInstance) -> Bool {
        if let left = lhs.launchDate, let right = rhs.launchDate, left != right {
            return left < right
        }
        /** A copy whose launch date the system does not report sorts last, which
            both sides agree on because both read the same two values. */
        if lhs.launchDate == nil, rhs.launchDate != nil { return false }
        if lhs.launchDate != nil, rhs.launchDate == nil { return true }
        return lhs.processIdentifier < rhs.processIdentifier
    }
}
