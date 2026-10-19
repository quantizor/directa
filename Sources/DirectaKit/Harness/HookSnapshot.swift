import Foundation

/** The server picture a conversation has already been shown: exactly the
    fields whose change is worth a line. Clocks and err output stay out, so a
    later tool call speaks only when a server actually changed. */
public struct HookServerPicture: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public var conflict: String?
        public var exitCode: Int?
        public var exitSignal: Int?
        public var name: String
        public var phase: String
        public var port: Int?
        public var specStale: Bool
        public var spawnErrno: Int?
        public var url: String?
        public var worktree: String?

        public init(
            conflict: String?,
            exitCode: Int?,
            exitSignal: Int?,
            name: String,
            phase: String,
            port: Int?,
            specStale: Bool,
            spawnErrno: Int?,
            url: String?,
            worktree: String?
        ) {
            self.conflict = conflict
            self.exitCode = exitCode
            self.exitSignal = exitSignal
            self.name = name
            self.phase = phase
            self.port = port
            self.specStale = specStale
            self.spawnErrno = spawnErrno
            self.url = url
            self.worktree = worktree
        }
    }

    public var rows: [Row]

    public init(rows: [Row]) {
        self.rows = rows
    }

    public func row(_ name: String) -> Row? {
        rows.first { $0.name == name }
    }
}

/** What one agent has been shown about one project: its last picture, and per
    server the sanitized err lines already quoted to it, so a later quote skips
    them. */
public struct HookProjectRecord: Codable, Equatable, Sendable {
    public var picture: HookServerPicture
    public var shownErrorLines: [String: [String]]?

    public init(picture: HookServerPicture, shownErrorLines: [String: [String]]? = nil) {
        self.picture = picture
        self.shownErrorLines = shownErrorLines
    }
}

/** One agent's record: a project-keyed map of what it was last shown. A harness
    may hang its own fields off `antigravity`. The compare does not read them.
    Both fields are optional so a record from an older version still loads: its
    single project-less picture has no project to file under and is dropped, so
    each project speaks its full summary once more. */
public struct HookConversationRecord: Codable, Equatable, Sendable {
    public var antigravity: AntigravityConversation?
    /** Keyed by the canonical project path the call resolved to. */
    public var projects: [String: HookProjectRecord]?

    public init(
        antigravity: AntigravityConversation? = nil,
        projects: [String: HookProjectRecord]? = nil
    ) {
        self.antigravity = antigravity
        self.projects = projects
    }
}

/** What one hook invocation should write. `text` nil means say nothing.
    `newErrorLines` means the text quotes err lines this conversation had not
    been shown. The caller decides what its harness does with that. */
public struct HookChangeOutcome: Equatable, Sendable {
    public var newErrorLines: Bool
    public var record: HookConversationRecord
    public var text: String?

    public init(newErrorLines: Bool, record: HookConversationRecord, text: String?) {
        self.newErrorLines = newErrorLines
        self.record = record
        self.text = text
    }
}

/** One value (an err line, a server name, a url) made safe to sit on a single
    line inside the `<directa-servers>` fence. */
public enum HookErrorText {
    /** How many of a server's latest err lines a crash may quote. */
    public static let lineLimit = 5

    public static func line(_ raw: String) -> String {
        let cleaned = MonitorSanitizer.sanitize(raw).replacingOccurrences(
            of: AgentContext.closingTag, with: AgentContext.defangedClosingTag)
        return cleaned.count > 200 ? String(cleaned.prefix(200)) + "…" : cleaned
    }
}

/** Compare a fresh status list with the picture this conversation already saw
    and say only what changed. */
public enum HookChange {
    /** Most lines remembered per server as already shown. */
    static let shownLinesLimit = 20

    public static func picture(of servers: [ServerStatus]) -> HookServerPicture {
        let rows = servers.map { server in
            HookServerPicture.Row(
                conflict: server.portConflict?.state.rawValue,
                exitCode: server.lastExit?.code,
                exitSignal: server.lastExit?.signal,
                name: server.server,
                phase: server.phase.rawValue,
                port: server.displayPort,
                specStale: server.specStale == true,
                spawnErrno: server.spawnError?.errno,
                url: server.url,
                worktree: server.worktree)
        }
        return HookServerPicture(rows: rows.sorted { $0.name < $1.name })
    }

    private static let badPhases: Set<String> = [
        ServerPhase.crashed.rawValue, ServerPhase.failed.rawValue, ServerPhase.unhealthy.rawValue,
    ]

    private static func isBad(_ row: HookServerPicture.Row) -> Bool {
        badPhases.contains(row.phase)
    }

    /** Servers now crashed, failed, or unhealthy that were not in that phase
        in `stored`: the only ones whose err lines are worth a log read. Empty
        without a stored picture, since that call speaks the full summary. */
    public static func enteringBad(stored: HookServerPicture?, current: HookServerPicture) -> [String] {
        guard let stored else { return [] }
        return current.rows.compactMap { row in
            isBad(row) && stored.row(row.name)?.phase != row.phase ? row.name : nil
        }
    }

    /** `boundary`, or a project this record has no picture of yet, speaks the
        full summary and quotes nothing. Any other call speaks only the servers
        whose picture row changed since this record last saw `project`, one line
        each. `errorLines` holds the latest err lines of the servers
        `enteringBad` named; of those, the last `HookErrorText.lineLimit` that
        the record has not shown for `project` are quoted. Harness fields and
        other projects' entries on the stored record are copied onto the
        result, except that a `boundary` drops the other projects' entries. The
        caller updates the harness fields. */
    public static func outcome(
        stored: HookConversationRecord?,
        project: String,
        picture: HookServerPicture,
        errorLines: [String: [String]] = [:],
        summary: String?,
        boundary: Bool
    ) -> HookChangeOutcome {
        guard let stored, let known = stored.projects?[project], !boundary else {
            let entry = HookProjectRecord(
                picture: picture,
                shownErrorLines: pruned(stored?.projects?[project]?.shownErrorLines, to: picture))
            return HookChangeOutcome(
                newErrorLines: false,
                record: recording(entry, for: project, in: stored, droppingOthers: boundary),
                text: summary)
        }
        guard known.picture != picture else {
            return HookChangeOutcome(newErrorLines: false, record: stored, text: nil)
        }
        var shown = known.shownErrorLines ?? [:]
        var quotes: [String: [String]] = [:]
        for name in enteringBad(stored: known.picture, current: picture) {
            let seen = Set(shown[name] ?? [])
            var fresh: [String] = []
            for line in (errorLines[name] ?? []).suffix(HookErrorText.lineLimit).map(HookErrorText.line)
            where !line.isEmpty && !seen.contains(line) && !fresh.contains(line) {
                fresh.append(line)
            }
            quotes[name] = fresh
            shown[name] = Array(((shown[name] ?? []) + fresh).suffix(shownLinesLimit))
        }
        let entry = HookProjectRecord(picture: picture, shownErrorLines: pruned(shown, to: picture))
        let record = recording(entry, for: project, in: stored, droppingOthers: false)
        let blocks = changeBlocks(old: known.picture, new: picture, quotes: quotes)
        guard !blocks.isEmpty else {
            return HookChangeOutcome(newErrorLines: false, record: record, text: nil)
        }
        let text = ([AgentContext.openingTag] + blocks + [AgentContext.closingTag]).joined(separator: "\n")
        return HookChangeOutcome(
            newErrorLines: quotes.values.contains { !$0.isEmpty }, record: record, text: text)
    }

    /** A boundary starts the conversation over, so the pictures of every other
        project go with it and each speaks its full summary on return. */
    private static func recording(
        _ entry: HookProjectRecord, for project: String, in stored: HookConversationRecord?,
        droppingOthers: Bool
    ) -> HookConversationRecord {
        var record = stored ?? HookConversationRecord()
        var projects = droppingOthers ? [:] : record.projects ?? [:]
        projects[project] = entry
        record.projects = projects
        return record
    }

    private static func pruned(
        _ shown: [String: [String]]?, to picture: HookServerPicture
    ) -> [String: [String]]? {
        guard let shown else { return nil }
        let kept = shown.filter { picture.row($0.key) != nil }
        return kept.isEmpty ? nil : kept
    }

    /** One block per changed server in name order: its line, then its quotes. */
    private static func changeBlocks(
        old: HookServerPicture, new: HookServerPicture, quotes: [String: [String]]
    ) -> [String] {
        let names = Set(old.rows.map(\.name)).union(new.rows.map(\.name)).sorted()
        return names.compactMap { name -> String? in
            guard let line = changeLine(old: old.row(name), new: new.row(name)) else { return nil }
            let quoted = (quotes[name] ?? []).map { "  err: \($0)" }
            return ([line] + quoted).joined(separator: "\n")
        }
    }

    private static func changeLine(old: HookServerPicture.Row?, new: HookServerPicture.Row?) -> String? {
        guard let new else {
            return old.map { "\(HookErrorText.line($0.name)): removed" }
        }
        let name = HookErrorText.line(new.name)
        let why = isBad(new) ? "; run: directa why \(ShellWord.inertOr(new.name))" : ""
        guard let old else {
            let url = new.url.map { "; url \(HookErrorText.line($0))" } ?? ""
            return "\(name): new, \(HookErrorText.line(new.phase))\(url)\(why)"
        }
        guard old != new else { return nil }
        var parts: [String] = []
        if old.phase != new.phase {
            parts.append("\(HookErrorText.line(new.phase)) (was \(HookErrorText.line(old.phase)))")
        }
        if old.port != new.port {
            parts.append(new.port.map { "port \($0)" } ?? "port cleared")
        }
        if old.url != new.url {
            parts.append(new.url.map { "url \(HookErrorText.line($0))" } ?? "url cleared")
        }
        if old.conflict != new.conflict {
            parts.append(new.conflict.map { "port conflict \(HookErrorText.line($0))" } ?? "port conflict cleared")
        }
        if old.specStale != new.specStale {
            parts.append(new.specStale ? "config changed, restart to apply" : "config applied")
        }
        if old.exitCode != new.exitCode || old.exitSignal != new.exitSignal {
            if let code = new.exitCode {
                parts.append("exit \(code)")
            } else if let signal = new.exitSignal {
                parts.append("signal \(signal)")
            }
        }
        if old.spawnErrno != new.spawnErrno, let errno = new.spawnErrno {
            parts.append("spawn errno \(errno)")
        }
        if old.worktree != new.worktree {
            parts.append(new.worktree.map { "worktree \(HookErrorText.line($0))" } ?? "worktree cleared")
        }
        guard !parts.isEmpty else { return nil }
        return "\(name): " + parts.joined(separator: "; ") + why
    }
}

/** The on-disk record. One file per agent (a Claude Code subagent counts as
    its own) under `$TMPDIR/directa-hook-snapshot`, each beside a `.lock-` file
    that serializes its invocations. `DIRECTA_HOOK_SNAPSHOT_DIR` relocates it. */
public enum HookSnapshotStore {
    public static let directoryEnvironmentKey = "DIRECTA_HOOK_SNAPSHOT_DIR"
    public static let directoryName = "directa-hook-snapshot"

    public static func directory(environment: [String: String]) -> URL {
        if let override = environment[directoryEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let tmp = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: tmp).appending(path: directoryName)
    }

    public static let fallbackKey = "nosession"
    public static let maxKeyLength = 128
    public static let maxFileKeyLength = 200

    /** A conversation id becomes one path component. Anything outside the
        filename alphabet is dropped, the result is capped, and an empty result
        or a relative component (`.` / `..`) shares the `nosession` file rather
        than escaping the directory. */
    public static func sessionKey(_ raw: String?) -> String {
        let trimmed = (raw ?? "").replacing(/[^A-Za-z0-9._-]/) { _ in "" }
        let sliced = String(trimmed.prefix(maxKeyLength))
        if sliced.isEmpty || sliced == "." || sliced == ".." { return fallbackKey }
        return sliced
    }

    /** `scope` keeps two callers that share a missing session id from writing
        the same file. The caller picks the pieces. The session id and the agent
        id are each sanitized once. `scope` is a fixed harness slug. A subagent
        shares its parent's session id, so a non-empty `agent` takes a file of
        its own, joined with `+`, which sanitizing removes from both ids, so
        two pairs of ids whose sanitized forms differ never share a file.

        The key stays within `maxFileKeyLength` (room for the lock file's
        prefix and the write's temp name under the 255-byte name limit). When
        the plain key would pass it, the agent part becomes `~` and the first
        32 hex characters of a SHA-256 over the raw agent id: sanitizing
        removes `~`, so a hashed key never equals a plain one, and agent ids
        that differ anywhere stay apart. Ids that sanitize to the same string
        (differing only in dropped characters, or past `maxKeyLength`) share a
        file when the plain key fits. */
    public static func fileKey(scope: String, session: String?, agent: String? = nil) -> String {
        let base = "\(scope)-\(sessionKey(session))"
        guard let agent, !agent.isEmpty else { return base }
        let plain = "\(base)+\(sessionKey(agent))"
        guard plain.utf8.count > maxFileKeyLength else { return plain }
        let digest = DirectaPaths.hashHex(Array(agent.utf8)).prefix(32)
        return "\(base)+~\(digest)"
    }

    /** How long a hook waits for another invocation on the same record before
        going ahead unlocked. A hook must never hold up its agent for long. */
    public static let lockTimeout: Duration = .seconds(5)

    /** Runs `body` while holding the record's lock (an flock on a sibling file
        named `.lock-<fileKey>`, which no record name can equal), so two tool
        calls finishing together cannot both load the same stored picture and
        both speak. The lock is polled without blocking a thread. When it
        cannot be had (the directory is unwritable, or `timeout` passes), `body`
        runs unlocked: a duplicate line costs less than a stalled agent. */
    public static func exclusively<Result: Sendable>(
        fileKey: String,
        directory: URL,
        timeout: Duration = lockTimeout,
        _ body: () async -> Result
    ) async -> Result {
        let descriptor = await acquireLock(fileKey: fileKey, directory: directory, timeout: timeout)
        defer { if let descriptor { close(descriptor) } }
        return await body()
    }

    private static func acquireLock(fileKey: String, directory: URL, timeout: Duration) async -> Int32? {
        /** Failing to make the directory leaves `open` to fail below, and that
            is the unlocked path. */
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(
            directory.appending(path: ".lock-\(fileKey)").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        let deadline = ContinuousClock.now + timeout
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let busy = errno == EWOULDBLOCK || errno == EINTR
            guard busy, ContinuousClock.now < deadline else {
                close(descriptor)
                return nil
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                close(descriptor)
                return nil
            }
        }
        return descriptor
    }

    public static func load(fileKey: String, directory: URL) -> HookConversationRecord? {
        AtomicFile.loadDefensively(
            HookConversationRecord.self, from: directory.appending(path: fileKey))
    }

    public static func save(_ record: HookConversationRecord, fileKey: String, directory: URL) {
        guard let data = try? JSONCoding.encoder().encode(record) else { return }
        try? AtomicFile.write(data, to: directory.appending(path: fileKey))
    }
}
