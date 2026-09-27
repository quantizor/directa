import Darwin
import Foundation

/** The one positional read loop behind every log and spool read. */
public enum PositionalRead {
    /** Fills `buffer` from `offset` of `descriptor` with `pread`, retrying
        an interrupted call; answers how many bytes arrived, fewer than the
        buffer holds at end of file or on an error. */
    public static func read(_ descriptor: Int32, at offset: Int, into buffer: UnsafeMutableRawBufferPointer) -> Int {
        guard let base = buffer.baseAddress, offset >= 0 else { return 0 }
        var filled = 0
        while filled < buffer.count {
            let got = pread(descriptor, base + filled, buffer.count - filled, off_t(offset + filled))
            if got > 0 {
                filled += got
            } else if got < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        return filled
    }
}

/** One log file opened read-only and read with `pread`, so a scan holds one
    chunk at a time rather than the file. */
final class LogFileReader {
    private let descriptor: Int32
    /** The file's inode number: its identity across a rotation's rename,
        which is what a cursor's position names. */
    let inode: UInt64
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
        self.inode = UInt64(info.st_ino)
        self.onDiskRead = onDiskRead
        self.size = Int(info.st_size)
    }

    deinit {
        close(descriptor)
    }

    /** A reader per file that opens, in order; a file gone between listing
        and opening (a rotation mid-query) is left out. */
    static func readers(for urls: [URL], onDiskRead: (@Sendable (Int) -> Void)?) -> [LogFileReader] {
        urls.compactMap { LogFileReader(url: $0, onDiskRead: onDiskRead) }
    }

    /** Up to `count` bytes from `offset`; fewer at end of file or on error. */
    func read(at offset: Int, count: Int) -> [UInt8] {
        guard count > 0, offset >= 0 else { return [] }
        let bytes = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            initialized = PositionalRead.read(descriptor, at: offset, into: UnsafeMutableRawBufferPointer(buffer))
        }
        onDiskRead?(bytes.count)
        return bytes
    }

    func byte(at offset: Int) -> UInt8? {
        read(at: offset, count: 1).first
    }

    /** Calls `body` with every non-empty line from `start` to the end of the
        file and its byte offset, including a final line with no trailing
        newline, until `body` answers false. Lines are read in fixed chunks,
        never the whole file, and no chunk past the stopping line is read.
        Returns false when `body` stopped the walk. */
    @discardableResult
    func forEachLine(from start: Int, _ body: (UnsafeBufferPointer<UInt8>, Int) -> Bool) -> Bool {
        var offset = start
        var pending: [UInt8] = []
        var pendingBase = start
        var going = true
        while going, offset < size {
            let chunk = read(at: offset, count: min(LogScan.chunkBytes, size - offset))
            guard !chunk.isEmpty else { break }
            offset += chunk.count
            pending.append(contentsOf: chunk)
            var consumed = 0
            pending.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var lineStart = 0
                while going, lineStart < buffer.count,
                    let hit = memchr(base + lineStart, Int32(LogScan.newline), buffer.count - lineStart)
                {
                    let end = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                    if end > lineStart {
                        going = body(UnsafeBufferPointer(rebasing: buffer[lineStart..<end]), pendingBase + lineStart)
                    }
                    lineStart = end + 1
                }
                consumed = lineStart
            }
            pending.removeFirst(consumed)
            pendingBase += consumed
        }
        if going, !pending.isEmpty {
            going = pending.withUnsafeBufferPointer { body($0, pendingBase) }
        }
        return going
    }

    /** Calls `body` with every non-empty line before `end`, newest first,
        with its byte offset, until `body` answers false; a line cut by `end`
        counts as a line, as a final unterminated one does going forward.
        Lines are read in fixed chunks from the end, so memory holds one
        chunk plus the longest line however far back the walk goes. Returns
        false when `body` stopped the walk or a read came back short (the
        file shrank under this reader, or an I/O error), since the line
        held across that read can no longer be completed. */
    @discardableResult
    func forEachLineBackward(
        before end: Int, chunkBytes: Int = LogScan.backwardChunkBytes,
        _ body: (UnsafeBufferPointer<UInt8>, Int) -> Bool
    ) -> Bool {
        var chunkStart = min(end, size)
        /** Bytes from `chunkStart` on that belong to a line whose start has
            not been read yet. */
        var pending: [UInt8] = []
        while chunkStart > 0 {
            let readStart = max(0, chunkStart - max(1, chunkBytes))
            let chunk = read(at: readStart, count: chunkStart - readStart)
            guard chunk.count == chunkStart - readStart else { return false }
            chunkStart = readStart
            var buffer = chunk
            buffer.append(contentsOf: pending)
            var going = true
            var keep = 0
            buffer.withUnsafeBufferPointer { bytes in
                var lineEnd = bytes.count
                var index = bytes.count - 1
                while going, index >= 0 {
                    if bytes[index] == LogScan.newline {
                        if lineEnd > index + 1 {
                            going = body(UnsafeBufferPointer(rebasing: bytes[(index + 1)..<lineEnd]), readStart + index + 1)
                        }
                        lineEnd = index
                    }
                    index -= 1
                }
                keep = lineEnd
            }
            guard going else { return false }
            pending = Array(buffer[..<keep])
        }
        guard !pending.isEmpty else { return true }
        return pending.withUnsafeBufferPointer { body($0, 0) }
    }

    /** Where the line holding the byte before `offset` begins: just past the
        nearest newline before `offset`, or 0. */
    func lineStart(atOrBefore offset: Int) -> Int {
        var end = min(offset, size)
        while end > 0 {
            let start = max(0, end - LogScan.probeChunkBytes)
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
            let chunk = read(at: start, count: min(LogScan.probeChunkBytes, size - start))
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
        let head = read(at: offset, count: LogScan.timestampProbeBytes)
        let line = head.prefix { $0 != LogScan.newline }
        guard let tab = line.firstIndex(of: LogScan.tab) else { return nil }
        return head.withUnsafeBufferPointer {
            LogScan.epochMilliseconds(UnsafeBufferPointer(rebasing: $0[..<tab]))
        }
    }

    /** The millisecond of the file's last record, walking back in small
        chunks only as far as that record; nil when the file holds none. */
    func lastRecordMilliseconds() -> Int64? {
        var found: Int64?
        forEachLineBackward(before: size, chunkBytes: LogScan.probeChunkBytes) { line, _ in
            found = LogScan.recordMilliseconds(line)
            return found == nil
        }
        return found
    }
}

/** The forward scan behind every log query except a bare tail. It streams
    each file from a binary-searched start, keeps only the positions of the
    lines a trim can still return (a fixed-size ring per stream for a tail,
    the first N for a head), and reads those lines back once the scan ends,
    so memory tracks the answer rather than the window. A head that reports
    no totals stops reading at its Nth line. Timestamps are parsed
    only where a decision needs one: the binary search, the first line of a
    file under a lower bound (per-file monotonic timestamps make every later
    line pass), and the records a cursor skips. */
enum LogScan {
    static let backwardChunkBytes = 64 * 1024
    static let chunkBytes = 256 * 1024
    /** The read size of a probe that needs only the bytes around one line
        (a line boundary, the last record of a file). */
    static let probeChunkBytes = 4096
    /** Enough bytes to hold any timestamp prefix a record can carry. */
    static let timestampProbeBytes = 64
    static let newline: UInt8 = 0x0A
    static let tab: UInt8 = 0x09

    /** The length of the timestamp `JSONCoding.formatISO8601` writes, which
        the digit-by-digit parser reads. */
    private static let canonicalTimestampLength = 24
    /** Lines kept for reading back sit within this many bytes of each other
        to share one read, and one read never spans more than `maxRunBytes`. */
    private static let maxGapBytes = 4096
    private static let maxRunBytes = 1024 * 1024
    /** Milliseconds beyond this either side of 1970 (about 31,000 years)
        are clamped, so converting an impossible wire date never traps. */
    private static let millisecondLimit = 1e15

    /** What the scan keeps of the lines that pass every filter: the trim
        the options ask for, or only the first and last (a summary needs the
        count, which totals already carry, and two timestamps). */
    enum Retention {
        case firstAndLast
        case trim
    }

    /** The last `count` records in a row stamped `ms`, the newest of them
        ending at byte `end` of reader `file`: a family's newest group, or
        where a positioned cursor lets a scan resume. */
    struct GroupEnd {
        var count: Int
        var end: Int
        var file: Int
        var ms: Int64
    }

    static func scan(
        files: [URL], options: LogQueryOptions, grep: Regex<AnyRegexOutput>?, retention: Retention = .trim,
        onDiskRead: (@Sendable (Int) -> Void)?
    ) -> (lines: [LogRecord], readers: [LogFileReader], resume: GroupEnd?, totals: LogStreamTotals) {
        let cursorMs = options.after.map { milliseconds(of: $0.at) }
        let boundMs = cursorMs ?? options.since.map(ceilingMilliseconds)
        var skipRemaining = options.after?.count ?? 0
        var collector = Collector(options: options, retention: retention)
        var totals = LogStreamTotals()
        let readers = LogFileReader.readers(for: files, onDiskRead: onDiskRead)
        let resume = options.after.flatMap { after in
            after.position.flatMap { resumePoint($0, after: after, readers: readers) }
        }
        if resume != nil { skipRemaining = 0 }
        var sequence = 0
        /** A head that reports no totals has its whole answer once it holds
            its lines; reading on would only count what nobody asked for. */
        let stopsWhenFull = !options.reportsTotals
        for (fileIndex, reader) in readers.enumerated() {
            if stopsWhenFull, collector.headIsFull { break }
            guard reader.size > 0 else { continue }
            let start: Int
            var passedBound: Bool
            if let resume {
                guard fileIndex >= resume.file else { continue }
                start = fileIndex == resume.file ? resume.end : 0
                passedBound = true
            } else {
                /** Whole-file skip: a file whose last record predates the
                    bound cannot contribute. */
                if let boundMs, let last = reader.lastRecordMilliseconds(), last < boundMs {
                    continue
                }
                start = boundMs.map { firstLineStart(atOrAfter: $0, in: reader) } ?? 0
                passedBound = boundMs == nil
            }
            let finished = !reader.forEachLine(from: start) { line, offset in
                guard let shape = LineShape(line) else { return true }
                if !passedBound || skipRemaining > 0 {
                    guard let ms = epochMilliseconds(UnsafeBufferPointer(rebasing: line[..<shape.firstTab]))
                    else { return true }
                    if let boundMs, !passedBound {
                        guard ms >= boundMs else { return true }
                        passedBound = true
                    }
                    if skipRemaining > 0 {
                        if ms == cursorMs {
                            skipRemaining -= 1
                            return true
                        }
                        skipRemaining = 0
                    }
                }
                if let streams = options.streams, !streams.contains(shape.stream) { return true }
                if let grep {
                    let text = String(decoding: UnsafeBufferPointer(rebasing: line[(shape.secondTab + 1)...]), as: UTF8.self)
                    guard (try? grep.firstMatch(in: text)) != nil else { return true }
                }
                totals[shape.stream] += 1
                sequence += 1
                collector.add(
                    Retained(file: fileIndex, length: line.count, offset: offset, sequence: sequence),
                    stream: shape.stream)
                return !(stopsWhenFull && collector.headIsFull)
            }
            if finished { break }
        }
        return (readBack(collector.ordered(), readers: readers), readers, resume, totals)
    }

    /** Where a cursor's position lets a scan resume, or nil when it names
        no file in this family or no record ending there stamped with the
        cursor's millisecond (a file rotated out of the family, or a
        position a caller made up), in which case the count applies. */
    static func resumePoint(_ position: LogFilePosition, after: LogCursor, readers: [LogFileReader]) -> GroupEnd? {
        let cursorMs = milliseconds(of: after.at)
        guard let file = readers.firstIndex(where: { $0.inode == position.file }) else { return nil }
        let reader = readers[file]
        guard position.offset > 0, position.offset <= reader.size,
            position.offset == reader.size || reader.byte(at: position.offset) == newline
        else { return nil }
        let start = reader.lineStart(atOrBefore: position.offset)
        let line = reader.read(at: start, count: position.offset - start)
        guard line.withUnsafeBufferPointer({ recordMilliseconds($0) }) == cursorMs else { return nil }
        return GroupEnd(count: after.count, end: position.offset, file: file, ms: cursorMs)
    }

    /** The newest record of the family, and how many records in a row
        carry its millisecond, counted backward in fixed chunks across files
        (one millisecond's records can straddle a rotation). Nil for a family
        with no records. A resumed scan stops the count at its resume point
        and takes the cursor's own count for the records behind it, so a
        poll after a clock step (which pins every later record to one
        millisecond) reads back only what arrived since the last one, not
        the whole millisecond. */
    static func newestGroup(readers: [LogFileReader], resume: GroupEnd?) -> GroupEnd? {
        var newest: GroupEnd?
        for (file, reader) in readers.enumerated().reversed() {
            if let resume, file < resume.file { break }
            let floor = resume.flatMap { file == $0.file ? $0.end : nil } ?? 0
            let stopped = !reader.forEachLineBackward(before: reader.size) { line, offset in
                guard offset >= floor else { return false }
                guard let ms = recordMilliseconds(line) else { return true }
                guard let current = newest else {
                    newest = GroupEnd(count: 1, end: offset + line.count, file: file, ms: ms)
                    return true
                }
                guard current.ms == ms else { return false }
                newest?.count += 1
                return true
            }
            if stopped { break }
        }
        guard let resume else { return newest }
        guard let found = newest else { return resume }
        /** Timestamps never fall within a family and the record behind the
            resume point carries the cursor's millisecond, so a newest group
            in that same millisecond runs unbroken back to the resume point. */
        guard found.ms == resume.ms else { return found }
        return GroupEnd(count: found.count + resume.count, end: found.end, file: found.file, ms: found.ms)
    }

    /** The start of the first line stamped at or after `boundMs`, by binary
        search over byte offsets. An unparseable midpoint line narrows the
        search to before it, so the scan falls back to reading forward from
        there. */
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
        if prefix.count == canonicalTimestampLength, let fast = canonicalMilliseconds(prefix) { return fast }
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
        let limit = millisecondLimit
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
    private static func readBack(_ items: [Retained], readers: [LogFileReader]) -> [LogRecord] {
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
            let bytes = readers[first.file].read(at: first.offset, count: runEnd - first.offset)
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
            index = end
        }
        return records
    }

    /** The record a line holds, or nil when it is not one or its stream is
        outside `streams` (checked before the payload is decoded). */
    static func record(from line: UnsafeBufferPointer<UInt8>, streams: Set<LogStream>? = nil) -> LogRecord? {
        guard let shape = LineShape(line), streams?.contains(shape.stream) ?? true,
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

/** The tab positions and stream of a record line (the
    `timestamp\tstream\tpayload` layout `LogRecord.formatted` writes), found
    without decoding the line. */
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
    as lines arrive, so a large capacity costs nothing until it fills. A
    class, so the collector's mode can hold it and append in place: a struct
    bound out of an enum case would copy its array on every append. */
private final class LineRing {
    private let capacity: Int?
    private var items: [Retained] = []
    private var start = 0

    init(capacity: Int?) {
        self.capacity = capacity
    }

    func append(_ item: Retained) {
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

/** Oldest-N positions. A class for the same reason as `LineRing`. */
private final class LineHead {
    private(set) var items: [Retained] = []
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    var isFull: Bool { items.count >= limit }

    func append(_ item: Retained) {
        if !isFull { items.append(item) }
    }
}

/** The trim a query asked for, applied as lines match. */
private struct Collector {
    private enum Mode {
        case firstAndLast(first: Retained?, last: Retained?)
        case head(LineHead)
        case tail(LineRing)
        case tailByStream([LogStream: LineRing])
    }

    private var mode: Mode

    /** A summary keeps two lines whatever the options say; otherwise a
        head wins over a per-stream tail, which wins over a plain tail. */
    init(options: LogQueryOptions, retention: LogScan.Retention) {
        if retention == .firstAndLast {
            mode = .firstAndLast(first: nil, last: nil)
        } else if let head = options.head {
            mode = .head(LineHead(limit: head))
        } else if let byStream = options.tailByStream {
            mode = .tailByStream(
                Dictionary(uniqueKeysWithValues: LogStream.allCases.map { ($0, LineRing(capacity: byStream[$0])) }))
        } else {
            mode = .tail(LineRing(capacity: options.tail))
        }
    }

    /** True once a head trim holds every line it will keep. */
    var headIsFull: Bool {
        guard case .head(let head) = mode else { return false }
        return head.isFull
    }

    mutating func add(_ item: Retained, stream: LogStream) {
        switch mode {
        case .firstAndLast(let first, _): mode = .firstAndLast(first: first ?? item, last: item)
        case .head(let head): head.append(item)
        case .tail(let ring): ring.append(item)
        case .tailByStream(let rings): rings[stream]?.append(item)
        }
    }

    func ordered() -> [Retained] {
        switch mode {
        case .firstAndLast(let first?, let last?): first.sequence == last.sequence ? [first] : [first, last]
        case .firstAndLast: []
        case .head(let head): head.items
        case .tail(let ring): ring.ordered()
        case .tailByStream(let rings): rings.values.flatMap { $0.ordered() }.sorted { $0.sequence < $1.sequence }
        }
    }
}
