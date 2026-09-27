import Foundation

/** How the previous run of the daemon's launchd job ended, as `launchctl
    print` reports it. `print` output is not API (launchctl(1) says so), so the
    parsed fields are a convenience and `rawLines` keeps the job's top-level
    lines verbatim for whatever the parse misses. */
public struct LaunchdExitRecord: Codable, Equatable, Sendable {
    public var exitCode: Int?
    public var exitReason: String?
    public var immediateReason: String?
    public var rawLines: [String]
    public var runs: Int?
    public var spawnType: String?
    public var terminatingSignal: Int?
    public var threadLimit: Int?

    public init(
        exitCode: Int?, exitReason: String?, immediateReason: String?, rawLines: [String], runs: Int?,
        spawnType: String?, terminatingSignal: Int?, threadLimit: Int?
    ) {
        self.exitCode = exitCode
        self.exitReason = exitReason
        self.immediateReason = immediateReason
        self.rawLines = rawLines
        self.runs = runs
        self.spawnType = spawnType
        self.terminatingSignal = terminatingSignal
        self.threadLimit = threadLimit
    }

    /** Keys of the job's own (one-tab-indented) lines kept verbatim. */
    static let keptKeyPrefixes = [
        "execs", "forks", "immediate reason", "jetsam", "job state", "last ", "pid", "runs", "spawn type",
        "state",
    ]

    public static func parse(_ printed: String) -> LaunchdExitRecord {
        let status = LaunchdJobs.parseJobPrint(printed)
        var fields: [String: String] = [:]
        var raw: [String] = []
        for line in printed.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t"), !line.hasSuffix("{"),
                let separator = line.range(of: " = ")
            else { continue }
            let key = line[line.index(after: line.startIndex)..<separator.lowerBound]
            guard keptKeyPrefixes.contains(where: { key.hasPrefix($0) }) else { continue }
            raw.append(String(line.dropFirst()))
            if fields[String(key)] == nil {
                fields[String(key)] = String(line[separator.upperBound...])
            }
        }
        return LaunchdExitRecord(
            exitCode: status.lastExitCode, exitReason: status.lastExitReason,
            immediateReason: fields["immediate reason"], rawLines: raw, runs: status.runs,
            spawnType: fields["spawn type"], terminatingSignal: status.lastTerminatingSignal,
            threadLimit: fields["jetsam thread limit"].flatMap { Int($0) })
    }
}

/** What launchd said about the previous run: its record, or why there is
    none. */
public enum LaunchdLookup: Equatable, Sendable {
    case found(LaunchdExitRecord)
    case unavailable(note: String)
}

/** The first line of an incident file, written at daemon boot. The previous
    run's last telemetry lines follow verbatim, then whatever the background
    search finds (`system-log` and `diagnostic-report` lines), then one
    `search-finished` line. On disk the lookup is a `launchd` record or a
    `launchdNote`, never both. */
public struct IncidentHeader: Codable, Equatable, Sendable {
    public var daemonPid: Int32
    public var entry = TelemetryEntryKind.incident
    /** Seconds from the previous run's last telemetry line to this boot. */
    public var gapSeconds: Double?
    public var launchd: LaunchdLookup
    /** The code on the previous run's own exit mark, when it wrote one
        that named a code. */
    public var previousExitCode: Int32?
    /** True when the previous run wrote its exit mark with no code or code
        zero. */
    public var previousExitedCleanly: Bool
    public var previousLastLineAt: Date?
    public var previousLineCount: Int
    public var previousPid: Int32?
    /** Boot time. */
    public var time: Date

    public init(
        daemonPid: Int32, gapSeconds: Double?, launchd: LaunchdLookup, previousExitCode: Int32?,
        previousExitedCleanly: Bool, previousLastLineAt: Date?, previousLineCount: Int, previousPid: Int32?,
        time: Date
    ) {
        self.daemonPid = daemonPid
        self.gapSeconds = gapSeconds
        self.launchd = launchd
        self.previousExitCode = previousExitCode
        self.previousExitedCleanly = previousExitedCleanly
        self.previousLastLineAt = previousLastLineAt
        self.previousLineCount = previousLineCount
        self.previousPid = previousPid
        self.time = time
    }

    private enum CodingKeys: String, CodingKey {
        case daemonPid, entry, gapSeconds, launchd, launchdNote, previousExitCode, previousExitedCleanly
        case previousLastLineAt, previousLineCount, previousPid, time
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        daemonPid = try container.decode(Int32.self, forKey: .daemonPid)
        entry = try container.decode(TelemetryEntryKind.self, forKey: .entry)
        gapSeconds = try container.decodeIfPresent(Double.self, forKey: .gapSeconds)
        launchd =
            if let record = try container.decodeIfPresent(LaunchdExitRecord.self, forKey: .launchd) {
                .found(record)
            } else {
                .unavailable(note: try container.decode(String.self, forKey: .launchdNote))
            }
        previousExitCode = try container.decodeIfPresent(Int32.self, forKey: .previousExitCode)
        previousExitedCleanly = try container.decode(Bool.self, forKey: .previousExitedCleanly)
        previousLastLineAt = try container.decodeIfPresent(Date.self, forKey: .previousLastLineAt)
        previousLineCount = try container.decode(Int.self, forKey: .previousLineCount)
        previousPid = try container.decodeIfPresent(Int32.self, forKey: .previousPid)
        time = try container.decode(Date.self, forKey: .time)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(daemonPid, forKey: .daemonPid)
        try container.encode(entry, forKey: .entry)
        try container.encodeIfPresent(gapSeconds, forKey: .gapSeconds)
        switch launchd {
        case .found(let record): try container.encode(record, forKey: .launchd)
        case .unavailable(let note): try container.encode(note, forKey: .launchdNote)
        }
        try container.encodeIfPresent(previousExitCode, forKey: .previousExitCode)
        try container.encode(previousExitedCleanly, forKey: .previousExitedCleanly)
        try container.encodeIfPresent(previousLastLineAt, forKey: .previousLastLineAt)
        try container.encode(previousLineCount, forKey: .previousLineCount)
        try container.encodeIfPresent(previousPid, forKey: .previousPid)
        try container.encode(time, forKey: .time)
    }
}

/** One unified-log line near the previous run's death. `time` is nil when
    `log show` gave a timestamp this parser could not read. */
public struct IncidentSystemLog: Codable, Equatable, Sendable {
    public var entry = TelemetryEntryKind.systemLog
    public var message: String
    public var process: String
    public var subsystem: String?
    public var time: Date?

    public init(message: String, process: String, subsystem: String?, time: Date?) {
        self.message = message
        self.process = process
        self.subsystem = subsystem
        self.time = time
    }
}

/** A crash or jetsam report in the death window. `excerpt` is the report's
    entry for the daemon's process when one could be picked out, else the
    report's first bytes. */
public struct IncidentDiagnosticReport: Codable, Equatable, Sendable {
    public var entry = TelemetryEntryKind.diagnosticReport
    public var excerpt: String?
    public var path: String
    public var time: Date

    public init(excerpt: String?, path: String, time: Date) {
        self.excerpt = excerpt
        self.path = path
        self.time = time
    }
}

/** The last line of an incident file. Absence is data: `matches` of zero, or
    an `outcome` other than `finished`, says what the search could not see. */
public struct IncidentSearchFinished: Codable, Equatable, Sendable {
    public var diagnosticReports: Int
    public var entry = TelemetryEntryKind.searchFinished
    public var logShowSeconds: Double?
    /** Every matching line `log show` printed, including any past
        `DaemonIncident.systemLogLineCap` that the file does not hold. */
    public var matches: Int
    /** `finished`, `timed out`, `failed: <why>`, or `skipped: <why>`. */
    public var outcome: String
    public var predicate: String?
    public var time: Date
    /** True when the file holds fewer `system-log` lines than `matches`. */
    public var truncated: Bool
    public var windowEnd: Date?
    public var windowStart: Date?

    public init(
        diagnosticReports: Int, logShowSeconds: Double?, matches: Int, outcome: String, predicate: String?,
        time: Date, truncated: Bool, windowEnd: Date?, windowStart: Date?
    ) {
        self.diagnosticReports = diagnosticReports
        self.logShowSeconds = logShowSeconds
        self.matches = matches
        self.outcome = outcome
        self.predicate = predicate
        self.time = time
        self.truncated = truncated
        self.windowEnd = windowEnd
        self.windowStart = windowStart
    }
}

/** Assembly and storage of the per-boot incident files. */
public enum DaemonIncident {
    /** Telemetry lines copied from the previous run: three minutes at the
        fast cadence, which covers the window before every death observed. */
    public static let previousLineCount = 180
    /** Incident files kept; older ones are deleted at boot. */
    public static let keepIncidents = 50
    /** Seconds of unified log before the previous run's last line. */
    public static let searchLeadSeconds = 60.0
    /** The search window never runs past this long after the last line, so a
        daemon that was down for hours does not scan hours of log. */
    public static let searchMaxSeconds = 600.0
    /** When there is no previous telemetry, the search covers this long
        before boot. */
    public static let searchFallbackSeconds = 180.0

    /** What a boot knows about the previous run from its telemetry. */
    public struct Previous: Equatable, Sendable {
        /** The code on the run's own exit mark, when the mark named one. */
        public var exitCode: Int32?
        public var exitedCleanly: Bool
        public var lastLineAt: Date?
        public var lines: [String]
        public var pid: Int32?

        public init(exitCode: Int32? = nil, exitedCleanly: Bool, lastLineAt: Date?, lines: [String], pid: Int32?) {
            self.exitCode = exitCode
            self.exitedCleanly = exitedCleanly
            self.lastLineAt = lastLineAt
            self.lines = lines
            self.pid = pid
        }
    }

    /** How many of the previous run's last lines are searched for its
        exit mark: a line already in flight on another thread when the exit
        began can land after the mark. */
    public static let exitMarkSearchLines = 8

    /** Reads the previous run's last lines from the telemetry directory.
        Called before this run writes its first line. The run exited cleanly
        when its own `daemon-exiting` mark is among the last
        `exitMarkSearchLines` and names no code or code zero; a nonzero code
        (a startup failure) is a death like a kill. */
    public static func readPrevious(
        telemetryDirectory: URL, keepRotated: Int = TelemetryLog.defaultKeepRotated
    ) -> Previous {
        let lines = TelemetryLog.lastLines(
            in: telemetryDirectory, count: previousLineCount, keepRotated: keepRotated)
        let decoder = JSONCoding.decoder()
        let last = lines.last.flatMap { TelemetryLog.LineHead(line: $0, decoder: decoder) }
        let pid = last?.daemonPid
        let exitingEvent = TelemetryMarkEvent.daemonExiting.rawValue
        let exitMark = lines.suffix(exitMarkSearchLines).lazy
            .filter { $0.contains(exitingEvent) }
            .compactMap { TelemetryLog.LineHead(line: $0, decoder: decoder) }
            .first { $0.event == exitingEvent && $0.daemonPid == pid }
        return Previous(
            exitCode: exitMark?.exitCode, exitedCleanly: exitMark.map { ($0.exitCode ?? 0) == 0 } ?? false,
            lastLineAt: last?.time, lines: lines, pid: pid)
    }

    /** `<boot time>-pid<pid>.ndjson`, colons swapped for dashes so the name
        sorts in time order and is safe on every filesystem. */
    public static func fileName(bootTime: Date, pid: Int32) -> String {
        let stamp = JSONCoding.formatISO8601(bootTime).replacing(":", with: "-")
        return "\(stamp)-pid\(pid).ndjson"
    }

    /** The header and the previous run's lines, ready to write. */
    public static func headerAndLines(
        bootTime: Date, daemonPid: Int32, launchd: LaunchdLookup, previous: Previous
    ) throws -> Data {
        let header = IncidentHeader(
            daemonPid: daemonPid,
            gapSeconds: previous.lastLineAt.map { Duration.seconds(bootTime.timeIntervalSince($0)).roundedSeconds },
            launchd: launchd, previousExitCode: previous.exitCode, previousExitedCleanly: previous.exitedCleanly,
            previousLastLineAt: previous.lastLineAt, previousLineCount: previous.lines.count,
            previousPid: previous.pid, time: bootTime)
        var data = try NDJSON.encodeLine(header)
        for line in previous.lines {
            data.append(Data(line.utf8))
            data.append(0x0A)
        }
        return data
    }

    /** The unified-log window for a death: from `searchLeadSeconds` before
        the previous run's last line to boot, capped at `searchMaxSeconds`
        past that line. */
    public static func searchWindow(previousLastLineAt: Date?, bootTime: Date) -> (start: Date, end: Date) {
        guard let last = previousLastLineAt, last <= bootTime else {
            return (bootTime.addingTimeInterval(-searchFallbackSeconds), bootTime)
        }
        return (
            last.addingTimeInterval(-searchLeadSeconds),
            min(bootTime, last.addingTimeInterval(searchMaxSeconds))
        )
    }

    /** The `log show` predicate: kernel memory and thread-limit messages,
        launchd's own lines about the agent label (never its child job
        labels), and any kernel, launchd, RunningBoard, or crash-reporter
        line naming the previous pid. RunningBoard's periodic state dumps name
        every process and are excluded by matching `:<pid>]`, the form its
        per-process lines take. */
    public static func logPredicate(previousPid: Int32?, label: String, processName: String) -> String {
        var kernel = [
            "eventMessage CONTAINS \"\(processName)\"",
            "eventMessage CONTAINS \"memorystatus\"",
            "eventMessage CONTAINS \"jetsam\"",
            "eventMessage CONTAINS \"thread limit\"",
            "eventMessage CONTAINS \"EXC_RESOURCE\"",
            "eventMessage CONTAINS \"killing\"",
        ]
        var launchd = [
            "eventMessage CONTAINS \"\(label) \"",
            "eventMessage CONTAINS \"\(label)]\"",
            "eventMessage CONTAINS \"\(label):\"",
            "eventMessage CONTAINS \"/\(label)\"",
        ]
        if let pid = previousPid {
            kernel.append("eventMessage CONTAINS \"[\(pid)]\"")
            kernel.append("eventMessage CONTAINS \"pid \(pid)\"")
            launchd.append("eventMessage CONTAINS \"[\(pid)]\"")
        }
        /** The kernel logs a code-signing `evaluation result` for every exec
            of any `ddirecta` binary on the machine, which says nothing about
            a death. */
        var clauses = [
            "(process == \"kernel\" AND NOT eventMessage BEGINSWITH \"evaluation result\" AND (\(kernel.joined(separator: " OR "))))",
            "(subsystem == \"com.apple.xpc.launchd\" AND NOT eventMessage CONTAINS \"\(label).job\" AND (\(launchd.joined(separator: " OR "))))",
        ]
        if let pid = previousPid {
            clauses.append("(process == \"runningboardd\" AND eventMessage CONTAINS \":\(pid)]\")")
            clauses.append(
                "((process == \"ReportCrash\" OR process == \"osanalyticshelper\" OR process == \"spindump\") AND (eventMessage CONTAINS \"\(processName)\" OR eventMessage CONTAINS \"\(pid)\"))"
            )
        }
        return clauses.joined(separator: " OR ")
    }

    /** One `log show --style ndjson` line. */
    private struct LogShowLine: Decodable {
        let eventMessage: String?
        let processImagePath: String?
        let subsystem: String?
        let timestamp: String?
    }

    /** Longest message kept per unified-log line. */
    public static let systemLogMessageCap = 1000
    /** Most unified-log lines kept per incident. */
    public static let systemLogLineCap = 300

    /** `log show` output as incident lines: the first `systemLogLineCap`,
        and how many matching lines there were in all. */
    public struct ParsedLogShow: Equatable, Sendable {
        public var lines: [IncidentSystemLog]
        public var matches: Int

        public init(lines: [IncidentSystemLog], matches: Int) {
            self.lines = lines
            self.matches = matches
        }

        public var truncated: Bool { matches > lines.count }
    }

    /** Parses `log show --style ndjson` output into incident lines, capped. */
    public static func parseLogShow(_ output: String) -> ParsedLogShow {
        var entries: [IncidentSystemLog] = []
        var matches = 0
        let decoder = JSONCoding.decoder()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("{"),
                let parsed = try? decoder.decode(LogShowLine.self, from: Data(line.utf8)),
                let message = parsed.eventMessage
            else { continue }
            matches += 1
            guard entries.count < systemLogLineCap else { continue }
            entries.append(
                IncidentSystemLog(
                    message: message.count > systemLogMessageCap
                        ? String(message.prefix(systemLogMessageCap)) + "..." : message,
                    process: parsed.processImagePath.map { ($0 as NSString).lastPathComponent } ?? "?",
                    subsystem: parsed.subsystem.flatMap { $0.isEmpty ? nil : $0 },
                    time: parsed.timestamp.flatMap { try? logTimestamp.parse($0) }))
        }
        return ParsedLogShow(lines: entries, matches: matches)
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /** `log show` ndjson timestamps read `2026-09-26 09:30:57.217451-0700`;
        parsed to the millisecond. */
    static let logTimestamp = Date.ParseStrategy(
        format:
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(6))\(timeZone: .iso8601(.short))",
        locale: posixLocale, timeZone: .gmt)

    /** `log show --start/--end` take local wall time in this form, with the
        offset, so the zone captured here never changes the instant. */
    private static let logShowTimeStyle = Date.VerbatimFormatStyle(
        format:
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)\(timeZone: .iso8601(.short))",
        locale: posixLocale, timeZone: .current, calendar: Calendar(identifier: .gregorian))

    public static func logShowTime(_ date: Date) -> String {
        date.formatted(logShowTimeStyle)
    }

    /** Report file names worth reading: every JetsamEvent, and any report
        naming the daemon's process. */
    public static func isRelevantReport(name: String, processName: String) -> Bool {
        (name.hasPrefix("JetsamEvent") || name.contains(processName))
            && (name.hasSuffix(".ips") || name.hasSuffix(".crash") || name.hasSuffix(".diag"))
    }

    /** Longest excerpt copied from one report. */
    public static let reportExcerptCap = 16 * 1024

    /** The daemon's entry from a report: for a JetsamEvent `.ips` (a JSON
        header line, then a JSON body with a `processes` array), the process
        whose `name` matches, re-encoded; for anything else the first
        `reportExcerptCap` bytes. Nil for a JetsamEvent that does not list the
        process, since the path alone then says the report exists. */
    public static func reportExcerpt(text: String, name: String, processName: String) -> String? {
        guard name.hasPrefix("JetsamEvent") else {
            return String(text.prefix(reportExcerptCap))
        }
        guard let bodyStart = text.firstIndex(of: "\n"),
            let body = try? JSONCoding.decoder().decode(
                JSONValue.self, from: Data(text[text.index(after: bodyStart)...].utf8)),
            case .object(let fields) = body, case .array(let processes)? = fields["processes"]
        else { return nil }
        let match = processes.first {
            if case .object(let process) = $0, case .string(let processNameValue)? = process["name"] {
                return processNameValue == processName
            }
            return false
        }
        guard let match, let encoded = try? JSONCoding.encoder().encode(match) else { return nil }
        let largest: String? =
            if case .string(let value)? = fields["largestProcess"] { value } else { nil }
        let excerpt = String(decoding: encoded, as: UTF8.self)
        return largest.map { "largestProcess=\($0) \(excerpt)" } ?? excerpt
    }

    /** Deletes all but the newest `keep` incident files. */
    public static func prune(directory: URL, keep: Int = keepIncidents) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        let incidents = names.filter { $0.hasSuffix(".ndjson") }.sorted()
        for name in incidents.dropLast(keep) {
            try? fileManager.removeItem(at: directory.appending(path: name))
        }
    }
}

/** Any JSON value, for picking one entry out of a report whose schema is
    Apple's and unversioned. A number that fits `Int64` stays an integer,
    since a `Double` rounds anything past 2^53. */
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case array([JSONValue])
    case bool(Bool)
    case integer(Int64)
    case null
    case number(Double)
    case object([String: JSONValue])
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .array(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .number(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}
