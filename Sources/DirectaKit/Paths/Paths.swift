import CryptoKit
import Darwin
import Foundation

/** On-disk layout: single home for every path the three products share. */
public struct DirectaPaths: Sendable {
    public let dataDir: URL
    public let logsDir: URL

    public init(dataDir: URL? = nil, logsDir: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.dataDir = dataDir ?? home.appending(path: "Library/Application Support/directa")
        self.logsDir = logsDir ?? home.appending(path: "Library/Logs/directa")
    }

    public var daemonBinaryDir: URL { dataDir.appending(path: "bin") }
    public var daemonLog: URL { dataDir.appending(path: "daemon.log") }
    /** Login-shell PATH captured at install/start. The sealed in-bundle
        LaunchAgent cannot hold a dynamic PATH; the daemon merges this file
        into its environment at startup so children still find Homebrew tools. */
    public var agentPathFile: URL { dataDir.appending(path: "agent.path") }
    /** Written before replacing `/Applications/directa.app` so the relaunched
        copy settles BTM before re-registering the helper (ad-hoc CDHash). */
    public var agentRebindFile: URL { dataDir.appending(path: "agent.rebind") }
    public var lockFile: URL { dataDir.appending(path: "daemon.lock") }
    /** Held resource locks (`project::resource` → holder + paused servers).
        Survives a daemon crash so mid-lock deaths can still resume what pause
        stopped. */
    public var locksFile: URL { dataDir.appending(path: "locks.json") }
    public var registryFile: URL { dataDir.appending(path: "registry.json") }
    public var stateFile: URL { dataDir.appending(path: "state.json") }
    public var stoppedIntentFile: URL { dataDir.appending(path: "stopped.intent") }

    /** The unix socket path, honoring DIRECTA_SOCKET and falling back under the
        sun_path 104-byte limit (long usernames, relocated homes). */
    public var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["DIRECTA_SOCKET"], !override.isEmpty {
            return override
        }
        let preferred = dataDir.appending(path: "daemon.sock").path
        return Self.fitsSunPath(preferred) ? preferred : "/tmp/directa-\(getuid())/daemon.sock"
    }

    /** sun_path includes the NUL terminator. */
    public static func fitsSunPath(_ path: String) -> Bool {
        path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    /** One path component for a server name, safe to append.

        A server name comes from a repo's committed devservers.json, so it is not
        directa's own string. `URL.appending(path:)` keeps `..` and `/` verbatim
        and the kernel resolves them at `createDirectory` and `open`, so a name
        of `../../../x` made the daemon create directories outside the logs tree
        and write raw child stdout into them. Separators and dot-only components
        are replaced rather than rejected so an odd name still gets a home, and
        the hash keeps two names that flatten to the same text apart.

        Every name the flattening CHANGED carries the hash, not only the ones
        that would have escaped. Hashing just the escaping cases left `a/b` and
        `a_b` both landing on `a_b`, so two servers shared one log directory and
        intermixed their output, which is the collision this comment already
        claimed to have handled. A name the flattening left alone cannot collide
        with a flattened one on its own text, so it keeps a readable directory
        with no suffix. */
    public static func serverPathComponent(_ server: String) -> String {
        let flattened = String(
            server.map { $0 == "/" || $0 == ":" || $0 == "\0" ? "_" : $0 })
        let resolvesToADirectoryOtherThanItself =
            flattened == "." || flattened == ".." || flattened.isEmpty
        if resolvesToADirectoryOtherThanItself { return "server-\(hash8(server))" }
        return flattened == server ? flattened : "\(flattened)-\(hash8(server))"
    }

    /** Per-server log directory: `<slug>-<hash8>/<server>`. The slug keeps paths
        human-readable; the hash keeps distinct projects with one basename apart. */
    public func serverLogDir(project: String, server: String) -> URL {
        let project = canonicalProjectPath(project)
        return logsDir
            .appending(path: "\(projectSlug(project))-\(Self.hash8(project))")
            .appending(path: Self.serverPathComponent(server))
    }

    public var eventsFile: URL { dataDir.appending(path: "events.log") }

    /** Caches, preferences, and saved state outside the data/logs trees.
        `--purge` removes these along with `dataDir` and `logsDir`. */
    public static func userLibraryResidue(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let library = home.appending(path: "Library")
        return [
            library.appending(path: "Caches/dev.quantizor.directa.app"),
            library.appending(path: "Caches/dev.quantizor.ddirecta"),
            library.appending(path: "Caches/ddirecta"),
            library.appending(path: "HTTPStorages/dev.quantizor.ddirecta"),
            library.appending(path: "HTTPStorages/ddirecta"),
            library.appending(path: "Preferences/dev.quantizor.directa.app.plist"),
            library.appending(path: "Saved Application State/dev.quantizor.directa.app.savedState"),
        ]
    }

    /** Raw child-output spools, one per stream so out/err tagging survives; the
        child holds these fds, so they outlive the daemon. */
    public func spoolErrFile(project: String, server: String) -> URL {
        serverLogDir(project: project, server: server).appending(path: "err.spool")
    }

    public func spoolOutFile(project: String, server: String) -> URL {
        serverLogDir(project: project, server: server).appending(path: "out.spool")
    }

    public func structuredLogFile(project: String, server: String) -> URL {
        serverLogDir(project: project, server: server).appending(path: "current.log")
    }

    /** Full hex SHA-256. `hash8` is its first 8 characters and stays so: log
        directory names on disk derive from that prefix. */
    public static func hashHex(_ bytes: [UInt8]) -> String {
        SHA256Portable.digest(bytes)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /** Full hex SHA-256 of a file's contents, read in chunks so peak memory is a
        chunk rather than the file. Nil when the file cannot be opened or read
        through, so a caller can report that instead of hashing a partial read
        and calling the result the file's identity. */
    public static func hashHex(contentsOf path: String) -> String? {
        SHA256Portable.digest(contentsOf: path)?
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /** First 8 hex chars of SHA-256 over the canonical project path. */
    public static func hash8(_ string: String) -> String {
        String(hashHex(Array(string.utf8)).prefix(8))
    }
}

/** The human-readable half of a project's on-disk and host identity: the last
    path component, lowercased, with anything outside `[a-z0-9-]` collapsed to a
    dash. The single home for that algorithm; log directories and the default
    `<slug>.localhost` host both derive from it.

    Callers pass the path they mean: log directories slug the canonical path,
    while the host slug uses the path as written, and those can differ when a
    symlink renames the last component. */
public func projectSlug(_ path: String) -> String {
    (path as NSString).lastPathComponent
        .lowercased()
        .replacing(/[^a-z0-9-]+/) { _ in "-" }
}

/** Canonicalizes a project path: absolute, symlinks resolved, on-disk case.
    CLI and daemon both use this so `~/code` symlinks or `/tmp` vs `/private/tmp`
    cannot mint two identities for one project. */
public func canonicalProjectPath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded)
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    // On-disk case: FileManager gives the true spelling for existing paths.
    if let canonical = try? resolved.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
        return canonical
    }
    return resolved.path
}

/** Server identity used in the registry and state store. */
public func serverID(project: String, name: String) -> String {
    "\(project)::\(name)"
}

/** Inverse of `serverID`. Splits on the last `::` so a project path that
    itself contains `::` still round-trips. */
public func parseServerID(_ id: String) -> (name: String, project: String)? {
    guard let separator = id.range(of: "::", options: .backwards) else { return nil }
    return (
        name: String(id[separator.upperBound...]),
        project: String(id[id.startIndex..<separator.lowerBound])
    )
}

/** Atomic file persistence: temp + fsync + rename. Loads are defensive: a parse
    failure quarantines the file to `.corrupt-<timestamp>` and returns nil rather
    than crashing (a startup parse crash under launchd KeepAlive loops forever). */
public enum AtomicFile {
    /** Temp + fsync + rename. The temp name carries a per-call unique suffix, not
        just the pid: two writers inside one process (the app registers the agent
        at launch while its recovery poll writes the same file) would otherwise
        share a temp path and rename it out from under each other. */
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(
            path: ".\(url.lastPathComponent).tmp-\(getpid())-\(UUID().uuidString)")
        try data.write(to: tmp)
        let fd = open(tmp.path, O_WRONLY)
        if fd >= 0 {
            fsync(fd)
            close(fd)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /** Loads a persisted store, distinguishing three outcomes a single nil used
        to blur together. A missing file returns nil: there is no prior state, so
        starting empty is correct. A file that exists but cannot be READ (EMFILE
        as the daemon nears its fd limit, an I/O error, a permission change)
        THROWS, so the caller refuses to start rather than treating real data as
        absent and erasing it on the next write. A file that reads but will not
        PARSE is quarantined to `.corrupt-<timestamp>` and returns nil, because
        the bytes are unusable and starting empty is the only recovery (a parse
        crash under launchd KeepAlive would loop forever). */
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
        {
            return nil
        }
        do {
            return try JSONCoding.decoder().decode(type, from: data)
        } catch {
            let stamp = JSONCoding.formatISO8601(Date()).replacing(":", with: "-")
            let quarantine = url.appendingPathExtension("corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: url, to: quarantine)
            return nil
        }
    }

    /** Non-throwing convenience: a missing, unreadable, or corrupt file all yield
        nil. Use only where losing the value is safe (a rebuildable cache, a
        secondary hint read after the primary store already loaded), never for a
        store whose next write would overwrite real data. Reach for `load` there,
        and refuse to start on a read failure. */
    public static func loadDefensively<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        try? load(type, from: url)
    }
}

/** SHA-256 over CryptoKit, which is a system framework here rather than a
    package dependency, so the two-dependency rule is untouched. This replaced a
    hand-rolled FIPS 180-4 implementation whose only real defect was having no
    incremental entry point: hashing a file meant holding the whole file in
    memory, which is why large ones were sampled at head and tail instead of
    read, and a middle-only rewrite that preserved both went unnoticed by a check
    whose entire job is noticing. `ResourceIdentityTests` pins the published
    vectors for "" and "abc" plus a multi-block input, so the swap is provably
    byte-identical and no project's log directory moved. */
enum SHA256Portable {
    static func digest(_ message: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(message)))
    }

    /** Reads in fixed-size chunks so peak memory is the chunk, not the file. The
        caller gets nil rather than a digest of nothing when the file cannot be
        opened or read, because a fingerprint that silently degrades to a
        constant compares equal to every other failure and reports "unchanged"
        for a resource nobody could read. */
    static func digest(contentsOf path: String, chunkBytes: Int = 1 << 20) -> [UInt8]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            /** do/catch rather than `try?`: Swift flattens `try?` over a call
                that already returns an optional, which would make a read error
                and a clean end-of-file the same nil and hash a truncated file as
                though it were whole. */
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkBytes)
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return Array(hasher.finalize())
    }
}
