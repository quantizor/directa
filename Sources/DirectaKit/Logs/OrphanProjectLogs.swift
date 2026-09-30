import Foundation

/** Slug directories under the logs root (`~/Library/Logs/directa/<slug>-<hash8>`)
    that match no project the daemon claims. `ControlServer` removes a
    project's log directory when it forgets the project (an explicit unregister
    down to zero servers, the missing-project sweep); a directory orphaned any
    other way stays until `directa doctor --fix`, whose `logs.removeOrphan`
    request has the daemon run `remove` on each one while it holds its claim
    set, or `directa uninstall --purge`, which removes the whole logs tree.

    `isUnclaimedName` and `detect` are pure so they are unit-testable;
    `unclaimedDirectories` and `scan` read the disk for `directa doctor`. */
public enum OrphanProjectLogs {
    /** A slug directory with no project left to claim it. */
    public struct Finding: Equatable, Sendable {
        /** What is wrong, in plain terms a non-engineer can read, including the
            directory's apparent size. `OrphanProjectLogs.remedy` removes it. */
        public let detail: String

        public init(detail: String) {
            self.detail = detail
        }
    }

    /** What `remove` did with one directory. */
    public enum Removal: Equatable, Sendable {
        /** `removeItem` threw; the payload is its message. */
        case failed(String)
        /** A safety check left the path in place. */
        case refused(Refusal)
        case removed
    }

    /** Why `removalRefusal` left a path in place. */
    public enum Refusal: Equatable, Sendable {
        case claimed
        case gone
        case link
        case notADirectory
        case notADirectaName
        /** The payload is the logs root the path should have been directly
            inside. */
        case outsideLogsRoot(String)

        /** Plain words for why the path was left alone. */
        public var reason: String {
            switch self {
            case .claimed: "a registered project claims it"
            case .gone: "it is no longer there"
            case .link: "it is a link to another location, not a log directory directa created"
            case .notADirectory: "it is not a directory"
            case .notADirectaName: "its name is not one directa gives a log directory, so directa did not create it"
            case .outsideLogsRoot(let logsDir): "it is not directly inside directa's logs folder \(logsDir)"
            }
        }

        /** What a person can do about it, or nil when nothing is left to do.
            Never a deletion command: whatever is removed by hand is the
            reader's own call. */
        public var remedy: String? {
            switch self {
            case .claimed, .gone, .outsideLogsRoot: nil
            case .link: "remove the link yourself if nothing needs it"
            case .notADirectory, .notADirectaName: "move or remove it yourself if nothing needs it"
            }
        }
    }

    /** The literal command that removes every reported directory. */
    public static let remedy = "directa doctor --fix"

    /** Whether a name listed directly under the logs root is an unclaimed
        project log directory. `claimedSlugDirs` is
        `DirectaPaths.projectLogDirNames(projects:)` over every project the
        daemon claims; a name not in that set has no project left to speak for
        it. A name without the `DirectaPaths.isProjectLogDirName` shape is
        never one: directa did not create it, and `remove` refuses it. */
    public static func isUnclaimedName(_ name: String, claimedSlugDirs: Set<String>) -> Bool {
        DirectaPaths.isProjectLogDirName(name) && !claimedSlugDirs.contains(name)
    }

    /** One finding per unclaimed directory, in the order given, each naming
        its apparent size in bytes (never a block-allocation size: a
        cloud-synced or lazily-materialized tree can report zero allocated
        blocks for a fully intact file, which would misreport a real orphan as
        empty). */
    public static func detect(entries: [(apparentBytes: Int64, path: URL)]) -> [Finding] {
        entries.map { entry in
            Finding(
                detail: "\(entry.path.path) (\(formatBytes(entry.apparentBytes))) matches no registered project")
        }
    }

    /** The unclaimed directories directly under the logs root, sorted by
        path, with nothing sized: what `doctor --fix` removes from, since a
        removal needs no size and walking every file would widen the window
        between its claimed-set re-read and the removal. A symbolic link is
        skipped even when it points at a directory: directa never creates one
        here, `remove` refuses it, and sizing it would count whatever the link
        points at. A name `isUnclaimedName` rejects is skipped, so a logs root
        shared with other apps never has their trees walked. */
    public static func unclaimedDirectories(
        paths: DirectaPaths, claimedSlugDirs: Set<String>, fileManager: FileManager = .default
    ) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: paths.logsDir.path) else {
            return []
        }
        return names
            .filter { isUnclaimedName($0, claimedSlugDirs: claimedSlugDirs) }
            .map { paths.logsDir.appending(path: $0) }
            .filter { fileType(at: $0) == S_IFDIR }
            .sorted { $0.path < $1.path }
    }

    /** `unclaimedDirectories` with each one sized, as findings. */
    public static func scan(
        paths: DirectaPaths, claimedSlugDirs: Set<String>, fileManager: FileManager = .default
    ) -> [Finding] {
        detect(
            entries: unclaimedDirectories(
                paths: paths, claimedSlugDirs: claimedSlugDirs, fileManager: fileManager
            ).map { (apparentBytes: apparentSize(of: $0, fileManager: fileManager), path: $0) })
    }

    /** Nil when `directory` is safe to delete as a leftover log directory,
        else why it is not. Safe means all of: every path
        component is a real name (a `.` or `..` is resolved lexically by
        `resolvingSymlinksInPath` but physically by the kernel after following
        links, so the two could name different directories); its resolved
        parent is exactly the resolved logs root (both sides resolved, since
        /var and /tmp are links to /private/var and /private/tmp and either
        spelling can arrive); the path itself, read without following links,
        is a directory and not a symbolic link (deleting through a link would
        delete its target, which could be a claimed project's logs); its name
        has the `DirectaPaths.isProjectLogDirName` shape (a logs root shared
        with other apps holds folders directa never made); and its name is no
        claimed slug. */
    public static func removalRefusal(
        of directory: URL, logsDir: URL, claimedSlugDirs: Set<String>
    ) -> Refusal? {
        let outsideRoot = Refusal.outsideLogsRoot(logsDir.path)
        if directory.pathComponents.contains(where: { $0 == "." || $0 == ".." }) {
            return outsideRoot
        }
        let resolvedRoot = trimmedPath(logsDir.resolvingSymlinksInPath())
        let resolvedParent = trimmedPath(
            directory.resolvingSymlinksInPath().deletingLastPathComponent())
        guard resolvedParent == resolvedRoot else { return outsideRoot }
        switch fileType(at: directory) {
        case nil:
            return .gone
        case S_IFLNK:
            return .link
        case S_IFDIR:
            break
        default:
            return .notADirectory
        }
        let name = directory.lastPathComponent
        guard DirectaPaths.isProjectLogDirName(name) else { return .notADirectaName }
        if claimedSlugDirs.contains(name) {
            return .claimed
        }
        return nil
    }

    /** Deletes one leftover log directory after `removalRefusal` clears it.
        `removeItem` gets `directory` as given, never its resolved form, so the
        path the checks read is the path that is deleted. */
    public static func remove(
        _ directory: URL, logsDir: URL, claimedSlugDirs: Set<String>,
        fileManager: FileManager = .default
    ) -> Removal {
        if let refusal = removalRefusal(of: directory, logsDir: logsDir, claimedSlugDirs: claimedSlugDirs) {
            return .refused(refusal)
        }
        do {
            try fileManager.removeItem(at: directory)
            return .removed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /** The file type bits of `url` read with `lstat`, so a symbolic link
        reports itself rather than its target; nil when nothing is there. */
    private static func fileType(at url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    private static func trimmedPath(_ url: URL) -> String {
        let path = url.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /** Sum of logical file sizes (`.fileSizeKey`) under `dir`, not on-disk
        block usage: `du`-style block accounting reports zero for an intact but
        evicted iCloud/OneDrive placeholder, which would call a real orphan
        empty. */
    private static func apparentSize(of dir: URL, fileManager: FileManager) -> Int64 {
        guard
            let enumerator = fileManager.enumerator(
                at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
