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

/** One conversation's last picture. A harness may hang its own fields off
    `antigravity`. The compare does not read them. `shownErrorLines` holds,
    per server, the sanitized err lines already quoted to this conversation, so
    a later quote skips them. It is optional so a record from an older version
    still loads. */
public struct HookConversationRecord: Codable, Equatable, Sendable {
    public var antigravity: AntigravityConversation?
    public var picture: HookServerPicture
    public var shownErrorLines: [String: [String]]?

    public init(
        antigravity: AntigravityConversation? = nil,
        picture: HookServerPicture,
        shownErrorLines: [String: [String]]? = nil
    ) {
        self.antigravity = antigravity
        self.picture = picture
        self.shownErrorLines = shownErrorLines
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

    /** `boundary`, or a conversation with no record yet, speaks the full
        summary and quotes nothing. Any other call speaks only the servers whose
        picture row changed, one line each. `errorLines` holds the latest err
        lines of the servers `enteringBad` named; of those, the last
        `HookErrorText.lineLimit` that the stored record has not shown are
        quoted. Harness fields on the stored record are copied onto the result.
        The caller updates them. */
    public static func outcome(
        stored: HookConversationRecord?,
        picture: HookServerPicture,
        errorLines: [String: [String]] = [:],
        summary: String?,
        boundary: Bool
    ) -> HookChangeOutcome {
        guard let stored, !boundary else {
            let record = HookConversationRecord(
                antigravity: stored?.antigravity, picture: picture,
                shownErrorLines: pruned(stored?.shownErrorLines, to: picture))
            return HookChangeOutcome(newErrorLines: false, record: record, text: summary)
        }
        guard stored.picture != picture else {
            return HookChangeOutcome(newErrorLines: false, record: stored, text: nil)
        }
        var shown = stored.shownErrorLines ?? [:]
        var quotes: [String: [String]] = [:]
        for name in enteringBad(stored: stored.picture, current: picture) {
            let seen = Set(shown[name] ?? [])
            var fresh: [String] = []
            for line in (errorLines[name] ?? []).suffix(HookErrorText.lineLimit).map(HookErrorText.line)
            where !line.isEmpty && !seen.contains(line) && !fresh.contains(line) {
                fresh.append(line)
            }
            quotes[name] = fresh
            shown[name] = Array(((shown[name] ?? []) + fresh).suffix(shownLinesLimit))
        }
        let record = HookConversationRecord(
            antigravity: stored.antigravity, picture: picture,
            shownErrorLines: pruned(shown, to: picture))
        let blocks = changeBlocks(old: stored.picture, new: picture, quotes: quotes)
        guard !blocks.isEmpty else {
            return HookChangeOutcome(newErrorLines: false, record: record, text: nil)
        }
        let text = ([AgentContext.openingTag] + blocks + [AgentContext.closingTag]).joined(separator: "\n")
        return HookChangeOutcome(
            newErrorLines: quotes.values.contains { !$0.isEmpty }, record: record, text: text)
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

/** The on-disk picture. One file per harness conversation under
    `$TMPDIR/directa-hook-snapshot`. `DIRECTA_HOOK_SNAPSHOT_DIR` relocates it. */
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
        the same file. The caller picks both pieces. The session id is sanitized
        once. `scope` is a fixed harness slug. */
    public static func fileKey(scope: String, session: String?) -> String {
        "\(scope)-\(sessionKey(session))"
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
