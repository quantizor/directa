import DirectaKit
import Foundation
import os

/** The daemon's telemetry at boot: reads what the previous run left, starts
    the sampler, turns in-flight activity into marks, and writes the boot
    incident file. Everything slow (launchctl, `log show`, report scans) runs
    on a background thread, so none of it delays the socket or the restore
    gate. Layout, bounds, and cadence: docs/macos-lifecycle.md "Daemon
    telemetry". */
public final class DaemonTelemetry: Sendable {
    /** Set to `off` to run the daemon with no telemetry at all. */
    public static let environmentKey = "DIRECTA_TELEMETRY"

    public static let processName = "ddirecta"
    public static let incidentThreadName = "dev.quantizor.directa.incident"
    /** Hard ceiling on the boot-time `log show`. */
    public static let logShowTimeoutSeconds = 60.0
    /** Ceiling on the boot-time `launchctl print`. */
    public static let launchctlTimeoutSeconds = 10.0

    public let activity: DaemonActivity
    private let incidentDone = DispatchSemaphore(value: 0)
    public let log: TelemetryLog
    public let paths: DirectaPaths
    private let pid: Int32
    public let sampler: TelemetrySampler
    /** Written once by the incident thread from `launchctl print`. */
    private let threadLimit: OSAllocatedUnfairLock<Int?>

    private static let active = OSAllocatedUnfairLock<DaemonTelemetry?>(initialState: nil)

    /** The running daemon's telemetry, for the process-exit hook. */
    public static var current: DaemonTelemetry? { active.withLock { $0 } }

    public static func isEnabled(environment: [String: String]) -> Bool {
        environment[environmentKey]?.lowercased() != "off"
    }

    private init(
        activity: DaemonActivity, log: TelemetryLog, paths: DirectaPaths, pid: Int32,
        policy: TelemetryCadence.Policy
    ) {
        self.activity = activity
        self.log = log
        self.paths = paths
        self.pid = pid
        let threadLimit = OSAllocatedUnfairLock<Int?>(initialState: nil)
        self.threadLimit = threadLimit
        self.sampler = TelemetrySampler(
            configuration: TelemetrySampler.Configuration(
                activity: activity, exitWatches: { ExitWatcher.shared.watchedCount }, lanes: BlockingLane.all,
                log: log, policy: policy,
                threadLimit: { threadLimit.withLock { $0 } }))
    }

    /** Boots telemetry. The previous run's tail is read before this run
        writes a line, so the incident holds only the previous run's lines. */
    @discardableResult
    public static func start(
        paths: DirectaPaths, runningAsAgent: Bool, activity: DaemonActivity = .shared,
        policy: TelemetryCadence.Policy = .standard, searchSystemLog: Bool = true
    ) -> DaemonTelemetry {
        let bootTime = Date()
        let previous = DaemonIncident.readPrevious(telemetryDirectory: paths.daemonTelemetryDir)
        let log = TelemetryLog(directory: paths.daemonTelemetryDir)
        let telemetry = DaemonTelemetry(
            activity: activity, log: log, paths: paths, pid: getpid(), policy: policy)
        active.withLock { $0 = telemetry }
        log.append(
            TelemetryMark(
                daemonPid: telemetry.pid, event: .daemonStarted, label: DirectaVersion.version, time: bootTime))
        let sampler = telemetry.sampler
        let pid = telemetry.pid
        activity.setObserver { event in
            if let mark = TelemetryMark.forActivity(event, daemonPid: pid, time: Date()) {
                log.append(mark)
            }
            if case .began(let token) = event, token.kind.triggersBurst {
                sampler.wakeNow()
            }
        }
        sampler.start()
        let thread = Thread {
            telemetry.writeIncident(
                bootTime: bootTime, previous: previous, runningAsAgent: runningAsAgent,
                searchSystemLog: searchSystemLog)
            telemetry.incidentDone.signal()
        }
        thread.name = incidentThreadName
        /** Utility, not background: background QoS throttles disk I/O and the
            `log show` child inherits it, so on a loaded machine the search
            would lag far behind boot. */
        thread.qualityOfService = .utility
        thread.start()
        return telemetry
    }

    /** The clean-exit mark; its absence as a run's last line is how the next
        boot tells a kill from an exit. The sampler and the activity marks are
        stopped first, so no line can land after it. */
    public func recordExit(reason: String) {
        activity.setObserver(nil)
        sampler.stop()
        log.append(TelemetryMark(daemonPid: pid, event: .daemonExiting, label: reason, time: Date()))
    }

    /** Blocks until the boot incident is fully written, for tests. */
    public func waitForIncident(timeoutSeconds: Double) -> Bool {
        incidentDone.wait(timeout: .now() + timeoutSeconds) == .success
    }

    /** Stops the sampler and detaches the observer, for tests; safe after
        `recordExit`. */
    public func shutdown() {
        activity.setObserver(nil)
        sampler.stop()
        log.close()
        Self.active.withLock { if $0 === self { $0 = nil } }
    }

    private func writeIncident(
        bootTime: Date, previous: DaemonIncident.Previous, runningAsAgent: Bool, searchSystemLog: Bool
    ) {
        var launchd: LaunchdExitRecord?
        var launchdNote: String?
        if runningAsAgent {
            let printed = LaunchdAdmin.shell(
                "/bin/launchctl", ["print", "gui/\(getuid())/\(LaunchdAdmin.label)"],
                timeoutSeconds: Self.launchctlTimeoutSeconds)
            if printed.status == 0 {
                let record = LaunchdExitRecord.parse(printed.output)
                launchd = record
                threadLimit.withLock { $0 = record.threadLimit }
            } else {
                launchdNote = "launchctl print exited \(printed.status): \(printed.output.prefix(200))"
            }
        } else {
            launchdNote = "not running as the launchd agent (started with --foreground or by hand)"
        }
        let directory = paths.daemonIncidentsDir
        let file = directory.appending(path: DaemonIncident.fileName(bootTime: bootTime, pid: pid))
        let incidentLog = IncidentFile(url: file)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try incidentLog.write(
                DaemonIncident.headerAndLines(
                    bootTime: bootTime, daemonPid: pid, launchd: launchd, launchdNote: launchdNote,
                    previous: previous))
        } catch {
            DirectaLog.daemon.error("telemetry: cannot write incident \(file.path): \(error)")
            return
        }
        DaemonIncident.prune(directory: directory)
        guard searchSystemLog else {
            incidentLog.append(
                IncidentSearchFinished(
                    diagnosticReports: 0, logShowSeconds: nil, matches: 0,
                    outcome: "skipped: system log search disabled", predicate: nil, time: Date(), windowEnd: nil,
                    windowStart: nil))
            return
        }
        if previous.exitedCleanly {
            incidentLog.append(
                IncidentSearchFinished(
                    diagnosticReports: 0, logShowSeconds: nil, matches: 0,
                    outcome: "skipped: the previous run exited cleanly", predicate: nil, time: Date(),
                    windowEnd: nil, windowStart: nil))
            return
        }
        let window = DaemonIncident.searchWindow(previousLastLineAt: previous.lastLineAt, bootTime: bootTime)
        let predicate = DaemonIncident.logPredicate(
            previousPid: previous.pid, label: LaunchdAdmin.label, processName: Self.processName)
        let began = ContinuousClock.now
        let shown = LaunchdAdmin.shell(
            "/usr/bin/log",
            [
                "show", "--start", DaemonIncident.logShowTime(window.start), "--end",
                DaemonIncident.logShowTime(window.end), "--predicate", predicate, "--style", "ndjson", "--info",
            ],
            timeoutSeconds: Self.logShowTimeoutSeconds)
        let seconds = DaemonActivity.seconds(began.duration(to: .now))
        let outcome: String
        var matches: [IncidentSystemLog] = []
        if shown.status == 0 {
            matches = DaemonIncident.parseLogShow(shown.output)
            outcome = "finished"
        } else if seconds >= Self.logShowTimeoutSeconds {
            outcome = "timed out"
        } else {
            outcome = "failed: log show exited \(shown.status): \(shown.output.prefix(200))"
        }
        for match in matches {
            incidentLog.append(match)
        }
        let reports = Self.diagnosticReports(
            folders: Self.reportFolders, windowStart: window.start, bootTime: bootTime)
        for report in reports {
            incidentLog.append(report)
        }
        incidentLog.append(
            IncidentSearchFinished(
                diagnosticReports: reports.count, logShowSeconds: seconds, matches: matches.count,
                outcome: outcome, predicate: predicate, time: Date(), windowEnd: window.end,
                windowStart: window.start))
    }

    static let reportFolders = [
        URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports"),
    ]

    /** JetsamEvent and daemon crash reports modified from the window's start
        to a minute past boot (a report can be written just after launchd has
        already respawned the daemon). */
    static func diagnosticReports(folders: [URL], windowStart: Date, bootTime: Date) -> [IncidentDiagnosticReport] {
        let fileManager = FileManager.default
        var found: [IncidentDiagnosticReport] = []
        for folder in folders {
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted()
            where DaemonIncident.isRelevantReport(name: name, processName: Self.processName) {
                let url = folder.appending(path: name)
                guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                    modified >= windowStart, modified <= bootTime.addingTimeInterval(60)
                else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                found.append(
                    IncidentDiagnosticReport(
                        excerpt: DaemonIncident.reportExcerpt(text: text, name: name, processName: Self.processName),
                        path: url.path, time: modified))
            }
        }
        return found
    }
}

/** Appends NDJSON lines to one incident file. Only the incident thread
    writes it. */
private struct IncidentFile {
    let url: URL

    func write(_ data: Data) throws {
        try data.write(to: url, options: .atomic)
    }

    func append<Line: TelemetryLine>(_ line: Line) {
        guard let encoded = try? NDJSON.encodeLine(line),
            let handle = try? FileHandle(forWritingTo: url)
        else {
            DirectaLog.daemon.error("telemetry: cannot append to incident \(url.path)")
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: encoded)
        } catch {
            DirectaLog.daemon.error("telemetry: cannot append to incident \(url.path): \(error)")
        }
    }
}
