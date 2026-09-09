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
    func probe(_ check: EffectiveHealthcheck) async -> Bool
}

public struct NetworkHealthProber: HealthProber {
    /** Dedicated ephemeral session so probes do not share URLSession.shared
        caches or the default 60s resource timeout. */
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: RedirectStopper.shared, delegateQueue: nil)
    }()

    public init() {}

    public func probe(_ check: EffectiveHealthcheck) async -> Bool {
        switch check {
        case .none:
            /** Stabilization timing lives in the monitor loop; the probe itself
                only answers "is the process still the thing we care about", which
                the supervisor already knows. */
            return true
        case .http(let url, let timeoutMs):
            guard let parsed = URL(string: url) else { return false }
            var request = URLRequest(url: parsed)
            request.timeoutInterval = Double(timeoutMs) / 1000
            /** *.localhost hosts resolve in browsers but not reliably in the
                system resolver; probe loopback directly and carry the Host header
                so vhost-aware dev servers still route. The bind stack is not
                knowable ahead (Vite 5+ binds `::1` only), so IPv6 loopback is
                retried when IPv4 refuses. */
            let originalHost = parsed.host
            if let host = originalHost, host.hasSuffix(".localhost"),
                var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false)
            {
                components.host = "127.0.0.1"
                if let rewritten = components.url {
                    request.url = rewritten
                    request.setValue(host, forHTTPHeaderField: "Host")
                }
            }
            do {
                return try await Self.httpResponds(request)
            } catch {
                /** IPv4 failed; retry over IPv6 loopback carrying the same Host. */
                guard let host = originalHost, host.hasSuffix(".localhost"),
                    var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false)
                else { return false }
                components.host = "[::1]"
                guard let rewritten = components.url else { return false }
                var v6 = URLRequest(url: rewritten)
                v6.timeoutInterval = request.timeoutInterval
                v6.setValue(host, forHTTPHeaderField: "Host")
                return (try? await Self.httpResponds(v6)) ?? false
            }
        case .tcp(let port, let timeoutMs):
            return LoopbackProbe.isListening(port: port, timeoutMs: timeoutMs)
        }
    }

    /** A 3xx IS a healthy answer (login redirects abound in dev apps);
        following it would re-enter hostname resolution the loopback rewrite
        just avoided, so redirects never get followed. */
    private static func httpResponds(_ request: URLRequest) async throws -> Bool {
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<400).contains(http.statusCode)
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
        guard let output = shell("/usr/sbin/lsof", ["-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"])
        else { return [] }
        var pids: [Int] = []
        for line in output.split(separator: "\n") {
            guard let pid = Int(line.trimmingCharacters(in: .whitespaces)) else { continue }
            if !pids.contains(pid) { pids.append(pid) }
        }
        return pids
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
