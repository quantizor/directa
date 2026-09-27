import Foundation
import os

/** The daemon's telemetry file: NDJSON through JSONCoding, size-rotated, with
    each line's `time` clamped monotonic so a clock step never reorders it.
    Lines are plain `write(2)` with no fsync: a SIGKILL keeps whatever reached
    the page cache, and an fsync per line would put a disk flush in the path
    of every mark. Thread-safe; a write holds one unfair lock for the syscall. */
public final class TelemetryLog: Sendable {
    public static let fileName = "telemetry.log"
    public static let defaultKeepRotated = 4

    public let directory: URL
    /** Rotated files kept beside the current one, named `telemetry.log.1`
        (newest) through `.<keepRotated>`. */
    public let keepRotated: Int
    public let maxBytes: Int

    private struct State {
        var descriptor: Int32 = -1
        var failedWrites = 0
        var lastTime = Date.distantPast
        var writtenBytes = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(directory: URL, keepRotated: Int = defaultKeepRotated, maxBytes: Int = 10 * 1024 * 1024) {
        self.directory = directory
        self.keepRotated = keepRotated
        self.maxBytes = maxBytes
    }

    public var currentURL: URL { directory.appending(path: Self.fileName) }

    public static func rotatedURL(in directory: URL, index: Int) -> URL {
        directory.appending(path: "\(fileName).\(index)")
    }

    public func rotatedURL(_ index: Int) -> URL {
        Self.rotatedURL(in: directory, index: index)
    }

    /** Writes that failed (disk full, a vanished directory). A telemetry
        write never throws into the daemon; this count is how a test or a
        reader learns lines were lost. */
    public var failedWrites: Int { state.withLock { $0.failedWrites } }

    public func append<Line: TelemetryLine>(_ line: Line) {
        state.withLock { state in
            openIfNeeded(&state)
            let clamped = JSONCoding.canonicalMs(max(line.time, state.lastTime))
            var stamped = line
            stamped.time = clamped
            guard let encoded = try? NDJSON.encodeLine(stamped) else {
                state.failedWrites += 1
                return
            }
            if state.writtenBytes > 0, state.writtenBytes + encoded.count > maxBytes {
                rotate(&state)
                openIfNeeded(&state)
            }
            guard state.descriptor >= 0, Self.writeAll(encoded, to: state.descriptor) else {
                state.failedWrites += 1
                return
            }
            state.writtenBytes += encoded.count
            state.lastTime = clamped
        }
    }

    public func close() {
        state.withLock { state in
            if state.descriptor >= 0 { Darwin.close(state.descriptor) }
            state.descriptor = -1
        }
    }

    private func openIfNeeded(_ state: inout State) {
        guard state.descriptor < 0 else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(currentURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return }
        var info = stat()
        state.writtenBytes = fstat(descriptor, &info) == 0 ? Int(info.st_size) : 0
        state.descriptor = descriptor
        /** Resume the clamp from what a previous run left, or a clock that
            stepped back across a restart would write an earlier time after a
            later one in the same file. */
        let decoder = JSONCoding.decoder()
        if let last = Self.tailLines(of: currentURL, count: 1).last
            .flatMap({ LineHead(line: $0, decoder: decoder)?.time })
        {
            state.lastTime = max(state.lastTime, last)
        }
    }

    private func rotate(_ state: inout State) {
        if state.descriptor >= 0 { Darwin.close(state.descriptor) }
        state.descriptor = -1
        state.writtenBytes = 0
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: rotatedURL(keepRotated))
        if keepRotated > 1 {
            for index in stride(from: keepRotated - 1, through: 1, by: -1) {
                Darwin.rename(rotatedURL(index).path, rotatedURL(index + 1).path)
            }
        }
        if keepRotated > 0 {
            Darwin.rename(currentURL.path, rotatedURL(1).path)
        } else {
            try? fileManager.removeItem(at: currentURL)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pointer += written
                remaining -= written
            }
            return true
        }
    }

    /** The fields a reader of the previous run needs from any line. Each is
        optional, so a line of any shape decodes; `event` stays a string so a
        mark name this build does not know still yields the line's time. */
    public struct LineHead: Decodable, Equatable, Sendable {
        public var daemonPid: Int32?
        public var event: String?
        public var time: Date?

        public init?(line: String, decoder: JSONDecoder) {
            guard let head = try? decoder.decode(LineHead.self, from: Data(line.utf8)) else { return nil }
            self = head
        }
    }

    /** The newest `count` lines across the current file and its rotations,
        oldest first. Each file is read backward in chunks, so the cost tracks
        the lines asked for rather than the file sizes. */
    public static func lastLines(in directory: URL, count: Int, keepRotated: Int = defaultKeepRotated) -> [String] {
        var collected: [String] = []
        let files =
            [directory.appending(path: fileName)]
            + (0..<max(0, keepRotated)).map { rotatedURL(in: directory, index: $0 + 1) }
        for url in files where collected.count < count {
            let lines = tailLines(of: url, count: count - collected.count)
            collected = lines + collected
        }
        return collected
    }

    /** The last `count` non-empty lines of one file, oldest first. A final
        line with no newline (a write the kill interrupted) is kept: it is the
        last thing the process said. */
    public static func tailLines(of url: URL, count: Int, chunkBytes: Int = 64 * 1024) -> [String] {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return [] }
        var offset = end
        /** Newest first; joined once at the end so each byte is copied once. */
        var chunks: [Data] = []
        var newlines = 0
        while offset > 0 {
            let step = min(UInt64(chunkBytes), offset)
            offset -= step
            guard (try? handle.seek(toOffset: offset)) != nil,
                let chunk = try? handle.read(upToCount: Int(step))
            else { break }
            chunks.append(chunk)
            newlines += chunk.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            if newlines > count { break }
        }
        let buffer = chunks.reversed().reduce(into: Data()) { $0.append($1) }
        var lines = buffer.split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        if offset > 0, !lines.isEmpty {
            /** The first piece started mid-line when the read stopped short of
                the file's start. */
            lines.removeFirst()
        }
        return Array(lines.suffix(count))
    }
}
