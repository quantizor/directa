import DirectaKit
import Foundation
import Testing
import os

@testable import DirectaDaemonCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "directa-sampler-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct SnapshotRead: Decodable {
    let entry: String
    let fileDescriptors: Int?
    let memory: MemorySample?
    let threads: ThreadSample?
}

private func snapshots(in directory: URL) -> [SnapshotRead] {
    let decoder = JSONCoding.decoder()
    return TelemetryLog.lastLines(in: directory, count: 10_000).compactMap {
        try? decoder.decode(SnapshotRead.self, from: Data($0.utf8))
    }.filter { $0.entry == "snapshot" }
}

/** A synchronous wait on purpose: holding the calling pool thread is the
    point of the starvation test. */
private func holdPoolThread(until gate: DispatchSemaphore) {
    gate.wait()
}

private let fastPolicy = TelemetryCadence.Policy(
    baselineSeconds: 0.02, burstSeconds: 0.02, burstThreadFraction: 0.5, burstTailSeconds: 60,
    thresholdCooldownSeconds: 60, thresholdThreadFraction: 0.75)

@Suite struct TelemetrySamplerTests {
    @Test func samplesRealKernelNumbers() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = TelemetryLog(directory: directory)
        let sampler = TelemetrySampler(
            configuration: .init(
                activity: DaemonActivity(), exitWatches: { 0 }, log: log, policy: fastPolicy,
                threadLimit: { nil }))
        sampler.start()
        let deadline = Date().addingTimeInterval(5)
        while snapshots(in: directory).count < 2, Date() < deadline {
            usleep(10_000)
        }
        sampler.stop()
        let first = try #require(snapshots(in: directory).first)
        let threads = try #require(first.threads)
        #expect(threads.total > 1)
        /** At least one: the suite's other tests run their own samplers in
            this process at the same time. */
        #expect(try #require(threads.byName[TelemetrySampler.threadName]) >= 1)
        #expect(threads.byName.values.reduce(0, +) == threads.total)
        #expect(threads.byState.values.reduce(0, +) == threads.total)
        let memory = try #require(first.memory)
        #expect(memory.footprint > 0)
        #expect(memory.resident > 0)
        /** Not compared with `footprint`: the kernel updates the lifetime
            maximum lazily, and a read can see it a page or so below the
            current value. */
        #expect(memory.footprintLifetimePeak > 0)
        #expect(try #require(first.fileDescriptors) >= 3)
    }

    /** Starves the cooperative pool for a bounded window: twice as many
        blocking tasks as cores, then a probe task behind them at the same
        priority (the runtime keeps a width per priority, so another one would
        get its own thread). Every freed pool thread takes a queued blocker
        before the probe, so the probe not running proves the starvation.
        Under the full parallel run the other suites may already hold every
        pool thread, so none of these blockers need to have started; the
        probe is the proof either way. The window is short because it starves
        every suite running in parallel in this process too. */
    @Test func keepsSamplingWhileTheCooperativePoolIsBlocked() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = TelemetryLog(directory: directory)
        let sampler = TelemetrySampler(
            configuration: .init(
                activity: DaemonActivity(), exitWatches: { 0 }, log: log, policy: fastPolicy,
                threadLimit: { nil }))
        let blockers = ProcessInfo.processInfo.activeProcessorCount * 2
        let gate = DispatchSemaphore(value: 0)
        let probeRan = OSAllocatedUnfairLock(initialState: false)
        for _ in 0..<blockers {
            Task.detached { holdPoolThread(until: gate) }
        }
        Task.detached { probeRan.withLock { $0 = true } }
        sampler.start()
        usleep(250_000)
        let during = snapshots(in: directory)
        let probeRanDuringWindow = probeRan.withLock { $0 }
        for _ in 0..<blockers { gate.signal() }
        sampler.stop()
        #expect(probeRanDuringWindow == false)
        #expect(during.count >= 3)
        let cooperative = during.last?.threads?.byName
            .filter { $0.key.hasSuffix(".cooperative") }
            .map(\.value)
            .reduce(0, +) ?? 0
        #expect(cooperative >= 1)
    }

    @Test func bootWritesMarksAndAnIncidentFromThePreviousRun() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DirectaPaths(dataDir: root.appending(path: "data"), logsDir: root.appending(path: "logs"))
        let previousLog = TelemetryLog(directory: paths.daemonTelemetryDir)
        let lastAt = Date().addingTimeInterval(-30)
        for index in 0..<5 {
            previousLog.append(
                TelemetryMark(
                    daemonPid: 4321, event: .slowOperation, kind: .lsof, label: "old \(index)",
                    time: lastAt.addingTimeInterval(Double(index - 4))))
        }
        previousLog.close()
        let activity = DaemonActivity()
        let telemetry = DaemonTelemetry.start(
            paths: paths, runningAsAgent: false, activity: activity, policy: fastPolicy, searchSystemLog: false)
        let stop = activity.begin(.stop, label: "/p::web: requested by stop")
        activity.end(stop, outcome: "stopped")
        #expect(telemetry.waitForIncident(timeoutSeconds: 10))
        telemetry.recordExit(reason: "test")
        telemetry.shutdown()

        let incidents = try FileManager.default.contentsOfDirectory(atPath: paths.daemonIncidentsDir.path)
        #expect(incidents.count == 1)
        let incident = try String(
            contentsOf: paths.daemonIncidentsDir.appending(path: try #require(incidents.first)), encoding: .utf8)
        let lines = incident.split(separator: "\n").map(String.init)
        #expect(lines.count == 7)
        #expect(lines[0].contains(#""entry":"incident""#))
        #expect(lines[0].contains(#""previousPid":4321"#))
        #expect(lines[0].contains(#""previousLineCount":5"#))
        #expect(lines[0].contains(#""launchdNote":"not running as the launchd agent"#))
        #expect(lines[1...5].allSatisfy { $0.contains(#""daemonPid":4321"#) })
        #expect(lines[6].contains(#""outcome":"skipped: system log search disabled""#))

        let current = TelemetryLog.lastLines(in: paths.daemonTelemetryDir, count: 10_000)
            .filter { !$0.contains(#""daemonPid":4321"#) }
        let events = current.compactMap { line -> String? in
            guard let range = line.range(of: #""event":""#) else { return nil }
            return String(line[range.upperBound...].prefix { $0 != "\"" })
        }
        #expect(events.first == "daemon-started")
        #expect(events.contains("stop-began"))
        #expect(events.contains("stop-ended"))
        #expect(events.last == "daemon-exiting")
        #expect(current.contains { $0.contains(#""entry":"snapshot""#) })
    }

    /** A thread limit of 2 puts any real process over the threshold, so the
        first sample is a threshold sample and the next ones are not (the
        rising edge has passed and the cooldown holds). */
    @Test func thresholdSampleCarriesDetailAMarkAndOnePersistedLogLine() throws {
        let recorder = try #require(DirectaLog.backend as? RecordingBackend)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = TelemetryLog(directory: directory)
        let activity = DaemonActivity()
        let stuck = activity.begin(.lsof, label: "lsof -nP -tiTCP:45999")
        defer { activity.end(stuck) }
        let sampler = TelemetrySampler(
            configuration: .init(
                activity: activity, exitWatches: { 0 }, log: log, policy: fastPolicy, threadLimit: { 2 }))
        sampler.start()
        let deadline = Date().addingTimeInterval(5)
        while snapshots(in: directory).count < 3, Date() < deadline {
            usleep(10_000)
        }
        sampler.stop()
        let lines = TelemetryLog.lastLines(in: directory, count: 10_000)
        let reasons = lines.compactMap { line -> String? in
            guard let range = line.range(of: #""reason":""#) else { return nil }
            return String(line[range.upperBound...].prefix { $0 != "\"" })
        }
        #expect(reasons.first == "threshold")
        #expect(reasons.dropFirst().allSatisfy { $0 == "burst" })
        #expect(lines.filter { $0.contains(#""threadDetail":["#) }.count == 1)
        let marks = lines.filter { $0.contains(#""event":"threads-high""#) }
        #expect(marks.count == 1)
        #expect(marks.first?.contains("limit 2; longest in flight: lsof lsof -nP -tiTCP:45999") == true)
        let logged = recorder.entries.filter {
            $0.level == .error && $0.message.contains("limit 2; longest in flight: lsof lsof -nP -tiTCP:45999")
        }
        #expect(logged.count == 1)
    }

    @Test func reportScanKeepsRelevantReportsInsideTheWindow() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let boot = Date(timeIntervalSince1970: 1_790_000_000)
        let windowStart = boot.addingTimeInterval(-120)
        let jetsam = [
            #"{"bug_type":"298"}"#,
            #"{"largestProcess":"node","processes":[{"name":"ddirecta","pid":6616,"rpages":945}]}"#,
        ].joined(separator: "\n")
        let files: [(name: String, text: String, modified: Date)] = [
            ("JetsamEvent-inside.ips", jetsam, boot.addingTimeInterval(-30)),
            ("ddirecta-after-boot.ips", "crash body", boot.addingTimeInterval(30)),
            ("JetsamEvent-too-old.ips", jetsam, windowStart.addingTimeInterval(-1)),
            ("ddirecta-too-late.ips", "late", boot.addingTimeInterval(61)),
            ("node-inside.ips", "other", boot.addingTimeInterval(-10)),
        ]
        for file in files {
            let url = folder.appending(path: file.name)
            try Data(file.text.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: file.modified], ofItemAtPath: url.path)
        }
        let found = DaemonTelemetry.diagnosticReports(
            folders: [folder, folder.appending(path: "missing")], windowStart: windowStart, bootTime: boot)
        #expect(found.map { ($0.path as NSString).lastPathComponent } == ["JetsamEvent-inside.ips", "ddirecta-after-boot.ips"])
        #expect(found.first?.excerpt == #"largestProcess=node {"name":"ddirecta","pid":6616,"rpages":945}"#)
        #expect(found.last?.excerpt == "crash body")
    }

    @Test func telemetryCanBeSwitchedOff() {
        #expect(DaemonTelemetry.isEnabled(environment: [:]))
        #expect(DaemonTelemetry.isEnabled(environment: ["DIRECTA_TELEMETRY": "on"]))
        #expect(!DaemonTelemetry.isEnabled(environment: ["DIRECTA_TELEMETRY": "off"]))
        #expect(!DaemonTelemetry.isEnabled(environment: ["DIRECTA_TELEMETRY": "OFF"]))
    }
}
