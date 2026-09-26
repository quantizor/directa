import Darwin
import Foundation

/** One log file opened read-only and read with `pread`, so a scan holds one
    chunk at a time rather than the file. */
final class LogFileReader {
    private let descriptor: Int32
    private let onDiskRead: (@Sendable (Int) -> Void)?
    let size: Int

    init?(url: URL, onDiskRead: (@Sendable (Int) -> Void)?) {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
        self.onDiskRead = onDiskRead
        self.size = Int(info.st_size)
    }

    deinit {
        close(descriptor)
    }

    /** Up to `count` bytes from `offset`; fewer at end of file or on error. */
    func read(at offset: Int, count: Int) -> [UInt8] {
        guard count > 0, offset >= 0 else { return [] }
        let bytes = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            initialized = 0
            guard let base = buffer.baseAddress else { return }
            while initialized < count {
                let got = pread(descriptor, base + initialized, count - initialized, off_t(offset + initialized))
                if got > 0 {
                    initialized += got
                } else if got < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
        onDiskRead?(bytes.count)
        return bytes
    }

    func byte(at offset: Int) -> UInt8? {
        read(at: offset, count: 1).first
    }

    /** Calls `body` with every non-empty line from `start` to the end of the
        file and its byte offset, including a final line with no trailing
        newline. Lines are read in fixed chunks, never the whole file. */
    func forEachLine(from start: Int, _ body: (UnsafeBufferPointer<UInt8>, Int) -> Void) {
        var offset = start
        var pending: [UInt8] = []
        var pendingBase = start
        while offset < size {
            let chunk = read(at: offset, count: min(LogScan.chunkBytes, size - offset))
            guard !chunk.isEmpty else { break }
            offset += chunk.count
            pending.append(contentsOf: chunk)
            var consumed = 0
            pending.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var lineStart = 0
                while lineStart < buffer.count,
                    let hit = memchr(base + lineStart, Int32(LogScan.newline), buffer.count - lineStart)
                {
                    let end = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                    if end > lineStart {
                        body(UnsafeBufferPointer(rebasing: buffer[lineStart..<end]), pendingBase + lineStart)
                    }
                    lineStart = end + 1
                }
                consumed = lineStart
            }
            pending.removeFirst(consumed)
            pendingBase += consumed
        }
        if !pending.isEmpty {
            pending.withUnsafeBufferPointer { body($0, pendingBase) }
        }
    }

    /** Where the line holding the byte before `offset` begins: just past the
        nearest newline before `offset`, or 0. */
    func lineStart(atOrBefore offset: Int) -> Int {
        var end = min(offset, size)
        while end > 0 {
            let start = max(0, end - 4096)
            let chunk = read(at: start, count: end - start)
            guard !chunk.isEmpty else { return 0 }
            if let index = chunk.lastIndex(of: LogScan.newline) { return start + index + 1 }
            end = start
        }
        return 0
    }

    /** Offset just past the first newline at or after `offset`, or the size. */
    func nextLineStart(after offset: Int) -> Int {
        var start = offset
        while start < size {
            let chunk = read(at: start, count: min(4096, size - start))
            guard !chunk.isEmpty else { break }
            if let index = chunk.firstIndex(of: LogScan.newline) { return start + index + 1 }
            start += chunk.count
        }
        return size
    }

    /** The timestamp prefix of the line starting at `offset`, in
        milliseconds; nil when the line has none. A timestamp is short, so
        only the first bytes are read. */
    func milliseconds(atLineStart offset: Int) -> Int64? {
        let head = read(at: offset, count: 64)
        let line = head.prefix { $0 != LogScan.newline }
        guard let tab = line.firstIndex(of: LogScan.tab) else { return nil }
        return head.withUnsafeBufferPointer {
            LogScan.epochMilliseconds(UnsafeBufferPointer(rebasing: $0[..<tab]))
        }
    }
}

/** The forward scan behind every log query except a bare tail. It streams
    each file from a binary-searched start, keeps only the positions of the
    lines a trim can still return (a fixed-size ring per stream for a tail,
    the first N for a head), and reads those lines back once the scan ends,
    so memory tracks the answer rather than the window. Timestamps are parsed
    only where a decision needs one: the binary search, the first line of a
    file under a lower bound (per-file monotonic timestamps make every later
    line pass), and the records a cursor skips. */
enum LogScan {
    static let chunkBytes = 256 * 1024
    static let newline: UInt8 = 0x0A
    static let tab: UInt8 = 0x09

    /** Lines kept for reading back sit within this many bytes of each other
        to share one read, and one read never spans more than `maxRunBytes`. */
    private static let maxGapBytes = 4096
    private static let maxRunBytes = 1024 * 1024

    static func scan(
        files: [URL], options: LogQueryOptions, grep: Regex<AnyRegexOutput>?,
        onDiskRead: (@Sendable (Int) -> Void)?
    ) -> (lines: [LogRecord], totals: LogStreamCounts) {
        let cursorMs = options.after.map { milliseconds(of: $0.at) }
        let boundMs = cursorMs ?? options.since.map(ceilingMilliseconds)
        var skipRemaining = max(0, options.after?.count ?? 0)
        var collector = Collector(options: options)
        var totals = LogStreamCounts(err: 0, mark: 0, out: 0, sys: 0)
        var readers: [LogFileReader?] = Array(repeating: nil, count: files.count)
        var sequence = 0
        for (fileIndex, url) in files.enumerated() {
            /** Whole-file skip: a file whose last line predates the bound
                cannot contribute. */
            if let boundMs, let last = LogQuery.lastLineTimestamp(of: url), milliseconds(of: last) < boundMs {
                continue
            }
            guard let reader = LogFileReader(url: url, onDiskRead: onDiskRead), reader.size > 0 else {
                continue
            }
            readers[fileIndex] = reader
            let start = boundMs.map { firstLineStart(atOrAfter: $0, in: reader) } ?? 0
            var passedBound = boundMs == nil
            reader.forEachLine(from: start) { line, offset in
                guard let shape = LineShape(line) else { return }
                if !passedBound || skipRemaining > 0 {
                    guard let ms = epochMilliseconds(UnsafeBufferPointer(rebasing: line[..<shape.firstTab]))
                    else { return }
                    if let boundMs, !passedBound {
                        guard ms >= boundMs else { return }
                        passedBound = true
                    }
                    if skipRemaining > 0 {
                        if ms == cursorMs {
                            skipRemaining -= 1
                            return
                        }
                        skipRemaining = 0
                    }
                }
                if let streams = options.streams, !streams.contains(shape.stream) { return }
                if let grep {
                    let text = String(decoding: UnsafeBufferPointer(rebasing: line[(shape.secondTab + 1)...]), as: UTF8.self)
                    guard (try? grep.firstMatch(in: text)) != nil else { return }
                }
                totals[shape.stream] = (totals[shape.stream] ?? 0) + 1
                sequence += 1
                collector.add(
                    Retained(file: fileIndex, length: line.count, offset: offset, sequence: sequence),
                    stream: shape.stream)
            }
        }
        return (readBack(collector.ordered(), readers: readers), totals)
    }

    /** Port of the in-memory search this file family always used, over byte
        offsets: the start of the first line stamped at or after `boundMs`.
        An unparseable midpoint line narrows the search to before it, so the
        scan falls back to reading forward from there. */
    static func firstLineStart(atOrAfter boundMs: Int64, in reader: LogFileReader) -> Int {
        var low = 0
        var high = reader.size
        while low < high {
            let mid = (low + high) / 2
            let lineStart = reader.lineStart(atOrBefore: mid)
            guard let stamp = reader.milliseconds(atLineStart: lineStart) else {
                high = lineStart
                if high <= low { break }
                continue
            }
            if stamp < boundMs {
                let next = reader.nextLineStart(after: lineStart)
                if next == lineStart { break }
                low = next
            } else {
                high = lineStart
            }
        }
        return reader.lineStart(atOrBefore: min(low, reader.size))
    }

    /** Non-empty line ranges in `bytes`, a final unterminated line included. */
    static func lineRanges(in bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for (index, byte) in bytes.enumerated() where byte == newline {
            if index > start { ranges.append(start..<index) }
            start = index + 1
        }
        if start < bytes.count { ranges.append(start..<bytes.count) }
        return ranges
    }

    /** A line's timestamp in milliseconds when it is a well-formed record
        (a timestamp, a known stream, and a payload); nil otherwise. The one
        predicate that decides what a cursor counts. */
    static func recordMilliseconds(_ line: UnsafeBufferPointer<UInt8>) -> Int64? {
        guard let shape = LineShape(line) else { return nil }
        return epochMilliseconds(UnsafeBufferPointer(rebasing: line[..<shape.firstTab]))
    }

    /** Milliseconds since 1970 for a timestamp prefix. The exact shape
        `JSONCoding.formatISO8601` writes is read digit by digit; anything
        else goes through `JSONCoding.parseISO8601`, so both answer the same
        instant for every input the store can hold. */
    static func epochMilliseconds(_ prefix: UnsafeBufferPointer<UInt8>) -> Int64? {
        if prefix.count == 24, let fast = canonicalMilliseconds(prefix) { return fast }
        guard let date = JSONCoding.parseISO8601(String(decoding: prefix, as: UTF8.self)) else { return nil }
        return milliseconds(of: date)
    }

    static func milliseconds(of date: Date) -> Int64 {
        clampedMilliseconds((date.timeIntervalSince1970 * 1000).rounded())
    }

    /** The first millisecond at or after `date`: every stored record carries
        a whole millisecond, so `record < date` holds exactly when the
        record's millisecond is below this. */
    static func ceilingMilliseconds(_ date: Date) -> Int64 {
        let rounded = milliseconds(of: date)
        return self.date(milliseconds: rounded) < date ? rounded + 1 : rounded
    }

    static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /** `Int64(_:)` traps on a non-finite or out-of-range Double; a wire date
        is finite in practice, and this keeps an impossible one from trapping. */
    private static func clampedMilliseconds(_ value: Double) -> Int64 {
        let limit = 1e15
        guard value.isFinite else { return value < 0 ? -Int64(limit) : Int64(limit) }
        return Int64(min(max(value, -limit), limit))
    }

    private static func canonicalMilliseconds(_ prefix: UnsafeBufferPointer<UInt8>) -> Int64? {
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let digit = Int(prefix[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard prefix[4] == 0x2D, prefix[7] == 0x2D, prefix[10] == 0x54, prefix[13] == 0x3A,
            prefix[16] == 0x3A, prefix[19] == 0x2E, prefix[23] == 0x5A,
            let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
            let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
            let milli = number(20..<23),
            year >= 1970, (1...12).contains(month), day >= 1, day <= daysIn(month: month, year: year),
            hour < 24, minute < 60, second < 60
        else { return nil }
        let seconds = daysFromCivil(year: year, month: month, day: day) * 86_400 + hour * 3600 + minute * 60 + second
        return Int64(seconds) * 1000 + Int64(milli)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /** Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's
        days_from_civil). */
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shifted = month <= 2 ? year - 1 : year
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /** Reads the kept lines back, nearby ones in one read, and parses them. */
    private static func readBack(_ items: [Retained], readers: [LogFileReader?]) -> [LogRecord] {
        var records: [LogRecord] = []
        records.reserveCapacity(items.count)
        var index = 0
        while index < items.count {
            let first = items[index]
            var end = index + 1
            var runEnd = first.offset + first.length
            while end < items.count, items[end].file == first.file,
                items[end].offset - runEnd <= maxGapBytes,
                items[end].offset + items[end].length - first.offset <= maxRunBytes
            {
                runEnd = items[end].offset + items[end].length
                end += 1
            }
            if let reader = readers[first.file] {
                let bytes = reader.read(at: first.offset, count: runEnd - first.offset)
                bytes.withUnsafeBufferPointer { buffer in
                    for item in items[index..<end] {
                        let lower = item.offset - first.offset
                        let upper = lower + item.length
                        guard upper <= buffer.count,
                            let record = record(from: UnsafeBufferPointer(rebasing: buffer[lower..<upper]))
                        else { continue }
                        records.append(record)
                    }
                }
            }
            index = end
        }
        return records
    }

    private static func record(from line: UnsafeBufferPointer<UInt8>) -> LogRecord? {
        guard let shape = LineShape(line),
            let ms = epochMilliseconds(UnsafeBufferPointer(rebasing: line[..<shape.firstTab]))
        else { return nil }
        let text = String(decoding: UnsafeBufferPointer(rebasing: line[(shape.secondTab + 1)...]), as: UTF8.self)
        return LogRecord(at: date(milliseconds: ms), stream: shape.stream, text: text)
    }
}

/** A kept line's position; `sequence` is its place in file order. */
private struct Retained {
    var file: Int
    var length: Int
    var offset: Int
    var sequence: Int
}

/** The tab positions and stream of a record line, the parts
    `LogRecord.parse` splits on, found without decoding the line. */
private struct LineShape {
    let firstTab: Int
    let secondTab: Int
    let stream: LogStream

    init?(_ line: UnsafeBufferPointer<UInt8>) {
        guard let firstTab = line.firstIndex(of: LogScan.tab),
            let secondTab = line[(firstTab + 1)...].firstIndex(of: LogScan.tab)
        else { return nil }
        guard let stream = Self.stream(line, from: firstTab + 1, to: secondTab) else { return nil }
        self.firstTab = firstTab
        self.secondTab = secondTab
        self.stream = stream
    }

    /** Matches the stream field against each `LogStream` raw value byte by
        byte, since decoding a String per line is the cost this avoids. */
    private static func stream(_ line: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> LogStream? {
        for stream in LogStream.allCases {
            let name = stream.rawValue.utf8
            guard name.count == end - start else { continue }
            if zip(name, line[start..<end]).allSatisfy({ $0 == $1 }) { return stream }
        }
        return nil
    }
}

/** Newest-N positions, or every position when `capacity` is nil. Grows only
    as lines arrive, so a large capacity costs nothing until it fills. */
private struct LineRing {
    let capacity: Int?
    private var items: [Retained] = []
    private var start = 0

    init(capacity: Int?) {
        self.capacity = capacity.map { max(0, $0) }
    }

    mutating func append(_ item: Retained) {
        guard let capacity else {
            items.append(item)
            return
        }
        guard capacity > 0 else { return }
        if items.count < capacity {
            items.append(item)
        } else {
            items[start] = item
            start = (start + 1) % capacity
        }
    }

    func ordered() -> [Retained] {
        Array(items[start...] + items[..<start])
    }
}

/** The trim a query asked for, applied as lines match. */
private struct Collector {
    private var headItems: [Retained] = []
    private let headLimit: Int?
    private let perStream: Bool
    /** One ring per stream under `tailByStream`, else one ring for all. */
    private var rings: [LineRing]

    init(options: LogQueryOptions) {
        headLimit = options.head.map { max(0, $0) }
        if let byStream = options.tailByStream {
            perStream = true
            rings = LogStream.allCases.map { LineRing(capacity: byStream[$0]) }
        } else {
            perStream = false
            rings = [LineRing(capacity: options.tail)]
        }
    }

    mutating func add(_ item: Retained, stream: LogStream) {
        if let headLimit {
            if headItems.count < headLimit { headItems.append(item) }
            return
        }
        rings[perStream ? Self.ringIndex(stream) : 0].append(item)
    }

    /** Position in `LogStream.allCases`, the order the rings are built in. */
    private static func ringIndex(_ stream: LogStream) -> Int {
        switch stream {
        case .err: 0
        case .mark: 1
        case .out: 2
        case .sys: 3
        }
    }

    func ordered() -> [Retained] {
        if headLimit != nil { return headItems }
        guard perStream else { return rings[0].ordered() }
        return rings.flatMap { $0.ordered() }.sorted { $0.sequence < $1.sequence }
    }
}
