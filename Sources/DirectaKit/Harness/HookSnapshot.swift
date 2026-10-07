import Foundation

/** The server picture a conversation has already been shown. Clocks stay out,
    so a later tool call pastes again only when a server actually changed.
    Err lines are the sanitized last lines the change path may quote, not the
    paragraph `AgentContext.render` builds. */
public struct HookServerPicture: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public var conflict: String?
        public var errorCount: Int
        public var errorLines: [String]
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
            errorCount: Int,
            errorLines: [String],
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
            self.errorCount = errorCount
            self.errorLines = errorLines
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

/** One conversation's last picture and how many times Antigravity has been
    pulled back to look at new error lines. */
public struct HookConversationRecord: Codable, Equatable, Sendable {
    public var picture: HookServerPicture
    public var pullBacks: Int

    public init(picture: HookServerPicture, pullBacks: Int) {
        self.picture = picture
        self.pullBacks = pullBacks
    }
}

/** What one hook invocation should write. `text` nil means say nothing.
    `pullBack` means new err lines were included and the continuation budget
    remains. The caller decides whether its harness can act on that. */
public struct HookChangeOutcome: Equatable, Sendable {
    public var pullBack: Bool
    public var record: HookConversationRecord
    public var text: String?

    public init(pullBack: Bool, record: HookConversationRecord, text: String?) {
        self.pullBack = pullBack
        self.record = record
        self.text = text
    }
}

/** One err line made safe to sit inside the `<directa-servers>` fence. */
public enum HookErrorText {
    public static let lineLimit = 10

    public static func line(_ raw: String) -> String {
        let cleaned = MonitorSanitizer.sanitize(raw).replacingOccurrences(
            of: "</directa-servers>", with: "<\u{200B}/directa-servers>")
        return cleaned.count > 200 ? String(cleaned.prefix(200)) + "…" : cleaned
    }
}

/** Compare a fresh status list with the picture this conversation already saw. */
public enum HookChange {
    public static let pullBackLimit = 3

    /** Servers whose err tail is worth a log read: a crashed, failed, or
        unhealthy server, or one whose err-line count moved. A healthy server
        whose count is unchanged is left out. */
    public static func serversNeedingErrorLines(
        stored: HookServerPicture?, servers: [ServerStatus]
    ) -> [String] {
        servers.compactMap { server in
            let bad = server.phase == .crashed || server.phase == .failed || server.phase == .unhealthy
            let count = server.errorSummary?.count ?? 0
            let previous = stored?.row(server.server)
            if bad || previous?.errorCount != count { return server.server }
            return nil
        }
    }

    public static func picture(
        of servers: [ServerStatus], errorLines: [String: [String]] = [:]
    ) -> HookServerPicture {
        let rows = servers.map { server in
            HookServerPicture.Row(
                conflict: server.portConflict?.state.rawValue,
                errorCount: server.errorSummary?.count ?? 0,
                errorLines: (errorLines[server.server] ?? []).prefix(HookErrorText.lineLimit).map(
                    HookErrorText.line),
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

    /** `boundary` is a session start or a compaction: paste the summary even
        when the picture matches, and do not quote err lines. Any other call
        pastes only when the picture differs, and quotes err lines that were
        not in the stored picture. A pull-back happens only for those new
        lines, and only until `pullBackLimit`. */
    public static func outcome(
        stored: HookConversationRecord?,
        picture: HookServerPicture,
        summary: String?,
        boundary: Bool
    ) -> HookChangeOutcome {
        if let stored, stored.picture == picture, !boundary {
            return HookChangeOutcome(pullBack: false, record: stored, text: nil)
        }
        let fresh = newErrorLines(stored: stored?.picture, current: picture)
        var text = summary
        if !boundary, !fresh.isEmpty, let summary {
            text = insertingErrorLines(fresh, into: summary)
        }
        let pulls = boundary ? 0 : (stored?.pullBacks ?? 0)
        let pullBack = !boundary && !fresh.isEmpty && summary != nil && pulls < pullBackLimit
        let record = HookConversationRecord(
            picture: picture, pullBacks: pullBack ? pulls + 1 : pulls)
        let speak = boundary ? summary != nil : text != nil && (stored?.picture != picture)
        return HookChangeOutcome(pullBack: pullBack, record: record, text: speak ? text : nil)
    }

    /** Err lines to quote: non-empty, and not the lines already stored for
        that server. */
    public static func newErrorLines(
        stored: HookServerPicture?, current: HookServerPicture
    ) -> [(name: String, lines: [String])] {
        current.rows.compactMap { row in
            guard !row.errorLines.isEmpty, row.errorLines != stored?.row(row.name)?.errorLines else {
                return nil
            }
            return (row.name, row.errorLines)
        }
    }

    public static func insertingErrorLines(
        _ blocks: [(name: String, lines: [String])], into summary: String
    ) -> String {
        let body = blocks.map { block in
            (["  \(block.name) errors:"] + block.lines.map { "  err: \($0)" }).joined(separator: "\n")
        }.joined(separator: "\n")
        let closing = "</directa-servers>"
        guard let range = summary.range(of: closing, options: .backwards) else {
            return summary + "\n" + body
        }
        return summary.replacingCharacters(in: range, with: body + "\n" + closing)
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

    /** `scope` keeps two callers that share a missing session id from writing
        the same file. The caller picks both pieces. The id is sanitized the
        same way as every other session file. */
    public static func fileKey(scope: String, session: String?) -> String {
        let id = AntigravitySessionGate.sessionKey(session)
        return AntigravitySessionGate.sessionKey("\(scope)-\(id)")
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
