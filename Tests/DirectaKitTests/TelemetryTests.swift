import DirectaTestSupport
import Foundation
import Testing
import os

@testable import DirectaKit

/** `launchctl print` of a throwaway gui job running `/bin/sh -c 'exit 3'`,
    captured after it exited and before bootout. The plist path and the
    SSH_AUTH_SOCK listener id are genericized; every other byte is verbatim. */
private let printedExitCode = [
    "gui/501/local.telemetryprobe.code = {",
    "\tactive count = 0",
    "\tpath = /private/tmp/probe/local.telemetryprobe.code.plist",
    "\ttype = LaunchAgent",
    "\tstate = not running",
    "",
    "\tprogram = /bin/sh",
    "\targuments = {",
    "\t\t/bin/sh",
    "\t\t-c",
    "\t\texit 3",
    "\t}",
    "",
    "\tinherited environment = {",
    "\t\tSSH_AUTH_SOCK => /var/run/com.apple.launchd.probe/Listeners",
    "\t}",
    "",
    "\tdefault environment = {",
    "\t\tPATH => /usr/bin:/bin:/usr/sbin:/sbin",
    "\t}",
    "",
    "\tenvironment = {",
    "\t\tOSLogRateLimit => 64",
    "\t\tXPC_SERVICE_NAME => local.telemetryprobe.code",
    "\t}",
    "",
    "\tdomain = gui/501 [100023]",
    "\tasid = 100023",
    "\tminimum runtime = 10",
    "\texit timeout = 5",
    "\truns = 1",
    "\tlast exit code = 3",
    "",
    "\tresource coalition = {",
    "\t\tID = 230067",
    "\t\ttype = resource",
    "\t\tstate = active",
    "\t\tactive count = 1",
    "\t\tname = local.telemetryprobe.code",
    "\t}",
    "",
    "\tjetsam coalition = {",
    "\t\tID = 230068",
    "\t\ttype = jetsam",
    "\t\tstate = active",
    "\t\tactive count = 1",
    "\t\tname = local.telemetryprobe.code",
    "\t}",
    "",
    "\tspawn type = daemon (3)",
    "\tjetsam priority = 40",
    "\tjetsam memory limit (active) = (unlimited)",
    "\tjetsam memory limit (inactive) = (unlimited)",
    "\tjetsamproperties category = daemon",
    "\tjetsam thread limit = 32",
    "\tcpumon = default",
    "",
    "\tproperties = runatload | inferred program",
    "}",
].joined(separator: "\n")

/** The same capture for `/bin/sh -c 'kill -9 $$'`: only the name, the
    arguments, and the exit line differ. */
private let printedKilled =
    printedExitCode
    .replacing("local.telemetryprobe.code", with: "local.telemetryprobe.signal")
    .replacing("\t\texit 3", with: "\t\tkill -9 $$")
    .replacing("\tlast exit code = 3", with: "\tlast terminating signal = Killed: 9")

/** The installed agent while running, captured from `launchctl print
    gui/501/dev.quantizor.directa` (environment blocks and the BTM uuid
    dropped): launchd reports `(never exited)` and an `immediate reason`. */
private let printedAgentRunning = [
    "gui/501/dev.quantizor.directa = {",
    "\tactive count = 1",
    "\tpath = (submitted by smd.41750)",
    "\ttype = Submitted",
    "\tmanaged_by = com.apple.xpc.ServiceManagement",
    "\tstate = running",
    "",
    "\tprogram identifier = Contents/Helpers/ddirecta (mode: 2)",
    "\tdomain = gui/501 [100023]",
    "\tminimum runtime = 10",
    "\texit timeout = 60",
    "\truns = 1",
    "\tpid = 21443",
    "\timmediate reason = speculative",
    "\tforks = 7054",
    "\texecs = 1",
    "\tlast exit code = (never exited)",
    "",
    "\tspawn type = interactive (4)",
    "\tjetsam priority = 40",
    "\tjetsam memory limit (active) = (unlimited)",
    "\tjetsam memory limit (inactive) = (unlimited)",
    "\tjetsamproperties category = daemon",
    "\tjetsam thread limit = 32",
    "\tcpumon = default",
    "\tjob state = running",
    "}",
].joined(separator: "\n")

private func temporaryDirectory() throws -> URL {
    try TemporaryTree.directory(named: "telemetry")
}

private func date(_ iso: String) throws -> Date {
    try #require(JSONCoding.parseISO8601(iso))
}

private func encoded<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try NDJSON.encodeLine(value), as: UTF8.self)
}

/** Every line decoded as `T`; a line that does not decode throws. */
private func decoded<T: Decodable>(_ lines: [String], as type: T.Type) throws -> [T] {
    let decoder = JSONCoding.decoder()
    return try lines.map { try decoder.decode(T.self, from: Data($0.utf8)) }
}

@Suite struct TelemetryRecordTests {
    @Test func snapshotEncodesEveryFieldSortedOnOneLine() throws {
        let snapshot = TelemetrySnapshot(
            activity: ActivitySnapshot(
                connectedClients: 2,
                longestRunning: [InFlightEntry(kind: .stop, label: "/p::web: requested by restart", seconds: 12.5)],
                operations: [.stop: ActivityGroup(count: 1, oldestLabel: "/p::web: requested by restart", oldestSeconds: 12.5)],
                requests: ["server.restart": ActivityGroup(count: 1, oldestLabel: nil, oldestSeconds: 12.6)],
                serverPhases: [.stopping: 1]),
            daemonPid: 4242, exitWatches: 3, fileDescriptors: 41,
            lanes: [
                LanePressure(name: "repository", oldestQueuedSeconds: 4.25, queued: 3, running: 2, width: 2),
                LanePressure(name: "system", oldestQueuedSeconds: 0, queued: 0, running: 1, width: 4),
            ],
            memory: MemorySample(
                compressed: 1, compressedLifetime: 2, compressedPeak: 3, footprint: 4, footprintLifetimePeak: 5,
                internal: 6, internalPeak: 7, resident: 8),
            reason: .threshold, sampleMicroseconds: 180,
            system: SystemSample(loadAverage: [1.5, 2, 3.25], memoryPressure: "normal"),
            threadDetail: [
                ThreadDetail(cpuPercent: 0.5, name: "(unnamed)", state: .waiting, systemSeconds: 0.25, userSeconds: 1)
            ],
            threads: ThreadSample(
                byName: ["(unnamed)": 20, "com.apple.root.default-qos.cooperative": 4], byState: [.waiting: 24],
                limit: 32, total: 24,
                workqueue: WorkqueueSample(blocked: 18, limitsExceeded: ["constrained"], running: 2, total: 20)),
            time: try date("2026-09-26T10:00:00.123Z"), uptimeSeconds: 99.5)
        #expect(
            try encoded(snapshot)
                == #"{"activity":{"connectedClients":2,"longestRunning":[{"kind":"stop","label":"/p::web: requested by restart","seconds":12.5}],"operations":{"stop":{"count":1,"oldestLabel":"/p::web: requested by restart","oldestSeconds":12.5}},"requests":{"server.restart":{"count":1,"oldestSeconds":12.6}},"serverPhases":{"stopping":1}},"daemonPid":4242,"entry":"snapshot","exitWatches":3,"fileDescriptors":41,"lanes":[{"name":"repository","oldestQueuedSeconds":4.25,"queued":3,"running":2,"width":2},{"name":"system","oldestQueuedSeconds":0,"queued":0,"running":1,"width":4}],"memory":{"compressed":1,"compressedLifetime":2,"compressedPeak":3,"footprint":4,"footprintLifetimePeak":5,"internal":6,"internalPeak":7,"resident":8},"reason":"threshold","sampleMicroseconds":180,"system":{"loadAverage":[1.5,2,3.25],"memoryPressure":"normal"},"threadDetail":[{"cpuPercent":0.5,"name":"(unnamed)","state":"waiting","systemSeconds":0.25,"userSeconds":1}],"threads":{"byName":{"(unnamed)":20,"com.apple.root.default-qos.cooperative":4},"byState":{"waiting":24},"limit":32,"total":24,"workqueue":{"blocked":18,"limitsExceeded":["constrained"],"running":2,"total":20}},"time":"2026-09-26T10:00:00.123Z","uptimeSeconds":99.5}"#
                + "\n")
    }

    @Test func refusedKernelReadsAreOmittedNotZero() throws {
        let snapshot = TelemetrySnapshot(
            activity: ActivitySnapshot(
                connectedClients: 0, longestRunning: [], operations: [:], requests: [:], serverPhases: [:]),
            daemonPid: 1, exitWatches: 0, fileDescriptors: nil, lanes: [], memory: nil, reason: .interval,
            sampleMicroseconds: 1, system: SystemSample(loadAverage: [], memoryPressure: "unreadable"),
            threadDetail: [
                ThreadDetail(cpuPercent: nil, name: "(unnamed)", state: .unknown, systemSeconds: nil, userSeconds: nil)
            ],
            threads: nil, time: try date("2026-09-26T10:00:00.000Z"), uptimeSeconds: 0)
        #expect(
            try encoded(snapshot)
                == #"{"activity":{"connectedClients":0,"longestRunning":[],"operations":{},"requests":{},"serverPhases":{}},"daemonPid":1,"entry":"snapshot","exitWatches":0,"lanes":[],"reason":"interval","sampleMicroseconds":1,"system":{"loadAverage":[],"memoryPressure":"unreadable"},"threadDetail":[{"name":"(unnamed)","state":"unknown"}],"time":"2026-09-26T10:00:00.000Z","uptimeSeconds":0}"#
                + "\n")
    }

    @Test func markEncoding() throws {
        let mark = TelemetryMark(
            daemonPid: 7, event: .slowOperation, kind: .git, label: "git rev-parse in /p", outcome: nil,
            seconds: 2.5, time: try date("2026-09-26T10:00:01.000Z"))
        #expect(
            try encoded(mark)
                == #"{"daemonPid":7,"entry":"mark","event":"slow-operation","kind":"git","label":"git rev-parse in /p","seconds":2.5,"time":"2026-09-26T10:00:01.000Z"}"#
                + "\n")
    }

    @Test func pressureAndWorkqueueNames() {
        #expect(SystemSample.pressureName(level: 1) == "normal")
        #expect(SystemSample.pressureName(level: 2) == "warning")
        #expect(SystemSample.pressureName(level: 4) == "critical")
        #expect(SystemSample.pressureName(level: 9) == "level 9")
        #expect(WorkqueueSample.limitNames(state: 0) == [])
        #expect(WorkqueueSample.limitNames(state: 0x1 | 0x2 | 0x4 | 0x8 | 0x10)
            == ["constrained", "total", "cooperative", "active-constrained"])
        #expect(ThreadRunState(machState: 1) == .running)
        #expect(ThreadRunState(machState: 3) == .waiting)
        #expect(ThreadRunState(machState: 4) == .uninterruptible)
        #expect(ThreadRunState(machState: 42) == .unknown)
    }

    @Test func executableKinds() {
        #expect(ActivityKind.forExecutable("/usr/bin/git") == .git)
        #expect(ActivityKind.forExecutable("/bin/launchctl") == .launchctl)
        #expect(ActivityKind.forExecutable("/usr/sbin/lsof") == .lsof)
        #expect(ActivityKind.forExecutable("/bin/ps") == .ps)
        #expect(ActivityKind.forExecutable("/usr/bin/log") == .logShow)
        #expect(ActivityKind.forExecutable("/bin/zsh") == .subprocess)
        #expect(ActivityKind.allCases.filter(\.triggersBurst).map(\.rawValue).sorted()
            == ["git", "launchctl", "lsof", "ps", "restart", "spawn-wait", "stop", "stop-wait", "subprocess"])
    }
}

@Suite struct DaemonActivityTests {
    @Test func snapshotGroupsByKindAndMethodWithOldestAge() throws {
        let activity = DaemonActivity()
        let base = ContinuousClock.now
        let stop = activity.begin(.stop, label: "/p::web: requested by stop")
        let git = activity.begin(.git, label: "git rev-parse")
        let request = activity.begin(.request, label: "server.stop")
        let second = activity.begin(.request, label: "server.stop")
        activity.clientConnected()
        activity.clientConnected()
        activity.clientDisconnected()
        activity.recordPhase(.running, key: "a")
        activity.recordPhase(.running, key: "b")
        activity.recordPhase("stopping", key: "c")
        activity.forgetPhase(key: "b")
        let snapshot = activity.snapshot(now: base.advanced(by: .seconds(5)))
        #expect(snapshot.connectedClients == 1)
        #expect(snapshot.serverPhases == [.running: 1, .stopping: 1])
        #expect(Set(snapshot.operations.keys) == [.stop, .git])
        #expect(snapshot.operations[.stop]?.count == 1)
        #expect(snapshot.operations[.stop]?.oldestLabel == "/p::web: requested by stop")
        let requestGroup = try #require(snapshot.requests["server.stop"])
        #expect(requestGroup.count == 2)
        #expect(requestGroup.oldestLabel == nil)
        #expect(requestGroup.oldestSeconds > 4.9 && requestGroup.oldestSeconds <= 5)
        #expect(snapshot.longestRunning.map(\.kind) == [.stop, .git, .request, .request])
        for token in [stop, git, request, second] {
            activity.end(token)
        }
        let after = activity.snapshot()
        #expect(after.operations.isEmpty)
        #expect(after.requests.isEmpty)
        #expect(after.longestRunning.isEmpty)
    }

    @Test func longestRunningIsCappedAndLabelsAreTrimmed() {
        let activity = DaemonActivity()
        let tokens = (0..<(DaemonActivity.longestRunningCap + 4)).map {
            activity.begin(.lsof, label: "lsof \($0)")
        }
        let long = activity.begin(.subprocess, label: String(repeating: "x", count: 500))
        let snapshot = activity.snapshot()
        #expect(snapshot.longestRunning.count == DaemonActivity.longestRunningCap)
        #expect(snapshot.longestRunning.first?.label == "lsof 0")
        #expect(snapshot.operations[.lsof]?.count == DaemonActivity.longestRunningCap + 4)
        #expect(snapshot.operations[.subprocess]?.oldestLabel?.count == DaemonActivity.labelCap + 3)
        for token in tokens + [long] {
            activity.end(token)
        }
    }

    @Test func triggerStateFollowsBurstKindsOnly() throws {
        let activity = DaemonActivity()
        #expect(activity.triggerState().inFlight == false)
        #expect(activity.triggerState().lastAt == nil)
        let request = activity.begin(.request, label: "server.status")
        #expect(activity.triggerState().inFlight == false)
        #expect(activity.triggerState().lastAt == nil)
        let stop = activity.begin(.stop, label: "x")
        #expect(activity.triggerState().inFlight == true)
        let began = try #require(activity.triggerState().lastAt)
        activity.end(stop)
        activity.end(request)
        let state = activity.triggerState()
        #expect(state.inFlight == false)
        #expect(try #require(state.lastAt) >= began)
    }

    /** The boot incident's `launchctl print` is a trigger kind, but it reads
        the daemon itself, so inside `selfDirected` it neither counts as in
        flight nor starts the burst tail; the same kind outside still does. */
    @Test func selfDirectedWorkNeverTriggersTheBurst() throws {
        let activity = DaemonActivity()
        let token = DaemonActivity.selfDirected { activity.begin(.launchctl, label: "launchctl print") }
        #expect(token.triggersBurst == false)
        #expect(activity.triggerState().inFlight == false)
        activity.end(token)
        #expect(activity.triggerState().lastAt == nil)
        let outside = activity.begin(.launchctl, label: "launchctl bootout")
        #expect(outside.triggersBurst == true)
        #expect(activity.triggerState().inFlight == true)
        activity.end(outside)
        #expect(activity.triggerState().lastAt != nil)
    }

    @Test func observerHearsBeginAndEndOutsideTheLock() {
        let activity = DaemonActivity()
        let heard = LockedArray()
        activity.setObserver { event in
            switch event {
            case .began(let token):
                heard.append("began \(token.kind.rawValue)")
                /** Reentrancy: an observer that reads the registry must not deadlock. */
                _ = activity.snapshot()
            case .ended(let token, let outcome, _):
                heard.append("ended \(token.kind.rawValue) \(outcome ?? "-")")
            case .laneWaited(let lane, let seconds):
                heard.append("lane \(lane) \(seconds)")
            }
        }
        let token = activity.begin(.restart, label: "r")
        activity.end(token, outcome: "stopped")
        activity.measure(.git, label: "g") {}
        activity.recordLaneWait(lane: "system", seconds: 3.5)
        activity.setObserver(nil)
        activity.end(activity.begin(.stop, label: "after"))
        activity.recordLaneWait(lane: "system", seconds: 9)
        #expect(
            heard.values == [
                "began restart", "ended restart stopped", "began git", "ended git -", "lane system 3.5",
            ])
    }

    @Test func concurrentBeginAndEndLeaveNothingInFlight() async {
        let activity = DaemonActivity()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                group.addTask {
                    for inner in 0..<200 {
                        let token = activity.begin(index % 2 == 0 ? .git : .request, label: "\(index)-\(inner)")
                        if inner % 50 == 0 { _ = activity.snapshot() }
                        activity.end(token)
                    }
                }
            }
        }
        let snapshot = activity.snapshot()
        #expect(snapshot.operations.isEmpty)
        #expect(snapshot.requests.isEmpty)
    }

    @Test func marksForActivityEvents() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let stop = DaemonActivity.Token(id: 1, kind: .stop, label: "/p::web: why", startedAt: .now)
        let git = DaemonActivity.Token(id: 2, kind: .git, label: "git x", startedAt: .now)
        let request = DaemonActivity.Token(id: 3, kind: .request, label: "server.wait", startedAt: .now)
        #expect(
            TelemetryMark.forActivity(.began(stop), daemonPid: 9, time: now)
                == TelemetryMark(daemonPid: 9, event: .stopBegan, label: "/p::web: why", time: now))
        #expect(
            TelemetryMark.forActivity(.ended(stop, outcome: "stopped", seconds: 7.2), daemonPid: 9, time: now)
                == TelemetryMark(
                    daemonPid: 9, event: .stopEnded, label: "/p::web: why", outcome: "stopped", seconds: 7.2,
                    time: now))
        #expect(TelemetryMark.forActivity(.began(git), daemonPid: 9, time: now) == nil)
        #expect(TelemetryMark.forActivity(.ended(git, outcome: nil, seconds: 2.0), daemonPid: 9, time: now) == nil)
        #expect(
            TelemetryMark.forActivity(.ended(git, outcome: nil, seconds: 2.01), daemonPid: 9, time: now)
                == TelemetryMark(
                    daemonPid: 9, event: .slowOperation, kind: .git, label: "git x", seconds: 2.01, time: now))
        #expect(
            TelemetryMark.forActivity(.ended(request, outcome: nil, seconds: 60), daemonPid: 9, time: now) == nil)
        #expect(
            TelemetryMark.forActivity(.laneWaited(lane: "repository", seconds: 3.2), daemonPid: 9, time: now)
                == TelemetryMark(daemonPid: 9, event: .slowLaneWait, label: "repository", seconds: 3.2, time: now))
    }
}

private final class LockedArray: Sendable {
    private let lock = OSAllocatedUnfairLock<[String]>(initialState: [])
    func append(_ value: String) { lock.withLock { $0.append(value) } }
    var values: [String] { lock.withLock { $0 } }
}

@Suite struct TelemetryCadenceTests {
    private func input(
        threads: Int? = 6, limit: Int? = 32, inFlight: Bool = false, sinceTrigger: Double? = nil,
        sinceThreshold: Double? = nil, previousAbove: Bool = false
    ) -> TelemetryCadence.Input {
        TelemetryCadence.Input(
            previousAboveThreshold: previousAbove, secondsSinceTrigger: sinceTrigger,
            secondsSinceThresholdSnapshot: sinceThreshold, threadCount: threads, threadLimit: limit,
            triggerInFlight: inFlight)
    }

    @Test func baselineWhenIdle() {
        #expect(
            TelemetryCadence.decide(input())
                == .init(aboveThreshold: false, nextSampleSeconds: 10, reason: .interval, threadsTrigger: false))
        #expect(TelemetryCadence.decide(input(threads: nil)).reason == .interval)
    }

    @Test func burstWhileWorkIsInFlightAndForTheTail() {
        #expect(TelemetryCadence.decide(input(inFlight: true)).nextSampleSeconds == 1)
        #expect(TelemetryCadence.decide(input(inFlight: true)).reason == .burst)
        #expect(TelemetryCadence.decide(input(sinceTrigger: 59.9)).nextSampleSeconds == 1)
        #expect(TelemetryCadence.decide(input(sinceTrigger: 60)).nextSampleSeconds == 10)
        #expect(TelemetryCadence.decide(input(sinceTrigger: 600)).reason == .interval)
    }

    @Test func threadFractionsUseTheLimitOrTheAssumedOne() {
        #expect(TelemetryCadence.Policy.standard.burstThreads(limit: 32) == 16)
        #expect(TelemetryCadence.Policy.standard.thresholdThreads(limit: 32) == 24)
        #expect(TelemetryCadence.Policy.standard.burstThreads(limit: 5) == 3)
        #expect(
            TelemetryCadence.decide(input(threads: 15))
                == .init(aboveThreshold: false, nextSampleSeconds: 10, reason: .interval, threadsTrigger: false))
        #expect(
            TelemetryCadence.decide(input(threads: 16))
                == .init(aboveThreshold: false, nextSampleSeconds: 1, reason: .burst, threadsTrigger: true))
        #expect(TelemetryCadence.decide(input(threads: 16, limit: nil)).threadsTrigger == true)
        #expect(TelemetryCadence.decide(input(threads: 16, limit: 64)).threadsTrigger == false)
    }

    @Test func thresholdOnlyOnARisingEdgeOutsideTheCooldown() {
        #expect(
            TelemetryCadence.decide(input(threads: 24))
                == .init(aboveThreshold: true, nextSampleSeconds: 1, reason: .threshold, threadsTrigger: true))
        #expect(TelemetryCadence.decide(input(threads: 30, previousAbove: true)).reason == .burst)
        #expect(TelemetryCadence.decide(input(threads: 24, sinceThreshold: 59)).reason == .burst)
        #expect(TelemetryCadence.decide(input(threads: 24, sinceThreshold: 60)).reason == .threshold)
        #expect(TelemetryCadence.decide(input(threads: 23)).aboveThreshold == false)
    }
}

@Suite(.temporaryTree) struct TelemetryLogTests {
    private func mark(_ index: Int, at time: Date) -> TelemetryMark {
        TelemetryMark(daemonPid: 100, event: .slowOperation, kind: .lsof, label: "line \(index)", time: time)
    }

    @Test func rotationKeepsTheBoundAndEveryLineStaysWhole() throws {
        let directory = try temporaryDirectory()
        let log = TelemetryLog(directory: directory, keepRotated: 2, maxBytes: 1000)
        let start = try date("2026-09-26T10:00:00.000Z")
        for index in 0..<200 {
            log.append(mark(index, at: start.addingTimeInterval(Double(index))))
        }
        log.close()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["telemetry.log", "telemetry.log.1", "telemetry.log.2"])
        for name in names {
            let size = try #require(
                try FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)[.size] as? Int)
            #expect(size <= 1000)
        }
        #expect(log.failedWrites == 0)
        let marks = try decoded(TelemetryLog.lastLines(in: directory, count: 1000, keepRotated: 2), as: TelemetryMark.self)
        #expect(marks == ((200 - marks.count)..<200).map { mark($0, at: start.addingTimeInterval(Double($0))) })
        #expect(marks.count < 200)
        #expect(marks.last?.label == "line 199")
    }

    @Test func timesAreClampedMonotonicAcrossAReopen() throws {
        let directory = try temporaryDirectory()
        let later = try date("2026-09-26T10:00:05.000Z")
        let earlier = try date("2026-09-26T10:00:01.000Z")
        let first = TelemetryLog(directory: directory)
        first.append(mark(0, at: later))
        first.append(mark(1, at: earlier))
        first.close()
        let second = TelemetryLog(directory: directory)
        second.append(mark(2, at: earlier))
        second.close()
        let decoder = JSONCoding.decoder()
        let times = TelemetryLog.lastLines(in: directory, count: 10).map {
            TelemetryLog.LineHead(line: $0, decoder: decoder)?.time
        }
        #expect(times == [later, later, later])
    }

    @Test func tailReadsAcrossChunksAndKeepsATornLastLine() throws {
        let directory = try temporaryDirectory()
        let url = directory.appending(path: "t.log")
        let body = (0..<50).map { "line \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n")
        try Data((body + "\ntorn").utf8).write(to: url)
        let tail = TelemetryLog.tailLines(of: url, count: 3, chunkBytes: 16)
        #expect(tail.count == 3)
        #expect(tail[0].hasPrefix("line 48 "))
        #expect(tail[1].hasPrefix("line 49 "))
        #expect(tail[2] == "torn")
        #expect(TelemetryLog.tailLines(of: directory.appending(path: "missing"), count: 3) == [])
        #expect(TelemetryLog.tailLines(of: url, count: 0) == [])
    }
}

@Suite(.temporaryTree) struct DaemonIncidentTests {
    @Test func parsesAnExitCodeFromARealPrint() {
        let record = LaunchdExitRecord.parse(printedExitCode)
        #expect(
            record
                == LaunchdExitRecord(
                    exitCode: 3, exitReason: nil, immediateReason: nil,
                    rawLines: [
                        "state = not running", "runs = 1", "last exit code = 3", "spawn type = daemon (3)",
                        "jetsam priority = 40", "jetsam memory limit (active) = (unlimited)",
                        "jetsam memory limit (inactive) = (unlimited)", "jetsamproperties category = daemon",
                        "jetsam thread limit = 32",
                    ],
                    runs: 1, spawnType: "daemon (3)", terminatingSignal: nil, threadLimit: 32))
    }

    @Test func parsesATerminatingSignalFromARealPrint() {
        let record = LaunchdExitRecord.parse(printedKilled)
        #expect(record.exitCode == nil)
        #expect(record.terminatingSignal == 9)
        #expect(record.rawLines.contains("last terminating signal = Killed: 9"))
        #expect(!record.rawLines.contains { $0.contains("kill -9") })
    }

    @Test func parsesTheRunningAgent() {
        let record = LaunchdExitRecord.parse(printedAgentRunning)
        #expect(record.exitCode == nil)
        #expect(record.terminatingSignal == nil)
        #expect(record.immediateReason == "speculative")
        #expect(record.spawnType == "interactive (4)")
        #expect(record.threadLimit == 32)
        #expect(record.rawLines.contains("last exit code = (never exited)"))
        #expect(record.rawLines.contains("pid = 21443"))
        #expect(record.rawLines.contains("forks = 7054"))
        #expect(record.rawLines.contains("job state = running"))
    }

    @Test func previousRunIsReadFromRotatedFilesOldestFirst() throws {
        let directory = try temporaryDirectory()
        /** About 60 lines per file, so the newest 180 span the current file
            and at least two rotations. */
        let log = TelemetryLog(directory: directory, keepRotated: 4, maxBytes: 8000)
        let start = try date("2026-09-26T10:00:00.000Z")
        for index in 0..<400 {
            log.append(
                TelemetryMark(
                    daemonPid: 555, event: .slowOperation, kind: .git, label: "n\(index)",
                    time: start.addingTimeInterval(Double(index))))
        }
        log.close()
        let rotated = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0.hasPrefix("telemetry.log.")
        }
        #expect(rotated.count >= 2)
        let previous = DaemonIncident.readPrevious(telemetryDirectory: directory)
        #expect(
            try decoded(previous.lines, as: TelemetryMark.self).map(\.label)
                == (220..<400).map { "n\($0)" })
        #expect(previous.pid == 555)
        #expect(previous.lastLineAt == start.addingTimeInterval(399))
        #expect(previous.exitedCleanly == false)
    }

    @Test func aCleanExitMarkIsRecognized() throws {
        let directory = try temporaryDirectory()
        let log = TelemetryLog(directory: directory)
        log.append(TelemetryMark(daemonPid: 1, event: .daemonExiting, label: "exit", time: Date()))
        log.close()
        #expect(DaemonIncident.readPrevious(telemetryDirectory: directory).exitedCleanly == true)

        /** A line from the same run landing after the mark still reads clean;
            a later run's lines after an earlier run's mark do not. */
        let straggler = TelemetryLog(directory: directory)
        straggler.append(TelemetryMark(daemonPid: 1, event: .threadsHigh, label: "late", time: Date()))
        straggler.close()
        #expect(DaemonIncident.readPrevious(telemetryDirectory: directory).exitedCleanly == true)
        let nextRun = TelemetryLog(directory: directory)
        nextRun.append(TelemetryMark(daemonPid: 2, event: .daemonStarted, label: "2.0.0", time: Date()))
        nextRun.close()
        let killed = DaemonIncident.readPrevious(telemetryDirectory: directory)
        #expect(killed.exitedCleanly == false)
        #expect(killed.pid == 2)
        let empty = try temporaryDirectory()
        #expect(
            DaemonIncident.readPrevious(telemetryDirectory: empty)
                == DaemonIncident.Previous(exitedCleanly: false, lastLineAt: nil, lines: [], pid: nil))
    }

    @Test func headerAndLinesAssembleTheIncident() throws {
        let boot = try date("2026-09-26T10:05:00.000Z")
        let data = try DaemonIncident.headerAndLines(
            bootTime: boot, daemonPid: 20,
            launchd: .found(LaunchdExitRecord.parse(printedKilled)),
            previous: DaemonIncident.Previous(
                exitedCleanly: false, lastLineAt: try date("2026-09-26T10:04:20.500Z"),
                lines: [#"{"a":1}"#, #"{"b":2}"#], pid: 19))
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(
            lines[0]
                == #"{"daemonPid":20,"entry":"incident","gapSeconds":39.5,"launchd":{"rawLines":["state = not running","runs = 1","last terminating signal = Killed: 9","spawn type = daemon (3)","jetsam priority = 40","jetsam memory limit (active) = (unlimited)","jetsam memory limit (inactive) = (unlimited)","jetsamproperties category = daemon","jetsam thread limit = 32"],"runs":1,"spawnType":"daemon (3)","terminatingSignal":9,"threadLimit":32},"previousExitedCleanly":false,"previousLastLineAt":"2026-09-26T10:04:20.500Z","previousLineCount":2,"previousPid":19,"time":"2026-09-26T10:05:00.000Z"}"#
        )
        #expect(Array(lines[1...]) == [#"{"a":1}"#, #"{"b":2}"#])
        #expect(
            DaemonIncident.fileName(bootTime: boot, pid: 20) == "2026-09-26T10-05-00.000Z-pid20.ndjson")
        #expect(try decoded([lines[0]], as: IncidentHeader.self).first?.launchd == .found(LaunchdExitRecord.parse(printedKilled)))
    }

    @Test func aHeaderWithNoLaunchdRecordCarriesOnlyTheNote() throws {
        let header = IncidentHeader(
            daemonPid: 20, gapSeconds: nil, launchd: .unavailable(note: "not running as the launchd agent"),
            previousExitedCleanly: false, previousLastLineAt: nil, previousLineCount: 0, previousPid: nil,
            time: try date("2026-09-26T10:05:00.000Z"))
        let line = try encoded(header)
        #expect(
            line
                == #"{"daemonPid":20,"entry":"incident","launchdNote":"not running as the launchd agent","previousExitedCleanly":false,"previousLineCount":0,"time":"2026-09-26T10:05:00.000Z"}"#
                + "\n")
        #expect(try decoded([line], as: IncidentHeader.self) == [header])
    }

    @Test func lineHeadReadsAnyLineShape() throws {
        let decoder = JSONCoding.decoder()
        let head = try #require(
            TelemetryLog.LineHead(
                line: #"{"daemonPid":3,"entry":"mark","event":"a-mark-from-a-newer-build","time":"2026-09-26T10:00:00.000Z"}"#,
                decoder: decoder))
        #expect(head.daemonPid == 3)
        #expect(head.event == "a-mark-from-a-newer-build")
        #expect(head.time == (try date("2026-09-26T10:00:00.000Z")))
        let bare = try #require(TelemetryLog.LineHead(line: #"{"entry":"snapshot"}"#, decoder: decoder))
        #expect(bare.daemonPid == nil && bare.event == nil && bare.time == nil)
        #expect(TelemetryLog.LineHead(line: #"{"daemonPid":3,"time":"#, decoder: decoder) == nil)
    }

    @Test func logShowTimeIsLocalWallTimeWithItsOffset() throws {
        let instant = try date("2026-09-26T10:05:07.900Z")
        let text = DaemonIncident.logShowTime(instant)
        #expect(text.wholeMatch(of: /\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}[+-]\d{4}/) != nil)
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        #expect(reader.date(from: text) == (try date("2026-09-26T10:05:07.000Z")))
    }

    @Test func searchWindowIsBoundedOnBothSides() throws {
        let boot = try date("2026-09-26T12:00:00.000Z")
        let recent = boot.addingTimeInterval(-40)
        #expect(DaemonIncident.searchWindow(previousLastLineAt: recent, bootTime: boot)
            == (recent.addingTimeInterval(-60), boot))
        let old = boot.addingTimeInterval(-7200)
        #expect(DaemonIncident.searchWindow(previousLastLineAt: old, bootTime: boot)
            == (old.addingTimeInterval(-60), old.addingTimeInterval(600)))
        #expect(DaemonIncident.searchWindow(previousLastLineAt: nil, bootTime: boot)
            == (boot.addingTimeInterval(-180), boot))
        #expect(DaemonIncident.searchWindow(previousLastLineAt: boot.addingTimeInterval(5), bootTime: boot)
            == (boot.addingTimeInterval(-180), boot))
    }

    @Test func predicateNamesThePidOnlyWhenKnown() {
        let withPid = DaemonIncident.logPredicate(
            previousPid: 59407, label: "dev.quantizor.directa", processName: "ddirecta")
        #expect(withPid.contains(#"process == "runningboardd" AND eventMessage CONTAINS ":59407]""#))
        #expect(withPid.contains(#"eventMessage CONTAINS "[59407]""#))
        #expect(withPid.contains(#"NOT eventMessage CONTAINS "dev.quantizor.directa.job""#))
        let withoutPid = DaemonIncident.logPredicate(
            previousPid: nil, label: "dev.quantizor.directa", processName: "ddirecta")
        #expect(!withoutPid.contains("runningboardd"))
        #expect(
            withoutPid.hasPrefix(
                #"(process == "kernel" AND NOT eventMessage BEGINSWITH "evaluation result" AND (eventMessage CONTAINS "ddirecta""#
            ))
    }

    @Test func logShowOutputIsParsedAndCapped() throws {
        let output = [
            "Filtering the log data using \"...\"",
            #"{"eventMessage":"memorystatus: killing largest compressed process ddirecta [94572] 176853 MB","processImagePath":"\/kernel","subsystem":"","timestamp":"2026-09-02 16:05:01.123456-0400"}"#,
            #"{"eventMessage":"exited due to SIGKILL | sent by kernel","processImagePath":"\/sbin\/launchd","subsystem":"com.apple.xpc.launchd","timestamp":"2026-09-02 16:05:01.200000-0400"}"#,
            #"{"processImagePath":"\/sbin\/launchd"}"#,
            #"{"eventMessage":"no readable time","processImagePath":"\/kernel","timestamp":"yesterday"}"#,
        ].joined(separator: "\n")
        let parsed = DaemonIncident.parseLogShow(output)
        #expect(
            parsed == [
                IncidentSystemLog(
                    message: "memorystatus: killing largest compressed process ddirecta [94572] 176853 MB",
                    process: "kernel", subsystem: nil, time: try date("2026-09-02T20:05:01.123Z")),
                IncidentSystemLog(
                    message: "exited due to SIGKILL | sent by kernel", process: "launchd",
                    subsystem: "com.apple.xpc.launchd", time: try date("2026-09-02T20:05:01.200Z")),
                IncidentSystemLog(message: "no readable time", process: "kernel", subsystem: nil, time: nil),
            ])
        #expect(
            try encoded(parsed[2])
                == #"{"entry":"system-log","message":"no readable time","process":"kernel"}"# + "\n")
        let flood = (0..<(DaemonIncident.systemLogLineCap + 5)).map { _ in
            #"{"eventMessage":"x","processImagePath":"\/kernel","timestamp":"2026-09-02 16:05:01.000000-0400"}"#
        }.joined(separator: "\n")
        #expect(DaemonIncident.parseLogShow(flood).count == DaemonIncident.systemLogLineCap)
    }

    @Test func jetsamReportExcerptPicksTheDaemonEntry() {
        let report = [
            #"{"bug_type":"298","timestamp":"2026-09-02 10:00:00.00 -0400","os_version":"macOS 26.0"}"#,
            #"{"largestProcess":"node","processes":[{"name":"node","pid":6751,"rpages":221772},{"name":"ddirecta","pid":6616,"rpages":945,"reason":"per-process-limit"}]}"#,
        ].joined(separator: "\n")
        #expect(
            DaemonIncident.reportExcerpt(text: report, name: "JetsamEvent-2026-09-02-100000.ips", processName: "ddirecta")
                == #"largestProcess=node {"name":"ddirecta","pid":6616,"reason":"per-process-limit","rpages":945}"#)
        #expect(
            DaemonIncident.reportExcerpt(
                text: report.replacing("ddirecta", with: "other"), name: "JetsamEvent-x.ips",
                processName: "ddirecta") == nil)
        #expect(
            DaemonIncident.reportExcerpt(text: "crash body", name: "ddirecta-2026.ips", processName: "ddirecta")
                == "crash body")
        #expect(DaemonIncident.isRelevantReport(name: "JetsamEvent-2026.ips", processName: "ddirecta"))
        #expect(DaemonIncident.isRelevantReport(name: "ddirecta-2026-09-02.ips", processName: "ddirecta"))
        #expect(!DaemonIncident.isRelevantReport(name: "node-2026.ips", processName: "ddirecta"))
        #expect(!DaemonIncident.isRelevantReport(name: "ddirecta.txt", processName: "ddirecta"))
    }

    @Test func pruneKeepsTheNewestIncidents() throws {
        let directory = try temporaryDirectory()
        for index in 0..<7 {
            try Data().write(to: directory.appending(path: "2026-09-2\(index)T00-00-00.000Z-pid1.ndjson"))
        }
        try Data().write(to: directory.appending(path: "notes.txt"))
        DaemonIncident.prune(directory: directory, keep: 3)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [
                "2026-09-24T00-00-00.000Z-pid1.ndjson", "2026-09-25T00-00-00.000Z-pid1.ndjson",
                "2026-09-26T00-00-00.000Z-pid1.ndjson", "notes.txt",
            ])
    }
}
