import DirectaKit
import Foundation

/** The resolved healthcheck a server actually runs: explicit config wins, a
    declared port implies a TCP probe, and nothing at all means "alive past a
    stabilization window". */
public enum EffectiveHealthcheck: Equatable, Sendable {
    case http(url: String, timeoutMs: Int)
    case none(stabilizationMs: Int)
    case tcp(port: Int, timeoutMs: Int)

    public static func resolve(spec: ServerSpec) -> EffectiveHealthcheck {
        let timeoutMs = spec.healthcheck?.timeoutMs ?? 1500
        switch spec.healthcheck?.type {
        case .http:
            if let url = spec.healthcheck?.url {
                return .http(url: url, timeoutMs: timeoutMs)
            }
        case .tcp:
            if let port = spec.healthcheck?.port ?? spec.port {
                return .tcp(port: port, timeoutMs: timeoutMs)
            }
        case .some(.none):
            return .none(stabilizationMs: 2000)
        case nil:
            break
        }
        if let port = spec.port {
            return .tcp(port: port, timeoutMs: timeoutMs)
        }
        return .none(stabilizationMs: 2000)
    }

    public var kind: HealthCheckType {
        switch self {
        case .http: .http
        case .none: .none
        case .tcp: .tcp
        }
    }
}

/** Seam for tests: the supervisor's health loop asks this, and unit tests inject
    a scripted prober instead of a real network. */
public protocol HealthProber: Sendable {
    func probe(_ check: EffectiveHealthcheck) async -> HealthProbeOutcome
}

/** One probe's answer: whether it passed and, when it did not, a short plain
    reason in directa's own words (never text the server sent). */
public struct HealthProbeOutcome: Equatable, Sendable {
    public var detail: String?
    public var passed: Bool

    public init(detail: String? = nil, passed: Bool) {
        self.detail = detail
        self.passed = passed
    }

    public static let pass = HealthProbeOutcome(passed: true)

    public static func fail(_ detail: String) -> HealthProbeOutcome {
        HealthProbeOutcome(detail: detail, passed: false)
    }
}

public struct NetworkHealthProber: HealthProber {
    /** Dedicated ephemeral session so probes do not share URLSession.shared
        caches. Its timeouts sit at the ceiling `timeoutMs` may take, because
        a session-wide resource timeout caps every request below whatever its
        own `timeoutInterval` asks (a 10s `timeoutMs` once failed at 5s);
        `probe` enforces the configured bound itself. */
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        let ceiling = Double(HealthCheckSpec.durationRange.upperBound) / 1000
        config.timeoutIntervalForRequest = ceiling
        config.timeoutIntervalForResource = ceiling
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: RedirectStopper.shared, delegateQueue: nil)
    }()

    /** Where the TCP connect waits, so a slow healthcheck never queues ahead
        of the `system` lane's launchctl, lsof, and ps calls. */
    let lane: BlockingLane

    public init() {
        self.init(lane: .health)
    }

    init(lane: BlockingLane) {
        self.lane = lane
    }

    public func probe(_ check: EffectiveHealthcheck) async -> HealthProbeOutcome {
        switch check {
        case .none:
            /** Stabilization timing lives in the monitor loop; the probe itself
                only answers "is the process still the thing we care about", which
                the supervisor already knows. */
            return .pass
        case .http(let url, let timeoutMs):
            return await httpProbe(url: url, timeoutMs: Self.bounded(timeoutMs))
        case .tcp(let port, let timeoutMs):
            /** The connect waits in `poll(2)` for up to the configured timeout. */
            let bounded = Self.bounded(timeoutMs)
            let outcome = await lane.run {
                LoopbackProbe.probe(port: port, timeoutMs: bounded)
            }
            switch outcome {
            case .listening: return .pass
            case .refused: return .fail(Self.refusedDetail)
            case .timedOut: return .fail(Self.timedOutDetail(timeoutMs: bounded))
            case .failed: return .fail(Self.unreachableDetail)
            }
        }
    }

    private static let refusedDetail = "connection refused"
    private static let unreachableDetail = "could not connect"
    private static let noAnswerDetail = "no valid answer"

    /** Config validation keeps `timeoutMs` inside `HealthCheckSpec.durationRange`;
        a spec that skipped it is held to the same range here. */
    private static func bounded(_ timeoutMs: Int) -> Int {
        min(max(timeoutMs, HealthCheckSpec.durationRange.lowerBound), HealthCheckSpec.durationRange.upperBound)
    }

    /** "10s" for whole seconds, "0.5s" otherwise. */
    private static func timedOutDetail(timeoutMs: Int) -> String {
        let seconds = timeoutMs.isMultiple(of: 1000) ? "\(timeoutMs / 1000)" : "\(Double(timeoutMs) / 1000)"
        return "timed out after \(seconds)s"
    }

    private func httpProbe(url: String, timeoutMs: Int) async -> HealthProbeOutcome {
        guard let parsed = URL(string: url) else { return .fail("invalid URL") }
        let clock = ContinuousClock()
        let began = clock.now
        var request = URLRequest(url: parsed)
        /** *.localhost hosts resolve in browsers but not reliably in the
            system resolver; probe loopback directly and carry the Host header
            so vhost-aware dev servers still route. The bind stack is not
            knowable ahead (Vite 5+ binds `::1` only), so IPv6 loopback is
            tried when IPv4 refuses the connection, and only then. */
        let localhostName = parsed.host.flatMap { $0.hasSuffix(".localhost") ? $0 : nil }
        if let localhostName, let rewritten = Self.rewrite(parsed, host: "127.0.0.1") {
            request.url = rewritten
            request.setValue(localhostName, forHTTPHeaderField: "Host")
        }
        let first = await Self.send(request, timeoutMs: timeoutMs)
        guard case .refused = first, let localhostName, let rewritten = Self.rewrite(parsed, host: "[::1]")
        else { return Self.outcome(first, timeoutMs: timeoutMs) }
        /** One bound for the whole probe: the retry gets what the first
            attempt left. */
        let (seconds, attoseconds) = began.duration(to: clock.now).components
        let spentMs = Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
        var v6 = URLRequest(url: rewritten)
        v6.setValue(localhostName, forHTTPHeaderField: "Host")
        let second = await Self.send(v6, timeoutMs: max(1, timeoutMs - spentMs))
        return Self.outcome(second, timeoutMs: timeoutMs)
    }

    private static func rewrite(_ url: URL, host: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.host = host
        return components.url
    }

    private enum Answer {
        case answered(status: Int)
        case failed
        case noValidAnswer
        case refused
        case timedOut
    }

    private static func outcome(_ answer: Answer, timeoutMs: Int) -> HealthProbeOutcome {
        switch answer {
        case .answered(let status): (200..<400).contains(status) ? .pass : .fail("HTTP \(status)")
        case .failed: .fail(unreachableDetail)
        case .noValidAnswer: .fail(noAnswerDetail)
        case .refused: .fail(refusedDetail)
        case .timedOut: .fail(timedOutDetail(timeoutMs: timeoutMs))
        }
    }

    /** One request raced against the whole-probe deadline. The request's own
        timeout only bounds the wait between bytes, so a server trickling its
        answer could outlast `timeoutMs`; the race ends the probe at the
        deadline whatever the connection is doing. */
    private static func send(_ request: URLRequest, timeoutMs: Int) async -> Answer {
        var timed = request
        timed.timeoutInterval = Double(timeoutMs) / 1000
        let prepared = timed
        return await withTaskGroup(of: Answer.self) { group in
            group.addTask { await answer(to: prepared) }
            group.addTask {
                guard (try? await Task.sleep(for: .milliseconds(timeoutMs))) != nil else { return .failed }
                return .timedOut
            }
            let first = await group.next() ?? .failed
            group.cancelAll()
            return first
        }
    }

    /** A 3xx IS a healthy answer (login redirects abound in dev apps);
        following it would re-enter hostname resolution the loopback rewrite
        just avoided, so redirects never get followed. */
    private static func answer(to request: URLRequest) async -> Answer {
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .noValidAnswer }
            return .answered(status: http.statusCode)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost: return .refused
            case .timedOut: return .timedOut
            case .badServerResponse, .cannotParseResponse, .networkConnectionLost, .zeroByteResource:
                return .noValidAnswer
            default: return .failed
            }
        } catch {
            return .failed
        }
    }

    /** Refuses redirect-following so the probe judges the first response. */
    final class RedirectStopper: NSObject, URLSessionTaskDelegate {
        static let shared = RedirectStopper()

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

}

/** Port ownership diagnostics: best-effort lsof shell-outs. These inform errors
    and status; supervision never depends on them. */
public enum PortGuard {
    /** True when something accepts on either loopback family for that port. */
    public static func isListening(port: Int) -> Bool {
        LoopbackProbe.isListening(port: port)
    }

    /** Every pid listening on a port, not just the first.

        One port routinely has two owners: a process bound to IPv4 `127.0.0.1`
        and another bound to the IPv6 wildcard coexist with no EADDRINUSE, and
        which one answers a probe depends on how the client resolves the name.
        Reading only the first pid reports a single owner for that case and hides
        the ambiguity that makes a health signal untrustworthy. */
    public static func listenerPids(port: Int) -> [Int] {
        answeredListenerPids(port: port) ?? []
    }

    /** The command behind a pid, for naming a holder in an error. */
    public static func commandForPid(_ pid: Int) -> String {
        shell("/bin/ps", ["-o", "command=", "-p", String(pid)])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    /** The pid + command listening on a port, when lsof can name it. */
    public static func listenerInfo(port: Int) -> (pid: Int, command: String)? {
        guard let pid = listenerPids(port: port).first else { return nil }
        return (pid: pid, command: commandForPid(pid))
    }

    /** TCP ports the given processes are listening on. */
    public static func listeningPorts(pids: [pid_t]) -> [Int] {
        guard !pids.isEmpty,
            let output = shell(
                "/usr/sbin/lsof",
                ["-nP", "-a", "-p", pids.map(String.init).joined(separator: ","), "-iTCP", "-sTCP:LISTEN"])
        else { return [] }
        var ports: [Int] = []
        for line in output.split(separator: "\n").dropFirst() {
            /** lsof NAME column ends in `:PORT (LISTEN)`. */
            guard let nameField = line.split(separator: " ").dropLast().last,
                let portText = nameField.split(separator: ":").last,
                let port = Int(portText)
            else { continue }
            if !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    private static func shell(_ path: String, _ arguments: [String]) -> String? {
        output(
            path, arguments,
            timeoutSeconds: HelperCommand.defaultTimeoutSeconds(executable: path, arguments: arguments)
                ?? HelperCommand.lsofTimeoutSeconds)
    }

    /** stdout of a command that ran to the end, or nil when it could not
        start, outlived `timeoutSeconds`, or wrote past `HelperCommand`'s output
        cap: a lookup that hung or ran away is no evidence, the same as one that
        found nothing. A nonzero exit still answers its
        output, since `lsof` exits 1 when nothing matches. */
    static func output(_ path: String, _ arguments: [String], timeoutSeconds: Double) -> String? {
        switch HelperCommand.run(path, arguments, includeStderr: false, timeoutSeconds: timeoutSeconds) {
        case .exited(_, let output): output
        case .failedToRun, .timedOut, .outputLimitExceeded: nil
        }
    }
}

/** The forms async code calls: each runs its synchronous namesake on
    `BlockingLane.system`, since `lsof` and `ps` block their caller until they
    exit and a loopback connect waits in `poll(2)`. Swift picks these over the
    synchronous forms in any async context. */
extension PortGuard {
    public static func isListening(port: Int) async -> Bool {
        await BlockingLane.system.run { isListening(port: port) }
    }

    public static func listenerInfo(port: Int) async -> (pid: Int, command: String)? {
        await BlockingLane.system.run { listenerInfo(port: port) }
    }

    public static func listenerPids(port: Int) async -> [Int] {
        await BlockingLane.system.run { listenerPids(port: port) }
    }

    public static func listeningPorts(pids: [pid_t]) async -> [Int] {
        await BlockingLane.system.run { listeningPorts(pids: pids) }
    }
}
