import DirectaKit
import Foundation

/** Owner of one server's structured log family (current.log + rotations).
    Every line flows through append(): timestamps are clamped monotonic per file
    (the since-query binary search depends on the sorted invariant), rotation
    happens at line boundaries, and marks share the same path so their ordering
    against process output is exact. */
public actor LogStore {
    private let currentURL: URL
    private var handle: FileHandle?
    private var clamp = TimestampClamp()
    private var markCounter = 0
    private let maxBytes: Int
    private let now: @Sendable () -> Date
    /** Set once an open failure is logged, so a store that cannot open its
        file logs it once rather than per line. */
    private var openFailureLogged = false
    private var writeFailureLogged = false
    private var writtenBytes: UInt64 = 0

    /** `now` is the clock the clamp's skew rule reads; tests inject one. */
    public init(currentURL: URL, maxBytes: Int = 10 * 1024 * 1024, now: @escaping @Sendable () -> Date = { Date() }) {
        self.currentURL = currentURL
        self.maxBytes = maxBytes
        self.now = now
    }

    deinit {
        try? handle?.close()
    }

    @discardableResult
    public func append(stream: LogStream, text: String, at date: Date? = nil) -> LogRecord {
        let record = LogRecord(at: clamped(date ?? now()), stream: stream, text: text)
        write(Data((record.formatted() + "\n").utf8))
        return record
    }

    /** One actor hop for a burst so a flood does not pay a hop per line.
        Every line of the burst carries one timestamp, so it is formatted
        once, and the lines up to a rotation boundary go out in one write;
        lines after a rotation take the clamp again, since the `rotated`
        line may have moved it. */
    public func append(stream: LogStream, texts: [String], at date: Date? = nil) {
        let date = date ?? now()
        var next = texts.startIndex
        while next < texts.endIndex {
            let prefix = Data("\(JSONCoding.formatISO8601(clamped(date)))\t\(stream.rawValue)\t".utf8)
            var run = Data()
            while next < texts.endIndex {
                run.append(prefix)
                run.append(contentsOf: texts[next].utf8)
                run.append(0x0A)
                next += 1
                if writtenBytes + UInt64(run.count) > UInt64(maxBytes) { break }
            }
            write(run)
        }
    }

    /** Monotonic clamp: an NTP step or wake-time sync must never write a
        timestamp earlier than the previous line. Opening first resumes the
        clamp from the file's last record before the first line is stamped;
        the skew check then costs one comparison per call. */
    private func clamped(_ date: Date) -> Date {
        openIfNeeded()
        restartClampIfAhead()
        return clamp.stamp(date)
    }

    /** A correlation marker; payload = `<id>\t<label>\t<text>` so queries can
        resolve `--since-mark` and attribute the mark to its requester. */
    public func appendMark(label: String, text: String) -> PlacedMark {
        markCounter += 1
        let id = "m\(Int(now().timeIntervalSince1970))-\(markCounter)"
        let record = append(stream: .mark, text: "\(id)\t\(label)\t\(text)")
        return PlacedMark(at: record.at, id: id, server: currentURL.deletingLastPathComponent().lastPathComponent)
    }

    /** Reads need no flush first: `write` hands each line to write(2) with no
        user-space buffer, so a read on another descriptor already sees it, and
        this actor orders every append before or after the whole query. */
    public func query(_ options: LogQueryOptions) -> [LogRecord] {
        LogQuery.run(current: currentURL, options: options)
    }

    public func window(_ options: LogQueryOptions) -> LogWindow {
        LogQuery.window(current: currentURL, options: options)
    }

    public func resolveMark(_ markID: String) -> Date? {
        LogQuery.markDate(current: currentURL, markID: markID)
    }

    private func openIfNeeded() {
        guard handle == nil else { return }
        let dir = currentURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: currentURL.path) {
                FileManager.default.createFile(atPath: currentURL.path, contents: nil)
            }
            let opened = try FileHandle(forWritingTo: currentURL)
            writtenBytes = try opened.seekToEnd()
            handle = opened
        } catch {
            writtenBytes = 0
            if !openFailureLogged {
                openFailureLogged = true
                DirectaLog.daemon.error("log open failed path=\(currentURL.path) error=\(error)")
            }
        }
        /** Resume the clamp from what is already on disk, or rotated files would
            let a clock step slip a regression into the family. */
        if let last = LogQuery.lastRecordDate(of: currentURL) {
            clamp.resume(at: last)
        }
    }

    /** A clamp past `TimestampClamp`'s tolerance (found at open or after a
        clock correction mid-run) rotates the file and restarts at now. A
        rotation that cannot move the live file keeps the clamp, since the
        future records stay in it and the file must stay sorted, and is not
        retried this run. */
    private func restartClampIfAhead() {
        let current = now()
        if clamp.settle(now: current, rotate: shiftFamily) {
            startRotatedFile(at: current)
        }
    }

    private func rotate() {
        _ = shiftFamily()
        startRotatedFile(at: now())
    }

    private func startRotatedFile(at date: Date) {
        openIfNeeded()
        writtenBytes = 0
        append(stream: .sys, text: SysLineText.rotated, at: date)
    }

    /** Moves the live file to `.1` and each rotation up one. False when the
        live file could not move (logged). */
    private func shiftFamily() -> Bool {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let oldest = currentURL.appendingPathExtension("\(LogQuery.rotations)")
        try? fm.removeItem(at: oldest)
        for index in stride(from: LogQuery.rotations - 1, through: 1, by: -1) {
            let from = currentURL.appendingPathExtension("\(index)")
            let to = currentURL.appendingPathExtension("\(index + 1)")
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }
        do {
            try fm.moveItem(at: currentURL, to: currentURL.appendingPathExtension("1"))
            return true
        } catch {
            DirectaLog.daemon.error("log rotation failed path=\(currentURL.path) error=\(error)")
            return false
        }
    }

    private func write(_ data: Data) {
        openIfNeeded()
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            if !writeFailureLogged {
                writeFailureLogged = true
                DirectaLog.daemon.error("log write failed path=\(currentURL.path) error=\(error)")
            }
            return
        }
        writtenBytes += UInt64(data.count)
        if writtenBytes > UInt64(maxBytes) {
            rotate()
        }
    }
}
