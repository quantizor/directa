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

/** Which already-ingested spool bytes can have their disk blocks released.
    The spool is written by a child through a descriptor directa cannot
    reopen or reposition (the daemon's own open for a direct spawn, launchd's
    O_APPEND open for an agent-mode job), so the file is never truncated or
    renamed during a run: the ingested prefix is turned into a hole instead
    (`F_PUNCHHOLE`, which APFS requires to be block aligned). The apparent
    size keeps growing with the child's writes; the allocated size stays near
    `retainBytes` plus whatever the tailer has not read yet. */
enum SpoolRelease {
    /** The block-aligned range to release, or nil when less than a step's
        worth is eligible: everything from `releasedThrough` up to `retainBytes`
        short of `ingestedThrough`. Releasing in steps of a quarter of the
        retained window (at least one block) keeps the syscall off every
        tick of a slow writer. */
    static func range(
        blockBytes: Int, ingestedThrough: UInt64, releasedThrough: UInt64, retainBytes: Int
    ) -> Range<UInt64>? {
        let block = UInt64(max(1, blockBytes))
        let retain = UInt64(max(0, retainBytes))
        guard ingestedThrough > retain else { return nil }
        let end = (ingestedThrough - retain) / block * block
        let step = max(block, retain / 4)
        guard end > releasedThrough, end - releasedThrough >= step else { return nil }
        return releasedThrough..<end
    }

    /** Punches `range` out of the file at `path`: 0 on success, else the
        errno. A writable descriptor is required (a read-only one answers
        EPERM); opening one neither truncates nor moves the child's offset. */
    static func punchHole(path: String, range: Range<UInt64>) -> Int32 {
        let descriptor = open(path, O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return errno }
        defer { close(descriptor) }
        var hole = fpunchhole_t(
            fp_flags: 0, reserved: 0, fp_offset: off_t(range.lowerBound), fp_length: off_t(range.count))
        return fcntl(descriptor, F_PUNCHHOLE, &hole) == 0 ? 0 : errno
    }

    /** The volume's allocation block, which `F_PUNCHHOLE` ranges must align
        to; 4096 (the APFS block) when the volume cannot be read. */
    static func blockBytes(path: String) -> Int {
        var info = statfs()
        guard statfs(path, &info) == 0, info.f_bsize > 0 else { return 4096 }
        return Int(info.f_bsize)
    }
}

/** Coalesces catch-up skips into at most one report per `interval`. A flood
    that outruns the tailer skips on nearly every chunk, and a sys line per
    skip would flood the structured log and every monitor watching it, since
    sys lines pass monitor budgets. The skipping itself is never deferred;
    only the line that names it is. */
struct SkipReport {
    let interval: Duration
    private var lastReported: ContinuousClock.Instant?
    private var pending: UInt64 = 0

    init(interval: Duration) {
        self.interval = interval
    }

    /** Adds a skip and answers the total to report now, if one is due. */
    mutating func add(_ bytes: UInt64, now: ContinuousClock.Instant) -> UInt64? {
        pending += bytes
        return due(now: now)
    }

    /** The unreported total once `interval` has passed since the last
        report (or there has been none), else nil. */
    mutating func due(now: ContinuousClock.Instant) -> UInt64? {
        guard pending > 0 else { return nil }
        if let lastReported, now - lastReported < interval { return nil }
        return take(now: now)
    }

    /** The unreported total regardless of the interval, for a final drain. */
    mutating func flush(now: ContinuousClock.Instant) -> UInt64? {
        guard pending > 0 else { return nil }
        return take(now: now)
    }

    private mutating func take(now: ContinuousClock.Instant) -> UInt64 {
        let total = pending
        pending = 0
        lastReported = now
        return total
    }
}

/** Tails one raw spool file (the fd the child writes; survives daemon death)
    into the structured LogStore. Polling keeps it simple and restart-safe; an
    idle tick still opens the file and seeks to the end, not a cheap stat. */
actor SpoolTailer {
    /** Set by a catch-up skip, which lands mid-line: the rest of that line
        is dropped rather than ingested as if it were whole, however many
        chunks or drains it takes to reach its newline. */
    private var droppingUntilNewline = false
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
    /** Returns 0 or an errno; a seam so a test can stand in for a volume
        that refuses hole punching. */
    private let releaseHole: @Sendable (String, Range<UInt64>) -> Int32
    /** Set once the volume refuses to release blocks, so the refusal is
        reported once rather than retried every chunk. */
    private var releaseRefused = false
    /** Everything below this offset is already released. */
    private var releasedThrough: UInt64 = 0
    /** Ingested raw bytes kept readable behind the read cursor; older ones
        are released (see `SpoolRelease`). */
    private let retainBytes: Int
    /** True until the first drain has run: gates the end-of-file seed so it
        applies once, at attach, and never again on a later drain. */
    private var seedingAtEnd: Bool
    private var skipReport = SkipReport(interval: .seconds(1))
    private let store: LogStore
    private let stream: LogStream
    private var task: Task<Void, Never>?
    private let url: URL
    /** Read once, at the first release. */
    private var volumeBlockBytes: Int?

    /** `startAtEnd` seeds `offset` to the file's current size before the first
        drain reads anything, so re-attaching to a spool a prior run already
        wrote into (a jetsam-surviving child being adopted) ingests only bytes
        appended from this point forward. Lines written while no daemon was
        tailing the file stay in the raw spool only, never reaching the
        structured log; the alternative, back-reading from offset 0, would
        duplicate every line the prior run's tailer already ingested. Defaults
        to false, which preserves ingesting from the start for an ordinary
        spawn. */
    init(
        intervalMs: Int = 100, maxCatchUpBytes: Int = 1_048_576, readChunkBytes: Int = 64 * 1024,
        releaseHole: @escaping @Sendable (String, Range<UInt64>) -> Int32 = SpoolRelease.punchHole,
        retainBytes: Int = 1_048_576, startAtEnd: Bool = false, store: LogStore, stream: LogStream,
        url: URL
    ) {
        self.intervalMs = intervalMs
        self.maxCatchUpBytes = max(0, maxCatchUpBytes)
        self.readChunkBytes = max(1, readChunkBytes)
        self.releaseHole = releaseHole
        self.retainBytes = max(0, retainBytes)
        self.seedingAtEnd = startAtEnd
        self.store = store
        self.stream = stream
        self.url = url
    }

    func start() {
        guard task == nil else { return }
        task = Task { [intervalMs] in
            while !Task.isCancelled {
                await self.drain(yieldsToCancellation: true)
                try? await Task.sleep(for: .milliseconds(intervalMs))
            }
        }
    }

    /** Stops polling after a final drain so exit-time output is not lost,
        even when the caller's own task is already cancelled. */
    func stop() async {
        task?.cancel()
        task = nil
        await drain(yieldsToCancellation: false)
        await reportSkipped(skipReport.flush(now: .now))
        await flushPartial()
    }

    /** Reads the unread tail one chunk per pass, re-reading the size before
        each: a child that writes as fast as the tailer reads never lets a
        drain reach end of file, so the catch-up skip and the block release
        both run per chunk rather than once per drain, or neither would ever
        run under a sustained flood. Chunked reads, never `readToEnd`; the
        offset advances by bytes actually read, so a child that appends
        after a size read cannot leave the cursor behind data already
        ingested (duplicate lines, doubled error tally). The polling task
        passes `yieldsToCancellation` so it stops between chunks once `stop`
        cancels it; `stop` drains to the end, and the catch-up skip keeps
        that bounded. */
    private func drain(yieldsToCancellation: Bool) async {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        while !(yieldsToCancellation && Task.isCancelled) {
            guard await skipToReadable(size: (try? handle.seekToEnd()) ?? 0),
                (try? handle.seek(toOffset: offset)) != nil,
                let data = try? handle.read(upToCount: readChunkBytes), !data.isEmpty
            else { break }
            offset += UInt64(data.count)
            var chunk = data
            if droppingUntilNewline {
                guard let newline = chunk.firstIndex(of: 0x0A) else { continue }
                chunk = Data(chunk[chunk.index(after: newline)...])
                droppingUntilNewline = false
            }
            if !chunk.isEmpty { await ingest(chunk: chunk) }
            await releaseIngested()
        }
        await releaseIngested()
        await reportSkipped(skipReport.due(now: .now))
    }

    private func reportSkipped(_ bytes: UInt64?) async {
        guard let bytes else { return }
        await store.append(stream: .sys, text: "spool catch-up skipped \(bytes) bytes")
    }

    /** Settles `offset` against the file's current `size` (the attach seed, a
        truncation by a fresh start, a backlog past the catch-up cap) and
        answers whether unread bytes remain. */
    private func skipToReadable(size: UInt64) async -> Bool {
        if seedingAtEnd {
            offset = size
            partial.removeAll()
            seedingAtEnd = false
        }
        if size < offset {
            offset = 0
            partial.removeAll()
            droppingUntilNewline = false
            releasedThrough = 0
        }
        guard size > offset else { return false }
        let cap = UInt64(maxCatchUpBytes)
        if maxCatchUpBytes > 0, size - offset > cap {
            let skipped = size - offset - cap
            offset = size - cap
            partial.removeAll()
            droppingUntilNewline = true
            await reportSkipped(skipReport.add(skipped, now: .now))
        }
        return true
    }

    private func releaseIngested() async {
        let blockBytes = volumeBlockBytes ?? SpoolRelease.blockBytes(path: url.path)
        volumeBlockBytes = blockBytes
        guard !releaseRefused,
            let range = SpoolRelease.range(
                blockBytes: blockBytes, ingestedThrough: offset, releasedThrough: releasedThrough,
                retainBytes: retainBytes)
        else { return }
        let failure = releaseHole(url.path, range)
        guard failure != 0 else {
            releasedThrough = range.upperBound
            return
        }
        releaseRefused = true
        let reason = String(cString: strerror(failure))
        DirectaLog.supervisor.error("cannot release ingested bytes of \(url.path): \(reason)")
        await store.append(
            stream: .sys,
            text: "\(url.lastPathComponent) cannot shrink on this volume (\(reason)), so it grows until the server restarts")
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
