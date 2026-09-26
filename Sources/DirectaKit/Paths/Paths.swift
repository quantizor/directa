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

    /** The CLI's local layout: `DIRECTA_DATA_DIR` and `DIRECTA_LOGS_DIR` stand
        in for the defaults, the way `ddirecta --data-dir`/`--logs-dir` do for
        the daemon, so a CLI pointed at a throwaway daemon never reads or writes
        the real ones. The socket follows the data dir unless `DIRECTA_SOCKET`
        names one, matching a daemon started with `--data-dir` alone. An empty
        value is treated as unset. */
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DirectaPaths {
        func directory(_ key: String) -> URL? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        return DirectaPaths(
            dataDir: directory(dataDirEnvironmentKey), logsDir: directory(logsDirEnvironmentKey))
    }

    public static let dataDirEnvironmentKey = "DIRECTA_DATA_DIR"
    public static let logsDirEnvironmentKey = "DIRECTA_LOGS_DIR"

    /** The layout of the daemon that answered `daemon.info`: its own data and
        logs directories, which a daemon started with `--data-dir`/`--logs-dir`
        moves away from this machine's defaults. */
    public init(daemon info: DaemonInfo) {
        self.init(
            dataDir: URL(fileURLWithPath: info.dataDir), logsDir: URL(fileURLWithPath: info.logsDir))
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
    /** Records "Start at login" as off: written by the Settings toggle, and
        at launch when `AppAgentPolicy.launchAction` answers `recordOff`.
        Absence alone never turns Start at login on. */
    public var appAutostartDisabledFile: URL { dataDir.appending(path: "app-autostart.disabled") }

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

    /** The one wording for a socket path `fitsSunPath` refuses. The client
        raises this before ever calling `connect(2)`; the daemon raises the same
        text before taking its single-instance lock, so a `DIRECTA_SOCKET`
        override too long for `sockaddr_un` fails the same way on both ends
        instead of the daemon printing a false "listening on" line while
        `NWListener` binds nothing. */
    public static func sunPathLimitMessage(_ path: String) -> String {
        "socket path exceeds sun_path limit: \(path)"
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

    /** The project's log directory root, `<slug>-<hash8>`: every server's log
        directory lives under this one. The slug keeps it human-readable; the
        hash keeps distinct projects with one basename apart. The single home
        for that name, so removing it (an explicit unregister down to zero
        servers, the missing-project sweep) deletes exactly what a fresh spawn
        would recreate. */
    public func projectLogDir(project: String) -> URL {
        logsDir.appending(path: Self.projectLogDirName(project: project))
    }

    /** The `<slug>-<hash8>` name alone, independent of any logs root. */
    public static func projectLogDirName(project: String) -> String {
        let project = canonicalProjectPath(project)
        return "\(projectSlug(project))-\(hash8(project))"
    }

    /** True when `name` has the shape `projectLogDir` gives a directory: the
        `projectSlug` alphabet, a dash, then eight lowercase hex characters. A
        logs root shared with other apps (`ddirecta --logs-dir ~/Library/Logs`)
        holds folders directa never made, and this shape is how they are told
        apart. */
    public static func isProjectLogDirName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z0-9-]*-[0-9a-f]{8}/) != nil
    }

    /** Per-server log directory: `<slug>-<hash8>/<server>`. */
    public func serverLogDir(project: String, server: String) -> URL {
        projectLogDir(project: project).appending(path: Self.serverPathComponent(server))
    }

    public var eventsFile: URL { dataDir.appending(path: "events.log") }

    /** The daemon's own diagnostics: telemetry.log and its rotations. The
        name has no hash suffix, so `isProjectLogDirName` never mistakes it
        for a project's log directory. */
    public var daemonTelemetryDir: URL { logsDir.appending(path: "daemon") }

    /** One file per daemon boot describing how the previous run ended. */
    public var daemonIncidentsDir: URL { daemonTelemetryDir.appending(path: "incidents") }

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

/** A step of `AtomicFile.write`'s temp + fsync + rename sequence that did not
    hold: the write happened, but the durability or cleanup guarantee around it
    did not. `message` names the exact call and path, the same posture as a wire
    error. */
public struct AtomicFileError: CustomStringConvertible, Error, Sendable {
    public let message: String

    public var description: String { message }
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
        if fd < 0 {
            let openErrno = errno
            try? FileManager.default.removeItem(at: tmp)
            throw AtomicFileError(
                message: "cannot open \(tmp.path) to fsync it: \(String(cString: strerror(openErrno)))")
        }
        let syncStatus = fsync(fd)
        let syncErrno = errno
        close(fd)
        if syncStatus != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw AtomicFileError(
                message: "fsync(\(tmp.path)) failed: \(String(cString: strerror(syncErrno)))")
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            /** The temp file is only ever meaningful mid-write: once the rename
                fails, nothing will ever pick it up, so a daemon killed right
                here would otherwise leave it on disk forever (that leftover
                class is exactly what `sweepStaleTemps` cleans up for an
                earlier crash; this path prevents adding to the pile). */
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        /** Durability covers the rename, not only the bytes: fsyncing `tmp`
            guarantees its content survives a crash, but a crash before the
            directory entry itself is flushed can still lose the rename and
            leave the old file in place. fsyncing the parent directory after
            the replace closes that window. */
        let dirFD = open(dir.path, O_RDONLY)
        if dirFD < 0 {
            let openErrno = errno
            throw AtomicFileError(
                message: "cannot open \(dir.path) to fsync the rename: \(String(cString: strerror(openErrno)))")
        }
        let dirSyncStatus = fsync(dirFD)
        let dirSyncErrno = errno
        close(dirFD)
        if dirSyncStatus != 0 {
            throw AtomicFileError(
                message: "fsync(\(dir.path)) failed: \(String(cString: strerror(dirSyncErrno)))")
        }
    }

    /** Deletes a `write`-generated temp (`.<name>.tmp-<pid>-<uuid>`) whose pid is
        no longer alive, and leaves everything else in `dir` untouched: a daemon
        killed between the temp write and the rename leaves one behind forever,
        since nothing else ever names it to clean it up, but a temp whose writer
        is still running must never be touched mid-write. Non-throwing: a sweep
        that could fail startup over a leftover file would trade a cosmetic mess
        for the exact crash-loop the defensive-load rule exists to prevent. */
    public static func sweepStaleTemps(in dir: URL, isAlive: (Int) -> Bool) {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries {
            guard let pid = tempFilePid(entry.lastPathComponent), !isAlive(pid) else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /** The pid embedded in a `write`-generated temp name, anchored to the exact
        suffix `write` appends, or nil for anything else in the directory (a real
        store, an unrelated dotfile, a `.corrupt-<timestamp>` quarantine). */
    static func tempFilePid(_ filename: String) -> Int? {
        guard let match = filename.firstMatch(of: /\.tmp-(\d+)-[0-9A-Fa-f-]+$/) else { return nil }
        return Int(match.1)
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
