import DirectaKit
import Foundation

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

    /** When the held total becomes reportable; nil with nothing held. A total
        is only ever held after a report (`add` reports the first at once), so
        `lastReported` is set whenever `pending` is. */
    var dueAt: ContinuousClock.Instant? {
        guard pending > 0, let lastReported else { return nil }
        return lastReported + interval
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
    into the structured LogStore. The spool is opened once and held until
    `stop`, since it is never truncated or renamed while its run lasts. A
    kernel vnode source on that descriptor wakes the tailer on every write
    (a quiet server costs no wakeups); a wake is a hint to drain, never data,
    so wakes coalesce and a spurious one (the tailer's own hole punch fires
    one) finds nothing to read. A drain holds a lock for its whole run, so a
    `catchUp` that returns has every complete line written before it in the
    store (a partial line stays in the framer, and a backlog past the cap is
    skipped and named). Once `stop` or `pause` is called the tailer never
    reads again. */
actor SpoolTailer {
    /** Answers a duplicate of the spool descriptor for the write watch, or a
        negative value (errno set) when none can be had; a seam so a test can
        stand in for descriptor exhaustion. */
    private let armWatch: @Sendable (Int32) -> Int32
    /** Whether a drain is running; drains never overlap, since one suspended
        in a store append would otherwise let a later drain return before the
        earlier one's lines are written. */
    private var drainBusy = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    /** Set by `stop` and `pause`, for good (a tailer serves one run): a
        `catchUp` that reaches the actor by reentrancy afterward must neither
        read past the position a pause recorded nor reopen the spool a stop
        closed. */
    private var finished = false
    /** Splits read bytes into lines. A line longer than `maxPartialLineBytes`
        flushes in segments of that size; after a catch-up skip, which lands
        mid-line, the rest of that line is dropped rather than ingested as if
        it were whole, however many chunks or drains it takes to reach its
        newline. */
    private var framer = LineFramer(maxPartialBytes: SpoolTailer.maxPartialLineBytes)
    /** Every spool byte before this offset has been ingested or skipped: the
        point the block release trails by `retainBytes`. */
    var ingestedThrough: UInt64 { offset }
    /** Unread bytes above this are skipped to the recent tail; 0 means no
        cap. Replaying a flood into a rotating structured log (10 MB) is wasted
        work, and a drain of that backlog would block `stop`. */
    private let maxCatchUpBytes: Int
    private var offset: UInt64 = 0
    /** Called at the top of every drain, so a test can count wakeups. */
    private let onDrain: (@Sendable () -> Void)?
    /** One drain never holds more than this plus the framer's partial line. */
    private let readChunkBytes: Int
    /** Returns 0 or an errno; a seam so a test can stand in for a volume
        that refuses hole punching. */
    private let releaseHole: @Sendable (String, Range<UInt64>) -> Int32
    /** Set once the volume refuses to release blocks, so the refusal is
        reported once rather than retried every chunk. */
    private var releaseRefused = false
    /** Everything below this offset is already released. */
    private var releasedThrough: UInt64 = 0
    /** Where the daemon that handed this run over stopped reading; see
        `init`. */
    private let resumeFrom: SpoolPosition?
    /** Ingested raw bytes kept readable behind the read cursor; older ones
        are released (see `SpoolRelease`). */
    private let retainBytes: Int
    /** True until the first drain has run: gates the end-of-file seed so it
        applies once, at attach, and never again on a later drain. */
    private var seedingAtEnd: Bool
    private var skipReport = SkipReport(interval: SpoolTailer.skipReportInterval)
    /** The one pending wake at the due time of a held skip notice; drains
        otherwise run only on writes, so a quiet server would hold the notice
        until its next line. */
    private var skipWake: Task<Void, Never>?
    /** The open spool, read-only; nil until `start` or a drain opens it and
        after `stop` closes it. Read afresh after every suspension, since
        `stop` can close it while a drain is suspended. */
    private var spool: Int32?
    private let store: LogStore
    private let stream: LogStream
    private var task: Task<Void, Never>?
    private let url: URL
    /** Read once, at the first release. */
    private var volumeBlockBytes: Int?
    /** Feeds the following task; nil unless started. */
    private var wake: AsyncStream<Void>.Continuation?
    /** Set once the watch could not be armed, so a retry on every timed
        pass logs the refusal once. */
    private var watchRefused = false
    /** The kernel write watch, on a duplicate of `spool` that its cancel
        handler closes. */
    private var watcher: DispatchSourceFileSystemObject?

    /** `startAtEnd` seeds `offset` to the file's current size before the first
        drain reads anything, so re-attaching to a spool a prior run already
        wrote into (a jetsam-surviving child being adopted) ingests only bytes
        appended from this point forward. Lines written while no daemon was
        tailing the file stay in the raw spool only, never reaching the
        structured log; the alternative, back-reading from offset 0, would
        duplicate every line the prior run's tailer already ingested. An
        ordinary spawn leaves it false and ingests from the start.

        `resumeFrom` (with `startAtEnd`) is the position a handing-over
        daemon recorded: when the spool is still the same file (device and
        inode) and at least that long, reading resumes there, so the lines the
        child wrote during the bounce are ingested exactly once; otherwise the
        seed is the end of the file as above. The catch-up cap applies to the
        resumed backlog like any other. */
    init(
        armWatch: @escaping @Sendable (Int32) -> Int32 = { fcntl($0, F_DUPFD_CLOEXEC, 0) },
        maxCatchUpBytes: Int = 1_048_576, onDrain: (@Sendable () -> Void)? = nil, readChunkBytes: Int = 64 * 1024,
        releaseHole: @escaping @Sendable (String, Range<UInt64>) -> Int32 = SpoolRelease.punchHole,
        resumeFrom: SpoolPosition? = nil, retainBytes: Int = 1_048_576, startAtEnd: Bool = false,
        store: LogStore, stream: LogStream, url: URL
    ) {
        self.armWatch = armWatch
        self.maxCatchUpBytes = max(0, maxCatchUpBytes)
        self.onDrain = onDrain
        self.readChunkBytes = max(1, readChunkBytes)
        self.releaseHole = releaseHole
        self.resumeFrom = resumeFrom
        self.retainBytes = max(0, retainBytes)
        self.seedingAtEnd = startAtEnd
        self.store = store
        self.stream = stream
        self.url = url
    }

    deinit {
        if let spool { close(spool) }
    }

    /** Starts following the spool: the watch is armed before the first drain,
        so a write between the two still produces a wake. */
    func start() {
        guard task == nil else { return }
        let (wakes, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wake = signal
        if openSpool() { watchSpool() }
        task = Task { await self.follow(wakes) }
    }

    /** Ingests every complete line the spool holds at this moment (a child
        still writing is not chased; a partial line stays in the framer; a
        backlog past the catch-up cap is skipped and named) and answers once
        it is in the store, leaving the tailer running. A caller that is about to read the log or place a mark
        calls it first, so what the child wrote before is ordered before. */
    func catchUp() async {
        await drain(yieldsToCancellation: false)
    }

    /** Stops following after a final drain so exit-time output is not lost,
        even when the caller's own task is already cancelled. The drain reads
        to the size the spool has when it begins, so an orphan still writing
        cannot hold the caller. */
    func stop() async {
        detach()
        finished = true
        await drain(yieldsToCancellation: false, finalizing: true)
        await reportSkipped(skipReport.flush(now: .now))
        await flushPartial()
        if let spool { close(spool) }
        spool = nil
    }

    /** Ends following for a handoff to the next daemon: ingests what the spool
        holds at this moment, once (a child still writing is not chased, so a
        flood cannot hold the exit; the catch-up cap bounds the rest), and
        answers where the next daemon resumes. That is the start of the line
        in progress, which stays unlogged here so the next daemon logs it
        whole, not the offset read to. Nil when the spool cannot be read. */
    func pause() async -> SpoolPosition? {
        detach()
        finished = true
        await drain(yieldsToCancellation: false, finalizing: true)
        await reportSkipped(skipReport.flush(now: .now))
        guard let info = spoolStat() else { return nil }
        return SpoolPosition(
            bytesRead: offset - min(offset, UInt64(framer.pendingByteCount)), device: Int(info.st_dev),
            inode: UInt64(info.st_ino))
    }

    /** Reads the unread tail one chunk per pass, re-reading the size before
        each: a child that writes as fast as the tailer reads never lets a
        drain reach end of file, so the catch-up skip and the block release
        both run per chunk rather than once per drain, or neither would ever
        run under a sustained flood. Chunked reads, never the whole tail; the
        offset advances by bytes actually read, so a child that appends
        after a size read cannot leave the cursor behind data already
        ingested (duplicate lines, doubled error tally). The following task
        passes `yieldsToCancellation` so it stops between chunks once `stop`
        cancels it. A drain stops at the size the spool has when it begins: a
        flood that never lets a chase reach end of file then still releases
        the drain lock between wakes, so a `catchUp` or `stop` waits one
        bounded drain, not the flood. `finalizing` marks the drain `stop` or
        `pause` runs after setting `finished`; any other drain that finds
        `finished` returns at once. */
    private func drain(yieldsToCancellation: Bool, finalizing: Bool = false) async {
        await acquireDrain()
        defer { releaseDrain() }
        if finished && !finalizing { return }
        if yieldsToCancellation && Task.isCancelled { return }
        onDrain?()
        guard openSpool(), let limit = spoolSize() else { return }
        while !(yieldsToCancellation && Task.isCancelled) {
            guard let fileSize = spoolSize() else { break }
            let size = min(limit, fileSize)
            let readable = await skipToReadable(size: size, fileSize: fileSize)
            guard readable, let chunk = readChunk(), !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)
            await emit(lines: framer.feed(chunk))
            await releaseIngested()
        }
        await releaseIngested()
        await reportSkipped(skipReport.due(now: .now))
        scheduleHeldSkipReport()
    }

    /** One wake at the due time of a skip notice still held; `follow` drains
        on it, spaced like any other drain. */
    private func scheduleHeldSkipReport() {
        guard skipWake == nil, !finished, let dueAt = skipReport.dueAt else { return }
        skipWake = Task {
            try? await Task.sleep(until: dueAt, clock: .continuous)
            self.wakeForHeldSkipReport()
        }
    }

    private func wakeForHeldSkipReport() {
        skipWake = nil
        guard !Task.isCancelled else { return }
        wake?.yield()
    }

    private func acquireDrain() async {
        while drainBusy {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
        drainBusy = true
    }

    private func releaseDrain() {
        drainBusy = false
        if !drainWaiters.isEmpty { drainWaiters.removeFirst().resume() }
    }

    /** Drains once now, then once per wake. Without a watch (the spool does
        not exist yet, or descriptor exhaustion) the gap is the wait, and each
        pass retries opening the spool and arming the watch. */
    private func follow(_ wakes: AsyncStream<Void>) async {
        var wakeIterator = wakes.makeAsyncIterator()
        var lastDrainEnd = ContinuousClock.now - Self.minimumDrainGap
        while !Task.isCancelled {
            /** A flood leaves a wake buffered at every pass, so without a gap a
                flooded tailer would drain back to back. The gap since the last
                drain ended caps that at ten drains a second and costs a write
                after a quiet spell nothing, since the gap is long past by then. */
            try? await Task.sleep(until: lastDrainEnd + Self.minimumDrainGap, clock: .continuous)
            if openSpool() { watchSpool() }
            await drain(yieldsToCancellation: true)
            lastDrainEnd = .now
            if watcher != nil, await wakeIterator.next() == nil { break }
        }
    }

    /** Also the period of a spool that has no watch. Under a flood this bounds
        one stream's ingest at about 10 MB a second, and the catch-up skip
        names the rest. */
    private static let minimumDrainGap = Duration.milliseconds(100)

    /** At most one skip notice a second, however often a flood skips. */
    private static let skipReportInterval = Duration.seconds(1)

    /** The framer's cap on a line held without its newline. */
    private static let maxPartialLineBytes = 16 * 1024

    private func detach() {
        task?.cancel()
        task = nil
        skipWake?.cancel()
        skipWake = nil
        watcher?.cancel()
        watcher = nil
        wake?.finish()
        wake = nil
    }

    private func openSpool() -> Bool {
        if spool != nil { return true }
        let opened = open(url.path, O_RDONLY | O_CLOEXEC)
        guard opened >= 0 else { return false }
        spool = opened
        return true
    }

    /** Both events: an append is an extend plus a write, a hole punch a write alone. */
    private func watchSpool() {
        guard watcher == nil, let spool, let wake else { return }
        let duplicate = armWatch(spool)
        guard duplicate >= 0 else {
            if !watchRefused {
                watchRefused = true
                DirectaLog.supervisor.error(
                    "cannot watch \(url.path) for writes, polling every \(Self.minimumDrainGap) instead: \(String(cString: strerror(errno)))")
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: duplicate, eventMask: [.extend, .write], queue: .global(qos: .utility))
        source.setEventHandler { wake.yield() }
        source.setCancelHandler { close(duplicate) }
        source.resume()
        watcher = source
    }

    private func spoolSize() -> UInt64? {
        spoolStat().map { UInt64($0.st_size) }
    }

    private func spoolStat() -> stat? {
        guard let spool else { return nil }
        var info = stat()
        guard fstat(spool, &info) == 0 else { return nil }
        return info
    }

    /** The recorded offset when the open spool is the file it was recorded
        for and is at least that long, else nil. */
    private func resumableOffset(size: UInt64) -> UInt64? {
        guard let resumeFrom, let info = spoolStat(),
            Int(info.st_dev) == resumeFrom.device, UInt64(info.st_ino) == resumeFrom.inode,
            size >= resumeFrom.bytesRead
        else { return nil }
        return resumeFrom.bytesRead
    }

    /** Up to `readChunkBytes` from `offset`; empty at end of file. */
    private func readChunk() -> Data? {
        guard let spool else { return nil }
        var chunk = Data(count: readChunkBytes)
        let got = chunk.withUnsafeMutableBytes { PositionalRead.read(spool, at: Int(offset), into: $0) }
        chunk.count = got
        return chunk
    }

    private func reportSkipped(_ bytes: UInt64?) async {
        guard let bytes else { return }
        await store.append(stream: .sys, text: "spool catch-up skipped \(bytes) bytes")
    }

    /** Settles `offset` against `size`, how far this drain may read (the
        attach seed, a backlog past the catch-up cap), and the file's real
        `fileSize` (a truncation by a fresh start), and answers whether
        unread bytes remain. A drain bounded below the file's size must not
        read a chunk past its bound and then mistake that for a truncation,
        which is why the two sizes are separate. */
    private func skipToReadable(size: UInt64, fileSize: UInt64) async -> Bool {
        if seedingAtEnd {
            offset = resumableOffset(size: size) ?? size
            framer.reset()
            seedingAtEnd = false
        }
        if fileSize < offset {
            offset = 0
            framer.reset()
            releasedThrough = 0
        }
        guard size > offset else { return false }
        let cap = UInt64(maxCatchUpBytes)
        if maxCatchUpBytes > 0, size - offset > cap {
            let skipped = size - offset - cap
            offset = size - cap
            framer.discardThroughNextNewline()
            /** Released before the next await (the report, or the emit of the
                chunk read after it), so the tailer never yields with a
                skipped backlog still holding data behind its read point. */
            await releaseIngested()
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
        guard let partial = framer.flush() else { return }
        await emit(lines: [partial])
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
