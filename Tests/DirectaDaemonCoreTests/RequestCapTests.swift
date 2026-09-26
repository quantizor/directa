import Darwin
import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

/** `ControlServer.receiveLoop`'s pending-request cap operates on the raw
    `NWConnection`, below `DaemonClient`, which only ever writes complete
    newline-terminated frames. Proving the cap refuses an unterminated request
    and closes the connection needs a raw socket that can write bytes with no
    trailing newline; a normal request through `DaemonClient` proves the cap
    left ordinary traffic alone. */
@Suite struct RequestCapTests {
    private func startServer() async throws -> (socketPath: String, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "directa-cap-\(UUID().uuidString)")
        let paths = DirectaPaths(
            dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs"))
        try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        let router = Router(
            launcher: SubprocessLauncher(), paths: paths, registry: Registry(paths: paths))
        /** Off `base`, not under it: `FileManager.temporaryDirectory` resolves
            to `/var/folders/.../T`, which alone can sit close to the sun_path
            104-byte limit, and this test needs headroom for its own directory
            name on top. `/tmp` is the same short fallback root the daemon's own
            `DirectaPaths.socketPath` uses when the preferred path will not fit. */
        let socketPath = "/tmp/directa-cap-\(UUID().uuidString.prefix(8)).sock"
        let server = try ControlServer(router: router, socketPath: socketPath)
        try await server.startAccepting()
        return (
            socketPath,
            {
                try? FileManager.default.removeItem(at: base)
                try? FileManager.default.removeItem(atPath: socketPath)
            }
        )
    }

    /** A bare POSIX connect: `DaemonClient` already validates and frames every
        request, which is exactly what this test needs to bypass. */
    private func rawConnect(to socketPath: String) throws -> Int32 {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(sock >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(socketPath.utf8))
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(sock, sa, len)
            }
        }
        #expect(result == 0)
        /** A read deadline, not a hang: if a refusal regressed into silence,
            `readLines` below must fail this test in bounded time rather than
            block the whole suite forever. */
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return sock
    }

    private func writeAll(_ sock: Int32, _ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(sock, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    /** Reads until at least `lineCount` newline-terminated lines have arrived
        or the peer closes; returns every complete line seen. */
    private func readLines(_ sock: Int32, count lineCount: Int) -> [Data] {
        var accumulated = Data()
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while accumulated.filter({ $0 == 0x0A }).count < lineCount {
            let n = scratch.withUnsafeMutableBufferPointer { read(sock, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            accumulated.append(contentsOf: scratch[0..<n])
        }
        return Array(accumulated).split(separator: 0x0A).map { Data($0) }
    }

    @Test func anOverCapUnterminatedRequestGetsRefusedAndCloses() async throws {
        let (socketPath, cleanup) = try await startServer()
        defer { cleanup() }
        let sock = try rawConnect(to: socketPath)
        defer { close(sock) }

        _ = readLines(sock, count: 1) // the hello frame

        let payload = [UInt8](
            repeating: UInt8(ascii: "x"), count: ControlServer.maxPendingRequestBytes + 4096)
        writeAll(sock, payload)

        let refusal = readLines(sock, count: 1)
        let response = try #require(refusal.first)
        let decoded = try JSONCoding.decoder().decode(WireResponseHead.self, from: response)
        #expect(decoded.ok == false)
        #expect(decoded.error?.code == .requestTooLarge)
        /** No literal command fixes a client writing raw NDJSON to the
            socket without a newline; the CLI and app never trigger this, so
            a hint here would name a remediation that does not exist. */
        #expect(decoded.error?.hint == nil)

        /** The connection closes after the refusal: a further read reaches EOF
            (0) rather than blocking forever or answering more requests. */
        var scratch = [UInt8](repeating: 0, count: 16)
        let n = scratch.withUnsafeMutableBufferPointer { read(sock, $0.baseAddress, $0.count) }
        #expect(n == 0)
    }

    @Test func aNormalRequestStillWorksUnderTheCap() async throws {
        let (socketPath, cleanup) = try await startServer()
        defer { cleanup() }
        let client = DaemonClient(socketPath: socketPath)
        let info = try await client.request(
            .daemonInfo, params: WireEmpty(), expecting: DaemonInfo.self)
        #expect(info.proto == DirectaVersion.proto)
    }
}
