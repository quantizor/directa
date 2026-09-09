import DirectaKit
import Foundation

/** Split a byte buffer on 0x0A without copying the unread tail once per line.
    Incomplete tail is `remainder`, except a tail longer than `maxPartialBytes`
    is emitted in segments of that size so a newline-less flood cannot grow
    without bound. Each returned slice is copied so the caller can drop
    `buffer`. Peak extra memory is the returned lines, so the caller must bound
    `buffer` (the tailer reads a fixed chunk). */
enum SpoolLineSplit {
    static func pull(from buffer: Data, maxPartialBytes: Int) -> (lines: [Data], remainder: Data) {
        var lines: [Data] = []
        var start = buffer.startIndex
        while start < buffer.endIndex {
            guard let newline = buffer[start...].firstIndex(of: 0x0A) else { break }
            if start < newline {
                lines.append(Data(buffer[start..<newline]))
            }
            start = buffer.index(after: newline)
        }
        if maxPartialBytes > 0 {
            while buffer.endIndex - start > maxPartialBytes {
                let cut = start + maxPartialBytes
                lines.append(Data(buffer[start..<cut]))
                start = cut
            }
        }
        let remainder = start < buffer.endIndex ? Data(buffer[start...]) : Data()
        return (lines, remainder)
    }
}

/** Tails one raw spool file (the fd the child writes; survives daemon death)
    into the structured LogStore. Polling keeps it simple and restart-safe; an
    idle tick still opens the file and seeks to the end, not a cheap stat. */
actor SpoolTailer {
    private let intervalMs: Int
    /** Unread bytes above this are skipped to the recent tail. Replaying a
        flood into a rotating structured log (10 MB) is wasted work, and a
        drain of that backlog would block `stop`. */
    private let maxCatchUpBytes: Int
    /** Partial-line cap: a line longer than this flushes in segments. */
    private let maxPartialBytes = 16 * 1024
    private var offset: UInt64 = 0
    private var partial = Data()
    /** One drain never holds more than this plus `maxPartialBytes` of leftover.
        Reading the whole unread tail and then removing each line from the front
        of that `Data` copies the remainder once per line and keeps the original
        allocation alive for the whole drain. */
    private let readChunkBytes: Int
    private let store: LogStore
    private let stream: LogStream
    private var task: Task<Void, Never>?
    private let url: URL

    init(
        intervalMs: Int = 100, maxCatchUpBytes: Int = 1_048_576, readChunkBytes: Int = 64 * 1024,
        store: LogStore, stream: LogStream, url: URL
    ) {
        self.intervalMs = intervalMs
        self.maxCatchUpBytes = max(0, maxCatchUpBytes)
        self.readChunkBytes = max(1, readChunkBytes)
        self.store = store
        self.stream = stream
        self.url = url
    }

    func start() {
        guard task == nil else { return }
        task = Task { [intervalMs] in
            while !Task.isCancelled {
                await self.drain()
                try? await Task.sleep(for: .milliseconds(intervalMs))
            }
        }
    }

    /** Stops polling after a final drain so exit-time output is not lost. */
    func stop() async {
        task?.cancel()
        task = nil
        await drain()
        await flushPartial()
    }

    private func drain() async {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        /** Truncation (a fresh start reuses the path) resets the cursor. */
        if size < offset { offset = 0; partial.removeAll() }
        guard size > offset else { return }
        var dropUntilNewline = false
        if maxCatchUpBytes > 0 {
            let unread = size - offset
            let cap = UInt64(maxCatchUpBytes)
            if unread > cap {
                let skipped = unread - cap
                offset = size - cap
                partial.removeAll()
                dropUntilNewline = true
                await store.append(
                    stream: .sys,
                    text: "spool catch-up skipped \(skipped) bytes")
            }
        }
        try? handle.seek(toOffset: offset)
        /** Chunked reads, never `readToEnd`. Advance by bytes actually read so a
            child that appends after the size snapshot cannot leave the cursor
            behind data already ingested (duplicate lines, doubled error tally).
            The polling task checks cancellation between chunks so a `stop` call
            can run; `stop` itself still drains, and catch-up skip keeps that
            bounded. */
        while !Task.isCancelled {
            guard let data = try? handle.read(upToCount: readChunkBytes), !data.isEmpty else {
                return
            }
            offset += UInt64(data.count)
            var chunk = data
            if dropUntilNewline {
                guard let newline = chunk.firstIndex(of: 0x0A) else { continue }
                chunk = Data(chunk[chunk.index(after: newline)...])
                dropUntilNewline = false
                if chunk.isEmpty { continue }
            }
            await ingest(chunk: chunk)
        }
    }

    private func flushPartial() async {
        guard !partial.isEmpty else { return }
        let chunk = partial
        partial.removeAll()
        await emit(lines: [chunk])
    }

    private func ingest(chunk: Data) async {
        let buffer: Data
        if partial.isEmpty {
            buffer = chunk
        } else {
            partial.append(chunk)
            buffer = partial
            partial = Data()
        }
        let pulled = SpoolLineSplit.pull(from: buffer, maxPartialBytes: maxPartialBytes)
        partial = pulled.remainder
        await emit(lines: pulled.lines)
    }

    private func emit(lines: [Data]) async {
        guard !lines.isEmpty else { return }
        var texts: [String] = []
        texts.reserveCapacity(lines.count)
        for lineData in lines {
            /** Lossy decode handles binary junk; the sanitizer strips NULs,
                ANSI/OSC escapes, and spinner rewrites. */
            let text = LogSanitizer.sanitize(String(decoding: lineData, as: UTF8.self))
            if !text.isEmpty { texts.append(text) }
        }
        guard !texts.isEmpty else { return }
        await store.append(stream: stream, texts: texts)
    }
}
