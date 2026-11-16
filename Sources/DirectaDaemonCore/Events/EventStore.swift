import DirectaKit
import Foundation

/** The daemon-wide event feed: one NDJSON file of EventRecord lines under the
    data dir, size-capped with a single rotation. Supervisors and the router post
    into it; `directa events` and the dashboard timeline read from it. */
public actor EventStore {
    /** Bytes per backward read in `query`: sized so a window of a few lines
        costs one read. */
    private static let readChunkBytes = 64 * 1024

    /** Bumped by every posted event, after its line is written when it can be
        (and on a failed write), so a client woken by it finds the event
        through `query`. Also the home every other
        status-visible change bumps (`StatusChangeSignal`). */
    public nonisolated let changes = StatusChangeSignal()
    private var clamp = TimestampClamp()
    private var handle: FileHandle?
    private let maxBytes: Int
    private let now: @Sendable () -> Date
    private let url: URL

    /** `now` is the clock the clamp's skew rule reads; tests inject one. */
    public init(url: URL, maxBytes: Int = 5 * 1024 * 1024, now: @escaping @Sendable () -> Date = { Date() }) {
        self.maxBytes = maxBytes
        self.now = now
        self.url = url
        /** `query` stops at the first record older than `since`, which holds
            only while timestamps never decrease down the file; starting the
            clamp at the file's newest record keeps that true across a restart
            after the clock stepped back. A newest record past the clamp's
            skew tolerance is rotated away (`TimestampClamp`) and the clamp
            starts at now, leaving each file time-ordered. A rotation that
            fails keeps the clamp at the newest record, since those records
            stay in the live file, and is not retried this run. */
        clamp.resume(at: Self.newestRecordTime(url: url))
        Self.settleClamp(&clamp, handle: &handle, at: now(), url: url)
    }

    deinit {
        try? handle?.close()
    }

    public func post(kind: EventKind, project: String, server: String, detail: String? = nil) {
        /** Every return path wakes parked clients: a post that could not be
            written still changed what a reader should re-read. */
        defer { changes.bump() }
        let current = now()
        Self.settleClamp(&clamp, handle: &handle, at: current, url: url)
        let at = clamp.stamp(current)
        let record = EventRecord(at: at, detail: detail, kind: kind, project: project, server: server)
        guard let line = try? NDJSON.encodeLine(record) else { return }
        openIfNeeded()
        guard let handle else { return }
        try? handle.write(contentsOf: line)
        if let size = try? handle.offset(), size > UInt64(maxBytes) {
            rotate()
        }
    }

    /** Reads need no flush first: `post` hands each line to write(2) with no
        user-space buffer, so a read on another descriptor already sees it.
        A negative `tail` reads as zero; the router refuses one from the wire
        before it gets here.

        Reads each file from its end and stops at the first record older than
        `since`, so a window of new lines costs those lines rather than the
        whole log. Timestamps never decrease down a file (`post` clamps them),
        so nothing newer sits behind an older record; the rotated file is read
        only when the window reaches it. */
    public func query(project: String? = nil, since: Date? = nil, tail: Int? = nil) -> [EventRecord] {
        /** Newest first, so the first `tail` kept records are the answer and
            the walk ends there instead of reading both files whole. */
        let keep = tail.map { max($0, 0) } ?? .max
        guard keep > 0 else { return [] }
        var newestFirst: [EventRecord] = []
        let decoder = JSONCoding.decoder()
        for file in [url, url.appendingPathExtension("1")] {
            let reachedOlder = Self.visitLinesBackward(file) { line in
                guard let record = try? decoder.decode(EventRecord.self, from: line) else { return true }
                if let since, record.at < since { return false }
                if let project, record.project != project { return true }
                newestFirst.append(record)
                return newestFirst.count < keep
            }
            if reachedOlder { break }
        }
        return Array(newestFirst.reversed())
    }

    /** The last record's time in the live file, or in the rotated one when the
        live file holds none yet; `distantPast` for an empty family. */
    private static func newestRecordTime(url: URL) -> Date {
        let decoder = JSONCoding.decoder()
        for file in [url, url.appendingPathExtension("1")] {
            var newest: Date?
            _ = visitLinesBackward(file) { line in
                guard let record = try? decoder.decode(EventRecord.self, from: line) else { return true }
                newest = record.at
                return false
            }
            if let newest { return newest }
        }
        return .distantPast
    }

    /** Calls `visit` on each line of `file`, last line first, until it returns
        false. True when `visit` stopped the walk. An unreadable or empty file
        has no lines. */
    private static func visitLinesBackward(_ file: URL, visit: (Data) -> Bool) -> Bool {
        /** A missing file is an empty family; any other open failure is a read error. */
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let reader: FileHandle
        do { reader = try FileHandle(forReadingFrom: file) } catch {
            DirectaLog.daemon.error("events.log unreadable path=\(file.path) error=\(error)")
            return false
        }
        defer { try? reader.close() }
        guard var offset = try? reader.seekToEnd() else { return false }
        /** The leading partial line of the block just read, completed by the
            next block read before it. */
        var carry = Data()
        while offset > 0 {
            let start = offset > UInt64(readChunkBytes) ? offset - UInt64(readChunkBytes) : 0
            let block: Data?
            do {
                try reader.seek(toOffset: start)
                block = try reader.read(upToCount: Int(offset - start))
            } catch {
                DirectaLog.daemon.error("events.log read failed path=\(file.path) offset=\(start) error=\(error)")
                return false
            }
            guard let block else { return false }
            offset = start
            var segments = (block + carry).split(separator: 0x0A, omittingEmptySubsequences: false)
            carry = Data()
            if start > 0, let partial = segments.first {
                carry = Data(partial)
                segments.removeFirst()
            }
            for line in segments.reversed() {
                if !visit(line) { return true }
            }
        }
        return false
    }

    private func openIfNeeded() {
        guard handle == nil else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    /** Rotates the live file aside when the clamp is ahead of `current`
        (`TimestampClamp.settle`). */
    private static func settleClamp(
        _ clamp: inout TimestampClamp, handle: inout FileHandle?, at current: Date, url: URL
    ) {
        clamp.settle(now: current) {
            try? handle?.close()
            handle = nil
            return rotateAside(url)
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        _ = Self.rotateAside(url)
        openIfNeeded()
    }

    /** Moves a non-empty `url` over its `.1` file. False when a step failed
        (logged), leaving `url` where it was; an empty or missing file is
        already rotated. */
    private static func rotateAside(_ url: URL) -> Bool {
        let fm = FileManager.default
        let rotated = url.appendingPathExtension("1")
        guard ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) > 0 else { return true }
        do {
            if fm.fileExists(atPath: rotated.path) { try fm.removeItem(at: rotated) }
            try fm.moveItem(at: url, to: rotated)
            return true
        } catch {
            DirectaLog.daemon.error("events.log rotation failed path=\(url.path) error=\(error)")
            return false
        }
    }
}
