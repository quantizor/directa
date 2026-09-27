import DirectaKit
import DirectaTestSupport
import Foundation
import Testing
import os

@testable import DirectaDaemonCore

private func temporaryDirectory() throws -> URL {
    try TemporaryTree.directory(named: "sampler")
}

private struct EntryOnly: Decodable {
    let entry: TelemetryEntryKind
}

/** Every line whose `entry` is `entry`, decoded as `T`. A line that is not
    JSON (one still being written) is skipped; a line of that entry that does
    not decode as `T` throws. */
private func decoded<T: Decodable>(_ lines: [String], entry: TelemetryEntryKind, as type: T.Type) throws -> [T] {
    let decoder = JSONCoding.decoder()
    return try lines.compactMap { line in
        let data = Data(line.utf8)
        guard (try? decoder.decode(EntryOnly.self, from: data))?.entry == entry else { return nil }
        return try decoder.decode(T.self, from: data)
    }
}

private func snapshots(in directory: URL) throws -> [TelemetrySnapshot] {
    try decoded(TelemetryLog.lastLines(in: directory, count: 10_000), entry: .snapshot, as: TelemetrySnapshot.self)
}

/** A synchronous wait on purpose: holding the calling pool thread is the
    point of the starvation test. */
private func holdPoolThread(until gate: DispatchSemaphore) {
    gate.wait()
}

private let fastPolicy = TelemetryCadence.Policy(
    baselineSeconds: 0.02, burstSeconds: 0.02, burstThreadFraction: 0.5, burstTailSeconds: 60,
    thresholdCooldownSeconds: 60, thresholdThreadFraction: 0.75)

@Suite(.temporaryTree) struct TelemetrySamplerTests {
    /** Also holds a width-1 lane with one job running and two queued, so the
        snapshot's lane pressure is a known answer. The jobs reach the lane
        from tasks, which a busy cooperative pool can start late, so every
        wait here is only a guard against hanging, and the gate opens however
        the wait ends. */
    @Test func samplesRealKernelNumbersAndLanePressure() async throws {
        let directory = try temporaryDirectory()
        let log = TelemetryLog(directory: directory)
        let lane = BlockingLane(name: "held", width: 1, activity: DaemonActivity())
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let jobs = (0..<3).map { _ in
            Task.detached {
                await lane.run {
                    entered.signal()
                    gate.wait()
                }
            }
        }
        let sampler = TelemetrySampler(
            configuration: .init(
                activity: DaemonActivity(), exitWatches: { 0 }, lanes: [lane], log: log, policy: fastPolicy,
                threadLimit: { nil }))
        let held = try await offPool { () throws -> Bool in
            defer { for _ in 0..<3 { gate.signal() } }
            guard entered.wait(timeout: .now() + 60) == .success else { return false }
            let queuedDeadline = Date().addingTimeInterval(60)
            while lane.pressure().queued < 2, Date() < queuedDeadline {
                usleep(5_000)
            }
            usleep(20_000)
            sampler.start()
            let deadline = Date().addingTimeInterval(60)
            while try snapshots(in: directory).count < 2, Date() < deadline {
                usleep(10_000)
            }
            sampler.stop()
            return true
        }
        try #require(held, "no lane job started within the guard's bound")
        for job in jobs { await job.value }
        #expect(lane.pressure() == LanePressure(name: "held", oldestQueuedSeconds: 0, queued: 0, running: 0, width: 1))
        let first = try #require(try snapshots(in: directory).first)
        let pressure = try #require(first.lanes.first)
        #expect(first.lanes.count == 1)
        #expect(pressure.name == "held")
        #expect(pressure.width == 1)
        #expect(pressure.running == 1)
        #expect(pressure.queued == 2)
        #expect(pressure.oldestQueuedSeconds >= 0.02)
        /** Never `interval`: a backlog forces the fast cadence. `threshold`
            is possible when the parallel suites push this process's thread
            count past the assumed limit's high-water mark. */
        #expect(first.reason != .interval)
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
        every suite running in parallel in this process too, and it is timed
        and closed from a thread of its own, since a pool thread could not
        run to close it. */
    @Test func keepsSamplingWhileTheCooperativePoolIsBlocked() async throws {
        let directory = try temporaryDirectory()
        let log = TelemetryLog(directory: directory)
        let sampler = TelemetrySampler(
            configuration: .init(
                activity: DaemonActivity(), exitWatches: { 0 }, lanes: [], log: log, policy: fastPolicy,
                threadLimit: { nil }))
        let blockers = ProcessInfo.processInfo.activeProcessorCount * 2
        let gate = DispatchSemaphore(value: 0)
        let probeRan = OSAllocatedUnfairLock(initialState: false)
        for _ in 0..<blockers {
            Task.detached { holdPoolThread(until: gate) }
        }
        Task.detached { probeRan.withLock { $0 = true } }
        let (during, probeRanDuringWindow) = try await offPool {
            defer {
                for _ in 0..<blockers { gate.signal() }
                sampler.stop()
            }
            sampler.start()
            usleep(250_000)
            return (try snapshots(in: directory), probeRan.withLock { $0 })
        }
        #expect(probeRanDuringWindow == false)
        #expect(during.count >= 3)
        let cooperative = during.last?.threads?.byName
            .filter { $0.key.hasSuffix(".cooperative") }
            .map(\.value)
            .reduce(0, +) ?? 0
        #expect(cooperative >= 1)
    }

    @Test func bootWritesMarksAndAnIncidentFromThePreviousRun() async throws {
        let root = try temporaryDirectory()
        let paths = DirectaPaths(dataDir: root.appending(path: "data"), logsDir: root.appending(path: "logs"))
        let previousLog = TelemetryLog(directory: paths.daemonTelemetryDir)
        let lastAt = JSONCoding.canonicalMs(Date().addingTimeInterval(-30))
        let previousMarks = (0..<5).map { index in
            TelemetryMark(
                daemonPid: 4321, event: .slowOperation, kind: .lsof, label: "old \(index)",
                time: lastAt.addingTimeInterval(Double(index - 4)))
        }
        for mark in previousMarks {
            previousLog.append(mark)
        }
        previousLog.close()
        let activity = DaemonActivity()
        let telemetry = DaemonTelemetry.start(
            paths: paths, runningAsAgent: false, activity: activity, policy: fastPolicy, searchSystemLog: false)
        let stop = activity.begin(.stop, label: "/p::web: requested by stop")
        activity.end(stop, outcome: "stopped")
        #expect(await offPool { telemetry.waitForIncident(timeoutSeconds: 10) })
        /** The sampler thread takes its first snapshot once the scheduler
            runs it, and a stop before then leaves none, so the exit waits
            for one. */
        let deadline = Date().addingTimeInterval(10)
        while try snapshots(in: paths.daemonTelemetryDir).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        telemetry.recordExit(code: 3, reason: "test")
        /** The process-exit hook after an exit that named its code writes nothing. */
        telemetry.recordExit(code: nil, reason: "exit")
        await offPool { telemetry.shutdown() }

        let incidents = try FileManager.default.contentsOfDirectory(atPath: paths.daemonIncidentsDir.path)
        #expect(incidents.count == 1)
        let incident = try String(
            contentsOf: paths.daemonIncidentsDir.appending(path: try #require(incidents.first)), encoding: .utf8)
        let lines = incident.split(separator: "\n").map(String.init)
        #expect(lines.count == 7)
        let header = try #require(try decoded(lines, entry: .incident, as: IncidentHeader.self).first)
        /** Boot time, and the gap derived from it, are the only volatile fields. */
        #expect(
            header
                == IncidentHeader(
                    daemonPid: getpid(), gapSeconds: header.gapSeconds,
                    launchd: .unavailable(note: "not running as the launchd agent (started with --foreground or by hand)"),
                    previousExitCode: nil, previousExitedCleanly: false, previousLastLineAt: lastAt, previousLineCount: 5, previousPid: 4321,
                    time: header.time))
        #expect(try #require(header.gapSeconds) >= 30)
        #expect(try decoded(Array(lines[1...5]), entry: .mark, as: TelemetryMark.self) == previousMarks)
        let finished = try #require(try decoded(lines, entry: .searchFinished, as: IncidentSearchFinished.self).last)
        #expect(
            finished
                == IncidentSearchFinished(
                    diagnosticReports: 0, logShowSeconds: nil, matches: 0,
                    outcome: "skipped: system log search disabled", predicate: nil, time: finished.time,
                    truncated: false, windowEnd: nil, windowStart: nil))

        let current = TelemetryLog.lastLines(in: paths.daemonTelemetryDir, count: 10_000)
        let marks = try decoded(current, entry: .mark, as: TelemetryMark.self)
            .filter { $0.daemonPid == getpid() && $0.event != .threadsHigh }
        #expect(marks.map(\.event) == [.daemonStarted, .stopBegan, .stopEnded, .daemonExiting])
        let exiting = try #require(marks.last)
        #expect(
            exiting == TelemetryMark(daemonPid: getpid(), event: .daemonExiting, exitCode: 3, label: "test", time: exiting.time))
        let ended = try #require(marks.first { $0.event == .stopEnded })
        #expect(
            ended
                == TelemetryMark(
                    daemonPid: getpid(), event: .stopEnded, label: "/p::web: requested by stop", outcome: "stopped",
                    seconds: ended.seconds, time: ended.time))
        #expect(try decoded(current, entry: .snapshot, as: TelemetrySnapshot.self).isEmpty == false)
    }

    /** A thread limit of 2 puts any real process over the threshold, so the
        first sample is a threshold sample and the next ones are not (the
        rising edge has passed and the cooldown holds). */
    @Test func thresholdSampleCarriesDetailAMarkAndOnePersistedLogLine() async throws {
        let recorder = try #require(DirectaLog.backend as? RecordingBackend)
        let directory = try temporaryDirectory()
        let log = TelemetryLog(directory: directory)
        let activity = DaemonActivity()
        let stuck = activity.begin(.lsof, label: "lsof -nP -tiTCP:45999")
        defer { activity.end(stuck) }
        let sampler = TelemetrySampler(
            configuration: .init(
                activity: activity, exitWatches: { 0 }, lanes: [], log: log, policy: fastPolicy,
                threadLimit: { 2 }))
        sampler.start()
        let deadline = Date().addingTimeInterval(5)
        while try snapshots(in: directory).count < 3, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await offPool { sampler.stop() }
        let lines = TelemetryLog.lastLines(in: directory, count: 10_000)
        let samples = try decoded(lines, entry: .snapshot, as: TelemetrySnapshot.self)
        #expect(samples.first?.reason == .threshold)
        #expect(samples.dropFirst().allSatisfy { $0.reason == .burst })
        #expect(samples.map { $0.threadDetail != nil } == [true] + Array(repeating: false, count: samples.count - 1))
        let first = try #require(samples.first)
        #expect(first.threadDetail?.count == first.threads?.total)
        let marks = try decoded(lines, entry: .mark, as: TelemetryMark.self)
        #expect(marks.map(\.event) == [.threadsHigh])
        #expect(marks.first?.label?.contains("limit 2; longest in flight: lsof lsof -nP -tiTCP:45999") == true)
        let logged = recorder.entries.filter {
            $0.level == .error && $0.message.contains("limit 2; longest in flight: lsof lsof -nP -tiTCP:45999")
        }
        #expect(logged.count == 1)
    }

    @Test func reportScanKeepsRelevantReportsInsideTheWindow() throws {
        let folder = try temporaryDirectory()
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
