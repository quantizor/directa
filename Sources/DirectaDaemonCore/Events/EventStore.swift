import DirectaKit
import Foundation

/** The daemon-wide event feed: one NDJSON file of EventRecord lines under the
    data dir, size-capped with a single rotation. Supervisors and the router post
    into it; `directa events` and the dashboard timeline read from it. */
public actor EventStore {
    private var handle: FileHandle?
    private var lastTimestamp = Date.distantPast
    private let maxBytes: Int
    private let url: URL

    public init(url: URL, maxBytes: Int = 5 * 1024 * 1024) {
        self.maxBytes = maxBytes
        self.url = url
    }

    deinit {
        try? handle?.close()
    }

    public func post(kind: EventKind, project: String, server: String, detail: String? = nil) {
        let at = JSONCoding.canonicalMs(max(Date(), lastTimestamp))
        lastTimestamp = at
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
        before it gets here. */
    public func query(project: String? = nil, since: Date? = nil, tail: Int? = nil) -> [EventRecord] {
        var events: [EventRecord] = []
        let decoder = JSONCoding.decoder()
        for file in [url.appendingPathExtension("1"), url] {
            guard let data = try? Data(contentsOf: file), !data.isEmpty else { continue }
            for line in data.split(separator: 0x0A) {
                guard let record = try? decoder.decode(EventRecord.self, from: line) else { continue }
                if let project, record.project != project { continue }
                if let since, record.at < since { continue }
                events.append(record)
            }
        }
        guard let tail else { return events }
        return Array(events.suffix(max(tail, 0)))
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

    private func rotate() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("1"))
        openIfNeeded()
    }
}
