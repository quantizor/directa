import Foundation

/** Slug directories under the logs root (`~/Library/Logs/directa/<slug>-<hash8>`)
    that match no project the daemon currently reports. `ControlServer` removes
    a project's log directory when it forgets the project (an explicit
    unregister down to zero servers, the missing-project sweep), but a directory
    predating that fix, or one orphaned some other way, is never cleaned up
    automatically; only `directa uninstall --purge` removes the whole logs tree.

    `detect` is pure over injected disk facts so it is unit-testable; `scan`
    gathers those facts from disk for `directa doctor`. */
public enum OrphanProjectLogs {
    /** A slug directory with no project left to claim it. */
    public struct Finding: Equatable, Sendable {
        /** What is wrong, in plain terms a non-engineer can read, including the
            directory's apparent size. */
        public let detail: String
        /** The literal command that removes it. */
        public let remedy: String

        public init(detail: String, remedy: String) {
            self.detail = detail
            self.remedy = remedy
        }
    }

    /** `entries` is every slug directory found directly under the logs root,
        each paired with its apparent size in bytes (never a block-allocation
        size: a cloud-synced or lazily-materialized tree can report zero
        allocated blocks for a fully intact file, which would misreport a real
        orphan as empty). `claimedSlugDirs` is
        `DirectaPaths.projectLogDir(project:).lastPathComponent` for every
        project the daemon currently reports; a directory not in that set has
        no project left to speak for it. */
    public static func detect(
        entries: [(apparentBytes: Int64, path: URL)], claimedSlugDirs: Set<String>
    ) -> [Finding] {
        entries
            .filter { !claimedSlugDirs.contains($0.path.lastPathComponent) }
            .sorted { $0.path.path < $1.path.path }
            .map { entry in
                Finding(
                    detail: "\(entry.path.path) (\(formatBytes(entry.apparentBytes))) matches no registered project",
                    remedy: "rm -rf \(entry.path.path)")
            }
    }

    /** Gathers the disk facts and runs `detect`. Impure (directory listing,
        file sizes); the decision it feeds is the pure `detect` above. */
    public static func scan(
        paths: DirectaPaths, claimedSlugDirs: Set<String>, fileManager: FileManager = .default
    ) -> [Finding] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: paths.logsDir.path) else {
            return []
        }
        let entries: [(apparentBytes: Int64, path: URL)] = names.compactMap { name in
            let url = paths.logsDir.appending(path: name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { return nil }
            return (apparentBytes: apparentSize(of: url, fileManager: fileManager), path: url)
        }
        return detect(entries: entries, claimedSlugDirs: claimedSlugDirs)
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
