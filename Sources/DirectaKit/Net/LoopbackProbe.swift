import Darwin
import Foundation

/** Is anything accepting connections on a loopback port right now.

    Lives in DirectaKit because two callers need it and cannot share a home
    otherwise: the daemon's health prober and the CLI's `doctor`, which cannot
    import DirectaDaemonCore (that target links swift-subprocess). The CLI used to
    carry its own IPv4-only copy with a blocking connect and no deadline, which
    reported a free port for anything bound to `::1` alone. */
public enum LoopbackProbe {
    /** Dev servers bind either stack: Vite 5+ listens on `::1` only, older
        tooling on `127.0.0.1` only, so both loopback families are tried and
        either answering counts as a live listener. */
    public static func isListening(port: Int, timeoutMs: Int = 300) -> Bool {
        connect(port: port, timeoutMs: timeoutMs, family: AF_INET) == .listening
            || connect(port: port, timeoutMs: timeoutMs, family: AF_INET6) == .listening
    }

    /** How one connect attempt ended. */
    public enum Outcome: Equatable, Sendable {
        /** Some other failure: an impossible port, no socket, an unreachable address. */
        case failed
        case listening
        /** Nothing is listening: the kernel answered the attempt with a reset. */
        case refused
        /** No answer inside the deadline. */
        case timedOut
    }

    /** The health probe's form: IPv4 first, and IPv6 only when IPv4 was
        refused, since a refusal says the port is free on that stack and
        another stack may hold the server. A timeout on IPv4 means something
        answered the address and did not accept, so a second full wait on IPv6
        would double the time `timeoutMs` promised the caller. */
    public static func probe(port: Int, timeoutMs: Int) -> Outcome {
        let v4 = connect(port: port, timeoutMs: timeoutMs, family: AF_INET)
        guard v4 == .refused else { return v4 }
        return connect(port: port, timeoutMs: timeoutMs, family: AF_INET6)
    }

    /** Non-blocking connect with a poll deadline, so an unreachable port cannot
        stall a status call for the kernel's full connect timeout. */
    private static func connect(port: Int, timeoutMs: Int, family: Int32) -> Outcome {
        /** A port arrives from a repo's devservers.json, from `--port`, and from
            portSpan arithmetic that can run off the end of the range, and
            `UInt16(port)` traps on anything outside 0...65535. Under launchd
            KeepAlive that trap is a crash loop: boot restore re-reads the same
            config and dies again on every relaunch. Nothing can be listening on
            a port that does not exist, so answer that instead of trapping. */
        guard let narrowed = UInt16(exactly: port), narrowed > 0 else { return .failed }
        let sock = socket(family, SOCK_STREAM, 0)
        guard sock >= 0 else { return .failed }
        defer { close(sock) }
        let flags = fcntl(sock, F_GETFL)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        var storage = sockaddr_storage()
        let sockLen: socklen_t
        if family == AF_INET6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = narrowed.bigEndian
            addr.sin6_addr = in6addr_loopback
            sockLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeMutablePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee = addr }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = narrowed.bigEndian
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            sockLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee = addr }
            }
        }
        let result = withUnsafePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, sockLen)
            }
        }
        if result == 0 { return .listening }
        if errno == ECONNREFUSED { return .refused }
        guard errno == EINPROGRESS else { return .failed }
        var pollTarget = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        /** The same hazard as the port above, on the value sitting beside it: a
            healthcheck's `timeoutMs` comes from a repo's devservers.json, and
            `Int32(timeoutMs)` traps outside Int32's range. A negative value does
            not trap but is worse, because `poll` reads it as "wait forever" and
            wedges the health task with no error anywhere. Clamping answers both:
            a probe that cannot report inside its deadline is a probe reporting
            that nothing is listening. */
        let deadline = Int32(clamping: max(0, timeoutMs))
        let ready = poll(&pollTarget, 1, deadline)
        if ready == 0 { return .timedOut }
        guard ready == 1 else { return .failed }
        var soError: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &soLen)
        switch soError {
        case 0: return .listening
        case ECONNREFUSED: return .refused
        default: return .failed
        }
    }
}
