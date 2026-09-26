import Foundation

/** Every line in telemetry.log and in an incident file carries `entry`, which
    names its shape. */
public enum TelemetryEntryKind: String, Codable, Sendable {
    case diagnosticReport = "diagnostic-report"
    case incident
    case mark
    case searchFinished = "search-finished"
    case snapshot
    case systemLog = "system-log"
}

/** A line telemetry.log accepts. `time` is writable so the log can clamp it
    monotonic per file. */
public protocol TelemetryLine: Encodable, Sendable {
    var time: Date { get set }
}

/** Why a snapshot was taken. */
public enum SampleReason: String, Codable, Sendable {
    /** The fast cadence: work in flight, threads high, or the tail after either. */
    case burst
    /** The baseline cadence. */
    case interval
    /** Thread count first crossed the high-water fraction of the limit; carries
        per-thread detail. */
    case threshold
}

/** Mach thread run states, named as `thread_info` reports them. */
public enum ThreadRunState: String, Codable, Sendable {
    case halted
    case running
    case stopped
    case uninterruptible
    case unknown
    case waiting

    /** `TH_STATE_*` from mach/thread_info.h. */
    public init(machState: Int32) {
        switch machState {
        case 1: self = .running
        case 2: self = .stopped
        case 3: self = .waiting
        case 4: self = .uninterruptible
        case 5: self = .halted
        default: self = .unknown
        }
    }
}

/** One thread, written only on a threshold snapshot. */
public struct ThreadDetail: Codable, Equatable, Sendable {
    /** `thread_basic_info.cpu_usage` as a percentage of one core. */
    public var cpuPercent: Double
    public var name: String
    public var state: ThreadRunState
    public var systemSeconds: Double
    public var userSeconds: Double

    public init(cpuPercent: Double, name: String, state: ThreadRunState, systemSeconds: Double, userSeconds: Double) {
        self.cpuPercent = cpuPercent
        self.name = name
        self.state = state
        self.systemSeconds = systemSeconds
        self.userSeconds = userSeconds
    }
}

/** The kernel's view of the process's dispatch workqueue
    (`PROC_PIDWORKQUEUEINFO`): pool threads, how many run and how many block,
    and which of the kernel's own thread limits it has hit. */
public struct WorkqueueSample: Codable, Equatable, Sendable {
    public var blocked: Int
    /** Names of the `WQ_EXCEEDED_*` flags set. */
    public var limitsExceeded: [String]
    public var running: Int
    public var total: Int

    public init(blocked: Int, limitsExceeded: [String], running: Int, total: Int) {
        self.blocked = blocked
        self.limitsExceeded = limitsExceeded
        self.running = running
        self.total = total
    }

    /** Flag names for `pwq_state`, from sys/proc_info.h. */
    public static func limitNames(state: UInt32) -> [String] {
        var names: [String] = []
        if state & 0x1 != 0 { names.append("constrained") }
        if state & 0x2 != 0 { names.append("total") }
        if state & 0x8 != 0 { names.append("cooperative") }
        if state & 0x10 != 0 { names.append("active-constrained") }
        return names
    }
}

/** One `BlockingLane` at an instant: jobs running on its threads, jobs
    waiting for a thread, and how long the first waiting job has waited. */
public struct LanePressure: Codable, Equatable, Sendable {
    public var name: String
    /** Zero when nothing is queued. */
    public var oldestQueuedSeconds: Double
    public var queued: Int
    public var running: Int
    public var width: Int

    public init(name: String, oldestQueuedSeconds: Double, queued: Int, running: Int, width: Int) {
        self.name = name
        self.oldestQueuedSeconds = oldestQueuedSeconds
        self.queued = queued
        self.running = running
        self.width = width
    }
}

public struct ThreadSample: Codable, Equatable, Sendable {
    /** Thread count per name: the pthread name when set, else the dispatch
        queue the thread is serving (a cooperative-pool thread reads
        `com.apple.root.<qos>.cooperative`), else `(unnamed)`. */
    public var byName: [String: Int]
    /** Keyed by `ThreadRunState` raw value. */
    public var byState: [String: Int]
    /** The launchd `jetsam thread limit` for this job, when running as the agent. */
    public var limit: Int?
    public var total: Int
    public var workqueue: WorkqueueSample?

    public init(
        byName: [String: Int], byState: [String: Int], limit: Int?, total: Int, workqueue: WorkqueueSample?
    ) {
        self.byName = byName
        self.byState = byState
        self.limit = limit
        self.total = total
        self.workqueue = workqueue
    }
}

/** Bytes, from `proc_pid_rusage` and `task_info(TASK_VM_INFO)`. `footprint`
    is what jetsam weighs; `compressed` is the process's compressed anonymous
    memory, the number `no_paging_space_action` compares. */
public struct MemorySample: Codable, Equatable, Sendable {
    public var compressed: UInt64
    public var compressedLifetime: UInt64
    public var compressedPeak: UInt64
    public var footprint: UInt64
    public var footprintLifetimePeak: UInt64
    public var `internal`: UInt64
    public var internalPeak: UInt64
    public var resident: UInt64

    public init(
        compressed: UInt64, compressedLifetime: UInt64, compressedPeak: UInt64, footprint: UInt64,
        footprintLifetimePeak: UInt64, internal: UInt64, internalPeak: UInt64, resident: UInt64
    ) {
        self.compressed = compressed
        self.compressedLifetime = compressedLifetime
        self.compressedPeak = compressedPeak
        self.footprint = footprint
        self.footprintLifetimePeak = footprintLifetimePeak
        self.internal = `internal`
        self.internalPeak = internalPeak
        self.resident = resident
    }
}

public struct SystemSample: Codable, Equatable, Sendable {
    /** 1, 5, and 15 minute load averages. */
    public var loadAverage: [Double]
    /** `kern.memorystatus_vm_pressure_level` by name: normal, warning,
        critical, or the raw number when it is none of those. */
    public var memoryPressure: String

    public init(loadAverage: [Double], memoryPressure: String) {
        self.loadAverage = loadAverage
        self.memoryPressure = memoryPressure
    }

    public static func pressureName(level: Int32) -> String {
        switch level {
        case 1: "normal"
        case 2: "warning"
        case 4: "critical"
        default: "level \(level)"
        }
    }
}

/** One sample of the daemon's own resources and activity. A field the kernel
    refused is nil rather than zero, so a zero always means zero. */
public struct TelemetrySnapshot: TelemetryLine, Codable, Equatable {
    public var activity: ActivitySnapshot
    public var daemonPid: Int32
    public var entry = TelemetryEntryKind.snapshot
    /** Exit watches armed in `ExitWatcher`. */
    public var exitWatches: Int
    public var fileDescriptors: Int?
    public var lanes: [LanePressure]
    public var memory: MemorySample?
    public var reason: SampleReason
    /** Wall time this sample took to collect, the sampler's own cost. */
    public var sampleMicroseconds: Int
    public var system: SystemSample
    public var threadDetail: [ThreadDetail]?
    public var threads: ThreadSample?
    public var time: Date
    public var uptimeSeconds: Double

    public init(
        activity: ActivitySnapshot, daemonPid: Int32, exitWatches: Int, fileDescriptors: Int?,
        lanes: [LanePressure], memory: MemorySample?, reason: SampleReason, sampleMicroseconds: Int,
        system: SystemSample, threadDetail: [ThreadDetail]?, threads: ThreadSample?, time: Date,
        uptimeSeconds: Double
    ) {
        self.activity = activity
        self.daemonPid = daemonPid
        self.exitWatches = exitWatches
        self.fileDescriptors = fileDescriptors
        self.lanes = lanes
        self.memory = memory
        self.reason = reason
        self.sampleMicroseconds = sampleMicroseconds
        self.system = system
        self.threadDetail = threadDetail
        self.threads = threads
        self.time = time
        self.uptimeSeconds = uptimeSeconds
    }
}

/** The mark names telemetry.log carries. */
public enum TelemetryMarkEvent: String, Codable, Sendable {
    case daemonExiting = "daemon-exiting"
    case daemonStarted = "daemon-started"
    case restartBegan = "restart-began"
    case restartEnded = "restart-ended"
    case slowLaneWait = "slow-lane-wait"
    case slowOperation = "slow-operation"
    case stopBegan = "stop-began"
    case stopEnded = "stop-ended"
    case threadsHigh = "threads-high"
}

/** A short timeline line: a stop or restart beginning and ending, a blocking
    operation that ran long, the daemon starting or exiting cleanly. */
public struct TelemetryMark: TelemetryLine, Codable, Equatable {
    public var daemonPid: Int32
    public var entry = TelemetryEntryKind.mark
    public var event: TelemetryMarkEvent
    public var kind: ActivityKind?
    public var label: String?
    public var outcome: String?
    public var seconds: Double?
    public var time: Date

    public init(
        daemonPid: Int32, event: TelemetryMarkEvent, kind: ActivityKind? = nil, label: String? = nil,
        outcome: String? = nil, seconds: Double? = nil, time: Date
    ) {
        self.daemonPid = daemonPid
        self.event = event
        self.kind = kind
        self.label = label
        self.outcome = outcome
        self.seconds = seconds
        self.time = time
    }

    /** The mark for an activity event, or nil when that event gets none:
        stops and restarts mark both ends, blocking work and phase waits mark
        only an end past `slowOperationSeconds`, and a lane reports only the
        queue waits already past it. */
    public static func forActivity(
        _ event: DaemonActivity.Event, daemonPid: Int32, time: Date,
        slowOperationSeconds: Double = TelemetryCadence.slowOperationSeconds
    ) -> TelemetryMark? {
        switch event {
        case .laneWaited(let lane, let seconds):
            return TelemetryMark(
                daemonPid: daemonPid, event: .slowLaneWait, label: lane, seconds: seconds, time: time)
        case .began(let token):
            switch token.kind {
            case .stop:
                return TelemetryMark(daemonPid: daemonPid, event: .stopBegan, label: token.label, time: time)
            case .restart:
                return TelemetryMark(daemonPid: daemonPid, event: .restartBegan, label: token.label, time: time)
            default:
                return nil
            }
        case .ended(let token, let outcome, let seconds):
            switch token.kind {
            case .stop:
                return TelemetryMark(
                    daemonPid: daemonPid, event: .stopEnded, label: token.label, outcome: outcome,
                    seconds: seconds, time: time)
            case .restart:
                return TelemetryMark(
                    daemonPid: daemonPid, event: .restartEnded, label: token.label, outcome: outcome,
                    seconds: seconds, time: time)
            case .request:
                return nil
            case .git, .launchctl, .logShow, .lsof, .ps, .spawnWait, .stopWait, .subprocess:
                guard seconds > slowOperationSeconds else { return nil }
                return TelemetryMark(
                    daemonPid: daemonPid, event: .slowOperation, kind: token.kind, label: token.label,
                    outcome: outcome, seconds: seconds, time: time)
            }
        }
    }
}
