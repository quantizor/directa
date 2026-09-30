import Darwin
import Foundation

/** Incremental framing on 0x0A: feed raw bytes, get each complete non-empty
    line back without its newline, copied so the caller can drop what it fed.
    Bytes after the last newline wait for a later feed. Only the bytes fed
    since the previous call are scanned, so one very long line costs time
    linear in its length however many feeds deliver it. */
public struct LineFramer: Sendable {
    /** Bytes that belong to a line whose newline has not arrived. */
    private var pending = Data()
    /** Set by `discardThroughNextNewline`: the next bytes up to and
        including a newline belong to a line whose start was dropped. */
    private var discarding = false
    /** A pending run longer than this is handed back in segments of this
        size, so a newline-less flood cannot grow memory without bound; nil
        holds every pending byte until its newline. */
    private let maxPartialBytes: Int?

    public init(maxPartialBytes: Int? = nil) {
        self.maxPartialBytes = maxPartialBytes.map { max(1, $0) }
    }

    /** Bytes held with no newline seen yet: the line in progress. */
    public var pendingByteCount: Int { pending.count }

    public mutating func feed(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        let scanFrom = pending.count
        pending.append(data)
        var lines: [Data] = []
        var consumed = 0
        pending.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var searchFrom = scanFrom
            if discarding {
                guard let hit = memchr(base + searchFrom, 0x0A, raw.count - searchFrom) else {
                    consumed = raw.count
                    return
                }
                discarding = false
                searchFrom = base.distance(to: UnsafeRawPointer(hit)) + 1
                consumed = searchFrom
            }
            while searchFrom < raw.count, let hit = memchr(base + searchFrom, 0x0A, raw.count - searchFrom) {
                let end = base.distance(to: UnsafeRawPointer(hit))
                if end > consumed { lines.append(Data(bytes: base + consumed, count: end - consumed)) }
                consumed = end + 1
                searchFrom = consumed
            }
            if let maxPartialBytes {
                while raw.count - consumed > maxPartialBytes {
                    lines.append(Data(bytes: base + consumed, count: maxPartialBytes))
                    consumed += maxPartialBytes
                }
            }
        }
        if consumed == pending.count {
            pending = Data()
        } else if consumed > 0 {
            pending = Data(pending[(pending.startIndex + consumed)...])
        }
        return lines
    }

    /** The line in progress, if any, handed back as final and cleared. */
    public mutating func flush() -> Data? {
        guard !pending.isEmpty else { return nil }
        defer { pending = Data() }
        return pending
    }

    /** Drops the line in progress and ends any discard. */
    public mutating func reset() {
        pending = Data()
        discarding = false
    }

    /** Drops the line in progress and the rest of whatever line the next
        bytes continue, up to and including its newline: for a reader that
        just jumped into the middle of a line. */
    public mutating func discardThroughNextNewline() {
        pending = Data()
        discarding = true
    }
}
