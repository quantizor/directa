import Foundation

/** Where the daemon is allowed to run its own executable image from.

    A DMG shares the installed app's bundle id (dev.quantizor.directa.app), so when
    the volume is mounted Launch Services can resolve the SMAppService agent to the
    volume copy and spawn the daemon from `/Volumes/directa/...` even though the BTM
    registration URL points at `/Applications`. The running image then pins the
    volume: the user cannot eject ("disk in use") until the daemon happens to
    cycle. The daemon must never keep running from a mounted volume; on boot it
    re-execs the canonical installed binary instead, so its process image is always
    on the boot volume regardless of how launchd resolved the spawn. */
public enum DaemonImagePolicy {
    /** Set to "1" in the environment of a daemon re-exec'd off a mounted
        volume: the sentinel `decide`'s `alreadyReexeced` reads. */
    public static let reexecEnvironmentKey = "DIRECTA_DAEMON_REEXECED"

    public enum Decision: Equatable, Sendable {
        /** The current image is on the boot volume (or nothing better exists);
            proceed here. */
        case runHere
        /** The current image is on a mounted volume; re-exec this absolute path,
            which is a canonical install location on the boot volume. */
        case reexec(path: String)
    }

    /** True for a path on a mounted volume (a DMG or external disk under
        `/Volumes`), never the boot volume where `/Applications` and a user's home
        live. `/Volumes` itself and any child count; a sibling like
        `/VolumesData` does not. */
    public static func isUnderMountedVolume(_ path: String) -> Bool {
        path == "/Volumes" || path.hasPrefix("/Volumes/")
    }

    /** Decide whether the running daemon should re-exec a canonical binary.

        `candidates` are canonical install locations, boot-volume paths, in
        preference order (the installed app's helper, then the legacy home CLI
        dir). `alreadyReexeced` reflects the re-exec sentinel and breaks any loop:
        a re-exec always targets a non-volume path, so the child takes `runHere`,
        but the guard makes that impossible to get wrong. When the image is on a
        volume yet no canonical binary exists elsewhere, running in place is the
        last resort, since exiting under KeepAlive would just respawn the same
        volume image in a tight loop. */
    public static func decide(
        currentExecutable: String,
        candidates: [String],
        alreadyReexeced: Bool,
        fileExists: (String) -> Bool
    ) -> Decision {
        guard !alreadyReexeced else { return .runHere }
        guard isUnderMountedVolume(currentExecutable) else { return .runHere }
        for candidate in candidates
        where !isUnderMountedVolume(candidate) && fileExists(candidate) {
            return .reexec(path: candidate)
        }
        return .runHere
    }
}
