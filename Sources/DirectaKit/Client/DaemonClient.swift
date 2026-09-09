import Foundation

/** Thin blocking-POSIX unix-socket client wrapped in an actor. Used unchanged by
    the CLI and the menu bar app. Request/response is correlated by id; the daemon
    may interleave push frames, which this client ignores beyond the hello handshake. */
public actor DaemonClient {
    private var buffer = NDJSONBuffer()
    private var fd: Int32 = -1
    private var nextID = 0
    public private(set) var hello: HelloParams?

    private let socketPath: String

    /** How long a single request waits for the daemon to answer before giving
        up. The daemon sends nothing between the request and its one response, so
        this is a whole-response deadline, not an idle gap: without it a wedged
        daemon (a blocked actor, a deadlock) hangs `directa` and the app forever,
        with no output and no way out. `request` raises it for a command that
        carries its own timeout so a long but healthy `ensure`, `wait`, or group
        rollout is never cut off. */
    private static let defaultResponseTimeout: Double = 120

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    /** Connects and consumes the hello frame, enforcing protocol compatibility. */
    public func connect() throws {
        guard fd < 0 else { return }
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw WireError(code: .daemonUnreachable, message: "socket() failed: \(String(cString: strerror(errno)))")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard DirectaPaths.fitsSunPath(socketPath) else {
            close(sock)
            throw WireError(code: .daemonUnreachable, message: "socket path exceeds sun_path limit: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, len)
            }
        }
        guard result == 0 else {
            let err = errno
            close(sock)
            throw WireError(
                code: .daemonUnreachable,
                hint: "run: directa daemon status",
                message: "cannot connect to ddirecta at \(socketPath): \(String(cString: strerror(err)))"
            )
        }
        fd = sock
        setResponseTimeout(Self.defaultResponseTimeout)
        /** The socket is open but unproven from here, and `fd >= 0` is what the
            guard above reads as "already connected". So every failing exit has
            to put the client back to disconnected: leaving a live fd behind with
            no hello meant the next `connect()` returned at that guard and the
            protocol check never ran again for the life of the client, turning a
            version mismatch into requests written blind at a daemon that does
            not speak this protocol. Minting a client per command hides it; the
            `lock` command holds one across acquire, the guarded command and
            release, which is long enough to reach. */
        do {
            let helloLine = try readLine()
            let head = try JSONCoding.decoder().decode(WireEventHead.self, from: helloLine)
            guard head.event == "hello" else {
                throw WireError(
                    code: .internalError, message: "daemon sent \(head.event) before hello")
            }
            let frame = try JSONCoding.decoder().decode(WireEvent<HelloParams>.self, from: helloLine)
            guard frame.params.proto == DirectaVersion.proto else {
                throw WireError(
                    code: .versionMismatch,
                    hint: "run: directa daemon restart",
                    message: "daemon speaks protocol \(frame.params.proto) (v\(frame.params.daemonVersion)); this client speaks \(DirectaVersion.proto) (v\(DirectaVersion.version))"
                )
            }
            hello = frame.params
        } catch {
            disconnect()
            throw error
        }
    }

    /** Back to the state a freshly constructed client is in. The buffered bytes
        matter as much as the fd: half a frame left over from a failed handshake
        would be read as the head of the next connection's hello. */
    private func disconnect() {
        if fd >= 0 { close(fd) }
        buffer = NDJSONBuffer()
        fd = -1
        hello = nil
        pending = []
    }

    /** Clamp a response deadline into a range safe to convert to `timeval`:
        `Int(Double)` and `Int32(Double)` trap on a non-finite or out-of-range
        value, and this deadline ultimately derives from a caller-supplied
        `--timeout`, so `--timeout inf` must degrade to the default rather than
        crash the process. One day is far above any real deadline and well inside
        Int range. */
    static func clampedResponseTimeout(_ seconds: Double) -> Double {
        seconds.isFinite ? min(max(seconds, 0), 86_400) : defaultResponseTimeout
    }

    /** Sets the socket receive timeout (`SO_RCVTIMEO`); a blocking `read` then
        fails with `EAGAIN` once no data arrives within the window. */
    private func setResponseTimeout(_ seconds: Double) {
        guard fd >= 0 else { return }
        let clamped = Self.clampedResponseTimeout(seconds)
        let whole = clamped.rounded(.down)
        var tv = timeval(
            tv_sec: Int(whole),
            tv_usec: Int32((clamped - whole) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /** `operationTimeoutSeconds` is the command's own health/wait budget, when it
        has one. The response deadline is set well above it so a legitimately long
        `ensure`/`wait`/group rollout (including a few dependency waves) is never
        cut off, while a wedged daemon still fails in bounded time. */
    public func request<P: Codable & Sendable, R: Codable & Sendable>(
        _ method: WireMethod,
        params: P,
        expecting: R.Type,
        operationTimeoutSeconds: Double? = nil
    ) throws -> R {
        try connect()
        if let operationTimeoutSeconds {
            setResponseTimeout(max(Self.defaultResponseTimeout, operationTimeoutSeconds * 2 + 60))
        }
        defer { setResponseTimeout(Self.defaultResponseTimeout) }
        nextID += 1
        let id = "c\(nextID)"
        let line = try NDJSON.encodeLine(WireRequest(id: id, method: method.rawValue, params: params))
        try writeAll(line)
        while true {
            let frame = try readLine()
            // Push frames can interleave with responses; skip anything without our id.
            if (try? JSONCoding.decoder().decode(WireEventHead.self, from: frame)) != nil { continue }
            let head = try JSONCoding.decoder().decode(WireResponseHead.self, from: frame)
            guard head.id == id else { continue }
            if head.ok {
                let typed = try JSONCoding.decoder().decode(WireResponse<R>.self, from: frame)
                guard let result = typed.result else {
                    throw WireError(code: .internalError, message: "ok response for \(method.rawValue) carried no result")
                }
                return result
            }
            throw head.error ?? WireError(code: .internalError, message: "unspecified daemon error for \(method.rawValue)")
        }
    }

    private func readLine() throws -> Data {
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let line = pendingLine() { return line }
            let n = read(fd, &scratch, scratch.count)
            if n == 0 {
                throw WireError(code: .daemonUnreachable, message: "daemon closed the connection")
            }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw WireError(
                        code: .daemonUnreachable,
                        hint: "run: directa daemon restart",
                        message: "ddirecta did not answer in time; it may be wedged")
                }
                throw WireError(code: .daemonUnreachable, message: "read failed: \(String(cString: strerror(errno)))")
            }
            pending.append(contentsOf: buffer.feed(Data(scratch[0..<n])))
        }
    }

    private var pending: [Data] = []

    private func pendingLine() -> Data? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    private func writeAll(_ data: Data) throws {
        var remaining = [UInt8](data)
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw WireError(code: .daemonUnreachable, message: "write failed: \(String(cString: strerror(errno)))")
            }
            remaining.removeFirst(n)
        }
    }
}
