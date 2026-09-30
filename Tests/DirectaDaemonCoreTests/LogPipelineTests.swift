import DirectaKit
import DirectaTestSupport
import Foundation
import Testing
import os

@testable import DirectaDaemonCore

private func tempDir() throws -> URL {
    try TemporaryTree.directory(named: "pipe")
}

@Suite(.temporaryTree) struct LogStoreTests {
    @Test func clampKeepsTimestampsMonotonic() async throws {
        let store = LogStore(currentURL: try tempDir().appending(path: "current.log"))
        let late = Date()
        let early = late.addingTimeInterval(-3600)
        let first = await store.append(stream: .out, text: "one", at: late)
        /** A clock step backwards must not write a regressing timestamp. */
        let second = await store.append(stream: .out, text: "two", at: early)
        #expect(second.at >= first.at)
    }

    @Test func rotationShiftsFamilyAndKeepsWriting() async throws {
        let current = try tempDir().appending(path: "current.log")
        let store = LogStore(currentURL: current, maxBytes: 1200)
        for index in 0..<40 {
            await store.append(stream: .out, text: "line \(index) padding padding padding")
        }
        let rotated = current.appendingPathExtension("1")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        /** The whole family still reads back in order through the query engine. */
        let all = await store.query(LogQueryOptions(streams: [.out]))
        #expect(all.count == 40)
        #expect(all.first?.text.hasPrefix("line 0 ") == true)
        #expect(all.last?.text.hasPrefix("line 39 ") == true)
    }

    /** A store opened over a log whose last record is later than the clock
        (a backward clock step across a daemon restart) stamps even its very
        first append at or after that record, one line or a burst. */
    @Test func theFirstAppendResumesTheClampFromDisk() async throws {
        let dir = try tempDir()
        let later = Date(timeIntervalSince1970: 4_102_444_800)
        for burst in [false, true] {
            let current = dir.appending(path: "current-\(burst).log")
            try Data((LogRecord(at: later, stream: .out, text: "from the last run").formatted() + "\n").utf8)
                .write(to: current)
            let store = LogStore(currentURL: current)
            if burst {
                await store.append(stream: .out, texts: ["one", "two"])
            } else {
                await store.append(stream: .out, text: "one")
            }
            let stamps = await store.query(LogQueryOptions()).map(\.at)
            #expect(stamps.count == (burst ? 3 : 2))
            #expect(stamps.allSatisfy { $0 >= later }, "burst \(burst): \(stamps)")
        }
    }

    /** A burst lands in order, one timestamp for every line up to the first
        rotation, and each rotated file ends on the line that carried it past
        the cap, exactly where appending one line at a time would rotate. */
    @Test func aBurstIsWrittenInOrderAndRotatesOnTheLineThatCrossesTheCap() async throws {
        let current = try tempDir().appending(path: "current.log")
        let maxBytes = 1200
        let store = LogStore(currentURL: current, maxBytes: maxBytes)
        let at = Date(timeIntervalSince1970: 1_700_000_000.123)
        let texts = (0..<40).map { "line \($0) padding padding padding" }
        await store.append(stream: .out, texts: texts, at: at)
        let all = await store.query(LogQueryOptions())
        #expect(all.filter { $0.stream == .out }.map(\.text) == texts)
        #expect(all.filter { $0.stream == .sys }.map(\.text) == ["rotated", "rotated"])
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.at <= $1.at })
        #expect(all.prefix { $0.stream == .out }.allSatisfy { $0.at == at })
        for rotation in [2, 1] {
            let bytes = try Data(contentsOf: current.appendingPathExtension("\(rotation)"))
            let lastLine = try #require(bytes.dropLast().split(separator: 0x0A).last)
            #expect(bytes.count > maxBytes, "rotation \(rotation)")
            #expect(bytes.count - (lastLine.count + 1) <= maxBytes, "rotation \(rotation)")
        }
    }

    @Test func marksCarryIDAndResolve() async throws {
        let currentURL = try tempDir().appending(path: "current.log")
        let store = LogStore(currentURL: currentURL)
        /** An explicit earlier timestamp: a ms-granular since-bound necessarily
            includes same-millisecond neighbors, so "before" must not share the
            mark's millisecond for this assertion to be deterministic. */
        await store.append(stream: .out, text: "before", at: Date().addingTimeInterval(-1))
        let mark = await store.appendMark(label: "pid-1", text: "test begins")
        await store.append(stream: .out, text: "after")
        #expect(await store.resolveMark(mark.id) == mark.at)
        let since = await store.query(LogQueryOptions(since: mark.at, streams: [.out]))
        #expect(since.map(\.text) == ["after"])
    }
}

@Suite struct SpoolReleaseTests {
    private func range(ingested: UInt64, released: UInt64 = 0, retain: Int = 64 * 1024) -> Range<UInt64>? {
        SpoolRelease.range(
            blockBytes: 4096, ingestedThrough: ingested, releasedThrough: released, retainBytes: retain)
    }

    @Test func releasesBlockAlignedUpToTheRetainedWindow() {
        /** 1_000_000 - 65_536 = 934_464, rounded down to a block. */
        #expect(range(ingested: 1_000_000) == 0..<933_888)
        #expect(range(ingested: 1_000_000, released: 409_600) == 409_600..<933_888)
    }

    @Test func holdsBackUntilAStepIsEligible() {
        /** A quarter of the retained window is the step. */
        #expect(range(ingested: 65_536 + 12_288) == nil)
        #expect(range(ingested: 65_536 + 16_384) == 0..<16_384)
        #expect(range(ingested: 65_536 + 16_384 + 12_288, released: 16_384) == nil)
        #expect(range(ingested: 65_536) == nil)
        #expect(range(ingested: 1_000) == nil)
    }

    @Test func aZeroWindowReleasesEveryWholeBlock() {
        #expect(range(ingested: 4095, retain: 0) == nil)
        #expect(range(ingested: 8191, retain: 0) == 0..<4096)
        #expect(range(ingested: 8192, released: 8192, retain: 0) == nil)
    }
}

@Suite struct SkipReportTests {
    /** The first skip reports at once; skips inside the next second add up
        and report together once it has passed, never one line each. */
    @Test func skipsInsideAnIntervalReportAsOneTotal() {
        let start = ContinuousClock.now
        var report = SkipReport(interval: .seconds(1))
        #expect(report.add(100, now: start) == 100)
        #expect(report.add(20, now: start + .milliseconds(50)) == nil)
        #expect(report.add(30, now: start + .milliseconds(400)) == nil)
        #expect(report.due(now: start + .milliseconds(999)) == nil)
        #expect(report.due(now: start + .milliseconds(1000)) == 50)
        #expect(report.due(now: start + .milliseconds(5000)) == nil)
        #expect(report.add(7, now: start + .milliseconds(5000)) == 7)
    }

    @Test func aFlushReportsWhateverIsPendingAtOnce() {
        let start = ContinuousClock.now
        var report = SkipReport(interval: .seconds(1))
        #expect(report.flush(now: start) == nil)
        #expect(report.add(10, now: start) == 10)
        #expect(report.add(5, now: start + .milliseconds(10)) == nil)
        #expect(report.flush(now: start + .milliseconds(20)) == 5)
        #expect(report.flush(now: start + .milliseconds(30)) == nil)
        #expect(report.add(1, now: start + .milliseconds(40)) == nil)
    }
}

@Suite(.temporaryTree) struct SpoolTailerTests {
    @Test func tailsIncrementallyAndSanitizes() async throws {
        let dir = try tempDir()
        let spool = dir.appending(path: "out.spool")
        FileManager.default.createFile(atPath: spool.path, contents: nil)
        let store = LogStore(currentURL: dir.appending(path: "current.log"))
        let tailer = SpoolTailer(intervalMs: 20, store: store, stream: .out, url: spool)
        await tailer.start()
        let handle = try FileHandle(forWritingTo: spool)
        try handle.write(contentsOf: Data("plain line\n10%\r99%\rdone\n\u{1B}[32mgreen\u{1B}[0m\n".utf8))
        /** Binary junk must not break the pipeline. */
        try handle.write(contentsOf: Data([0xFF, 0xFE, 0x80] + Array("tail\n".utf8)))
        try handle.close()
        /** Lines ingest in order, so the last one landing means all did. */
        let ingested = try await eventually(within: .seconds(5), every: .milliseconds(20)) {
            await store.query(LogQueryOptions(streams: [.out])).contains { $0.text.hasSuffix("tail") }
        }
        #expect(ingested, "the tailer never ingested the last line")
        await tailer.stop()
        let records = await store.query(LogQueryOptions(streams: [.out]))
        let texts = records.map(\.text)
        #expect(texts.contains("plain line"))
        #expect(texts.contains("done"))
        #expect(texts.contains("green"))
        #expect(texts.contains { $0.hasSuffix("tail") })
    }

    @Test func assemblesALineTornAcrossReadChunks() async throws {
        let dir = try tempDir()
        let spool = dir.appending(path: "out.spool")
        try Data("hello world\nnext\n".utf8).write(to: spool)
        let store = LogStore(currentURL: dir.appending(path: "current.log"))
        let tailer = SpoolTailer(
            intervalMs: 20, readChunkBytes: 8, store: store, stream: .out, url: spool)
        await tailer.start()
        await tailer.stop()
        let texts = await store.query(LogQueryOptions(streams: [.out])).map(\.text)
        #expect(texts == ["hello world", "next"])
    }

    @Test func truncationResetsTheCursorWithoutReplaying() async throws {
        let dir = try tempDir()
        let spool = dir.appending(path: "out.spool")
        try Data("first line\n".utf8).write(to: spool)
        let store = LogStore(currentURL: dir.appending(path: "current.log"))
        let tailer = SpoolTailer(intervalMs: 20, store: store, stream: .out, url: spool)
        await tailer.start()
        await tailer.stop()
        /** Shorter than the prior offset, which is the truncation signal. */
        try Data("new\n".utf8).write(to: spool)
        await tailer.start()
        await tailer.stop()
        let texts = await store.query(LogQueryOptions(streams: [.out])).map(\.text)
        #expect(texts == ["first line", "new"])
    }

    /** A stop issued from a task that is already cancelled (a supervisor
        torn down mid-teardown) still drains what the child wrote on exit. */
    @Test func stopFromACancelledTaskStillDrains() async throws {
        let dir = try tempDir()
        let spool = dir.appending(path: "out.spool")
        try Data("last words\npartial".utf8).write(to: spool)
        let store = LogStore(currentURL: dir.appending(path: "current.log"))
        let tailer = SpoolTailer(intervalMs: 20, store: store, stream: .out, url: spool)
        let stopping = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await tailer.stop()
        }
        await stopping.value
        let texts = await store.query(LogQueryOptions(streams: [.out])).map(\.text)
        #expect(texts == ["last words", "partial"])
    }

    @Test func stopFlushesAPartialLine() async throws {
        let dir = try tempDir()
        let spool = dir.appending(path: "out.spool")
        try Data("no newline".utf8).write(to: spool)
        let store = LogStore(currentURL: dir.appending(path: "current.log"))
        let tailer = SpoolTailer(intervalMs: 20, store: store, stream: .out, url: spool)
        await tailer.start()
        await tailer.stop()
        let texts = await store.query(LogQueryOptions(streams: [.out])).map(\.text)
        #expect(texts == ["no newline"])
    }

    @Test func aBurstOfShortLinesIsIngestedInFull() async throws {
        let dir = try tempDir()
        let spool = dir.appending(path: "out.spool")
        var payload = Data()
        payload.reserveCapacity(4_000 * 12)
        for index in 0..<4_000 {
            payload.append(contentsOf: "line \(index)\n".utf8)
        }
        try payload.write(to: spool)
        let store = LogStore(currentURL: dir.appending(path: "current.log"))
        let tailer = SpoolTailer(
            intervalMs: 20, maxCatchUpBytes: 0, readChunkBytes: 64, store: store, stream: .out,
            url: spool)
        await tailer.start()
        await tailer.stop()
        let records = await store.query(LogQueryOptions(streams: [.out]))
        #expect(records.count == 4_000)
        #expect(records.first?.text == "line 0")
        #expect(records.last?.text == "line 3999")
    }

    @Test func aNewlineLessBlobIsFlushedInSegments() async throws {
        let dir = try tempDir()
        let spool = dir.appending(path: "out.spool")
        try Data(repeating: 0x61, count: 40 * 1024).write(to: spool)
        let store = LogStore(currentURL: dir.appending(path: "current.log"))
        let tailer = SpoolTailer(
            intervalMs: 20, maxCatchUpBytes: 0, store: store, stream: .out, url: spool)
        await tailer.start()
        await tailer.stop()
        let texts = await store.query(LogQueryOptions(streams: [.out])).map(\.text)
        #expect(texts.map(\.count) == [16 * 1024, 16 * 1024, 8 * 1024])
        #expect(texts.allSatisfy { $0.allSatisfy { $0 == "a" } })
    }

    @Test func catchUpSkipKeepsTheRecentTail() async throws {
        let dir = try tempDir()
        let spool = dir.appending(path: "out.spool")
        var payload = Data()
        for index in 0..<20 {
            payload.append(contentsOf: "line-\(index)\n".utf8)
        }
        try payload.write(to: spool)
        let store = LogStore(currentURL: dir.appending(path: "current.log"))
        /** 30 bytes of tail: enough for the last few lines, not the head. */
        let tailer = SpoolTailer(
            intervalMs: 20, maxCatchUpBytes: 30, store: store, stream: .out, url: spool)
        await tailer.start()
        await tailer.stop()
        let out = await store.query(LogQueryOptions(streams: [.out])).map(\.text)
        let sys = await store.query(LogQueryOptions(streams: [.sys])).map(\.text)
        #expect(out.contains("line-19"))
        #expect(!out.contains("line-0"))
        #expect(sys.contains { $0.hasPrefix("spool catch-up skipped ") })
    }

    /** A catch-up skip releases the skipped backlog before the tailer reads
        the chunk after it, so no await (the skip report, the chunk's emit)
        leaves skipped bytes holding data behind the read point. Every size
        is a whole number of the volume's blocks, so each release lands
        exactly: the skipped span less the window first, then one block per
        chunk read. */
    @Test func aCatchUpSkipReleasesTheSkippedBacklogBeforeReadingOn() async throws {
        let dir = try tempDir()
        let spool = dir.appending(path: "out.spool")
        let block = SpoolRelease.blockBytes(path: dir.path)
        let line = Data(repeating: 0x61, count: block - 1) + Data("\n".utf8)
        let backlog = 64 * block
        try Data((0..<64).flatMap { _ in line }).write(to: spool)
        let cap = 8 * block
        let retain = 2 * block
        let releases = OSAllocatedUnfairLock<[Range<UInt64>]>(initialState: [])
        let store = LogStore(currentURL: dir.appending(path: "current.log"))
        let tailer = SpoolTailer(
            intervalMs: 20, maxCatchUpBytes: cap, readChunkBytes: block,
            releaseHole: { _, range in
                releases.withLock { $0.append(range) }
                return 0
            },
            retainBytes: retain, store: store, stream: .out, url: spool)
        await tailer.start()
        await tailer.stop()
        let skippedEnd = UInt64(backlog - cap - retain)
        let perChunk = (1...(cap / block)).map { index in
            (skippedEnd + UInt64((index - 1) * block))..<(skippedEnd + UInt64(index * block))
        }
        #expect(releases.withLock { $0 } == [0..<skippedEnd] + perChunk)
    }

    /** Re-attach to a spool a prior run already wrote into (adoption's use
        case): the seed-to-end drain must ingest nothing that predates it, and
        only bytes appended after that point. */
    @Test func startAtEndIngestsOnlyBytesAppendedAfterAttach() async throws {
        let dir = try tempDir()
        let spool = dir.appending(path: "out.spool")
        try Data("preexisting line\n".utf8).write(to: spool)
        let store = LogStore(currentURL: dir.appending(path: "current.log"))
        let tailer = SpoolTailer(
            intervalMs: 20, startAtEnd: true, store: store, stream: .out, url: spool)
        await tailer.start()
        await tailer.stop()
        var texts = await store.query(LogQueryOptions(streams: [.out])).map(\.text)
        #expect(texts.isEmpty)
        let handle = try FileHandle(forWritingTo: spool)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("appended after attach\n".utf8))
        try handle.close()
        await tailer.start()
        await tailer.stop()
        texts = await store.query(LogQueryOptions(streams: [.out])).map(\.text)
        #expect(texts == ["appended after attach"])
    }

    /** The two ways a child's spool descriptor is opened: the daemon's own
        open for a direct spawn, and launchd's for an agent-mode job (read
        and write, appending, never truncating; observed on a real job). */
    static let spoolOpenFlags: [Int32] = [O_WRONLY | O_CREAT | O_TRUNC, O_RDWR | O_CREAT | O_APPEND]

    /** A flooding child writes through a descriptor the tailer can neither
        reopen nor reposition. Released blocks keep the spool's data near the
        retained window while its apparent size grows many times past it,
        every line still reaches the structured log, and the child's writes
        keep landing at the end of the file. The bound is on the bytes that
        still hold data (the SEEK_DATA walk), which is what the tailer
        controls: `st_blocks` also counts the preallocation APFS reserves
        ahead of a fast sequential writer, which no hole punch reaches and
        which the file grows into, so it swings with the volume's own
        policy rather than with anything the tailer did. Mid-flood, the data
        is the retained window plus what the tailer has not read yet, and the
        unread part is whatever the child wrote since the tailer last ran,
        which a starved cooperative pool stretches without limit, so that
        bound is measured against the tailer's own read point. */
    @Test(arguments: spoolOpenFlags)
    func aFloodingChildsSpoolStaysBoundedOnDisk(openFlags: Int32) async throws {
        let fixture = try #require(fixtureServerExecutable(), "fixture-server is not built; run swift build")
        let dir = try tempDir()
        let spool = dir.appending(path: "out.spool")
        let descriptor = open(spool.path, openFlags | O_CLOEXEC, 0o644)
        try #require(descriptor >= 0)
        let child = try spawnBare([fixture, "--flood"], stdoutFD: descriptor)
        close(descriptor)
        defer {
            kill(child, SIGKILL)
            var status: Int32 = 0
            waitpid(child, &status, 0)
        }
        let store = LogStore(currentURL: dir.appending(path: "current.log"))
        let retain = 16 * 1024
        let chunk = 64 * 1024
        let tailer = SpoolTailer(
            intervalMs: 20, maxCatchUpBytes: 256 * 1024, readChunkBytes: chunk, retainBytes: retain, store: store,
            stream: .out, url: spool)
        await tailer.start()
        let floodBytes: Int64 = 2 * 1024 * 1024
        _ = try await eventually(within: .seconds(20), every: .milliseconds(20)) {
            try spoolSizes(spool).apparent >= floodBytes
        }
        /** Measured mid-flood, while a drain never reaches end of file. The
            tailer answers between chunks, so its read point can lead its last
            release by a chunk read but not yet released, on top of the window,
            one release step, and a block of rounding; everything past the
            read point is unread, counted up to the file's size after the
            walk, since the walk sees whatever the child appends during it. */
        let ingested = await tailer.ingestedThrough
        let floodingData = try spoolDataBytes(spool)
        let flooding = try spoolSizes(spool)
        #expect(flooding.apparent >= floodBytes)
        let unread = flooding.apparent - Int64(ingested)
        let block = SpoolRelease.blockBytes(path: spool.path)
        #expect(
            floodingData <= unread + Int64(retain + retain / 4 + block + chunk),
            "data mid-flood \(floodingData) with \(unread) unread")
        kill(child, SIGSTOP)
        await tailer.stop()
        let stopped = try spoolSizes(spool)
        #expect(stopped.apparent >= floodBytes)
        /** The retained window, one release step, and a block of rounding at
            each end. */
        let stoppedData = try spoolDataBytes(spool)
        #expect(stoppedData <= Int64(retain + retain / 4 + 2 * 4096), "data after stop \(stoppedData)")

        let rawTail = try spoolTailText(spool)
        let newest = await store.query(LogQueryOptions(streams: [.out], tail: 1)).map(\.text)
        #expect(newest == [rawTail])

        kill(child, SIGCONT)
        _ = try await eventually(within: .seconds(20), every: .milliseconds(20)) {
            try spoolSizes(spool).apparent > stopped.apparent
        }
        #expect(kill(child, 0) == 0)
        #expect(try spoolSizes(spool).apparent > stopped.apparent)
        #expect(try spoolTailText(spool).hasPrefix("heartbeat"))
    }

    /** A flood that outruns the tailer is skipped chunk by chunk, but named
        in at most one sys line a second, never one per skip. */
    @Test func aFloodThatOutrunsTheTailerIsNamedAboutOnceASecond() async throws {
        let fixture = try #require(fixtureServerExecutable(), "fixture-server is not built; run swift build")
        let dir = try tempDir()
        let spool = dir.appending(path: "out.spool")
        let descriptor = open(spool.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        try #require(descriptor >= 0)
        let child = try spawnBare([fixture, "--flood"], stdoutFD: descriptor)
        close(descriptor)
        defer {
            kill(child, SIGKILL)
            var status: Int32 = 0
            waitpid(child, &status, 0)
        }
        let store = LogStore(currentURL: dir.appending(path: "current.log"))
        /** Sixteen-byte reads cannot keep up with the fixture's flood. */
        let tailer = SpoolTailer(
            intervalMs: 20, maxCatchUpBytes: 2048, readChunkBytes: 16, retainBytes: 16 * 1024, store: store,
            stream: .out, url: spool)
        let started = ContinuousClock.now
        await tailer.start()
        try await Task.sleep(for: .milliseconds(1500))
        kill(child, SIGSTOP)
        await tailer.stop()
        let elapsed = ContinuousClock.now - started
        let skips = await store.query(LogQueryOptions(streams: [.sys])).map(\.text)
            .filter { $0.hasPrefix("spool catch-up skipped ") }
        let skipped = skips.compactMap { UInt64($0.split(separator: " ")[3]) }
        #expect(skipped.count == skips.count)
        #expect(!skips.isEmpty)
        #expect(skipped.reduce(0, +) > 0)
        /** One per elapsed second, plus the first (reported at once) and the
            final flush. */
        #expect(skips.count <= Int(elapsed.components.seconds) + 2, "\(skips.count) lines in \(elapsed)")
    }

    /** Attaching to a spool a prior run filled (adoption) releases that
        backlog too, without ingesting any of it. */
    @Test func startAtEndReleasesAPriorRunsBacklog() async throws {
        let dir = try tempDir()
        let spool = dir.appending(path: "out.spool")
        try Data(String(repeating: "earlier run line\n", count: 64 * 1024).utf8).write(to: spool)
        let store = LogStore(currentURL: dir.appending(path: "current.log"))
        let tailer = SpoolTailer(
            intervalMs: 20, retainBytes: 32 * 1024, startAtEnd: true, store: store, stream: .out, url: spool)
        await tailer.start()
        await tailer.stop()
        let sizes = try spoolSizes(spool)
        #expect(sizes.apparent == 64 * 1024 * 17)
        #expect(sizes.allocated <= 32 * 1024 + 8 * 1024 + 2 * 4096, "allocated \(sizes.allocated)")
        #expect(await store.query(LogQueryOptions()).isEmpty)
    }

    /** A volume that cannot release blocks is named once in the sys stream,
        not retried every tick, and ingestion carries on. */
    @Test func aVolumeThatRefusesToReleaseIsReportedOnce() async throws {
        let dir = try tempDir()
        let spool = dir.appending(path: "out.spool")
        try Data(String(repeating: "line\n", count: 8 * 1024).utf8).write(to: spool)
        let store = LogStore(currentURL: dir.appending(path: "current.log"))
        let attempts = OSAllocatedUnfairLock<Int>(initialState: 0)
        let tailer = SpoolTailer(
            intervalMs: 20, maxCatchUpBytes: 0,
            releaseHole: { _, _ in
                attempts.withLock { $0 += 1 }
                return ENOTSUP
            },
            retainBytes: 4096, store: store, stream: .out, url: spool)
        await tailer.start()
        let handle = try FileHandle(forWritingTo: spool)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(repeating: "more\n", count: 8 * 1024).utf8))
        try handle.close()
        await tailer.stop()
        #expect(attempts.withLock { $0 } == 1)
        let sys = await store.query(LogQueryOptions(streams: [.sys])).map(\.text)
        #expect(sys == ["out.spool cannot shrink on this volume (Operation not supported), so it grows until the server restarts"])
        #expect(await store.query(LogQueryOptions(streams: [.out])).count == 16 * 1024)
    }

    private func spoolSizes(_ url: URL) throws -> (allocated: Int64, apparent: Int64) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return (Int64(info.st_blocks) * 512, Int64(info.st_size))
    }

    /** The bytes of `url` that still hold data: the sum of the extents a
        SEEK_DATA / SEEK_HOLE walk reports, so a punched range counts as
        zero whatever the volume still has allocated around it. */
    private func spoolDataBytes(_ url: URL) throws -> Int64 {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.ENOENT) }
        defer { close(descriptor) }
        var total: Int64 = 0
        var cursor: off_t = 0
        while true {
            let data = lseek(descriptor, cursor, SEEK_DATA)
            /** ENXIO: no data at or past `cursor`, the walk's normal end. */
            guard data >= 0 else {
                guard errno == ENXIO else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return total
            }
            let hole = lseek(descriptor, data, SEEK_HOLE)
            guard hole > data else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            total += Int64(hole - data)
            cursor = hole
        }
    }

    /** The newest line in the raw spool (a trailing unterminated one
        included), read from its last bytes only. */
    private func spoolTailText(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
        let bytes = try handle.readToEnd() ?? Data()
        return String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
    }

    @Test func fileHandleReadUpToCountHonorsTheLimit() throws {
        let dir = try tempDir()
        let url = dir.appending(path: "blob")
        try Data(repeating: 0x61, count: 1000).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let chunk = try handle.read(upToCount: 64)
        #expect(chunk?.count == 64)
    }
}

@Suite(.temporaryTree) struct EventStoreTests {
    @Test func postAndQueryWithFilters() async throws {
        let store = EventStore(url: try tempDir().appending(path: "events.log"))
        await store.post(kind: .started, project: "/a", server: "web", detail: "pid 1")
        await store.post(kind: .crashed, project: "/a", server: "web", detail: "code=1")
        await store.post(kind: .started, project: "/b", server: "api")
        let all = await store.query()
        #expect(all.count == 3)
        let projectA = await store.query(project: "/a")
        #expect(projectA.map(\.kind) == [.started, .crashed])
        let tail = await store.query(tail: 1)
        #expect(tail.first?.server == "api")
    }

    @Test func aForcedRotateKeepsTheNewestAndTheRotatedFile() async throws {
        let url = try tempDir().appending(path: "events.log")
        let store = EventStore(url: url, maxBytes: 4_096)
        for index in 0..<80 {
            await store.post(
                kind: .started, project: "/p", server: "web-\(index)",
                detail: String(repeating: "x", count: 80))
        }
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
        let all = await store.query()
        #expect(!all.isEmpty)
        #expect(all.last?.server == "web-79")
    }

    @Test func aCapSizedFamilyStillAnswersSinceAndTail() async throws {
        /** Pre-written NDJSON, not 5 MB of actor posts: the query path reads
            both files whole, then tails, which is the same shape as a days-old
            events.log at the 5 MB rotate cap. */
        let dir = try tempDir()
        let current = dir.appending(path: "events.log")
        func event(_ offset: Int, project: String) throws -> Data {
            try NDJSON.encodeLine(
                EventRecord(
                    at: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset)),
                    kind: offset % 3 == 0 ? .crashed : .started,
                    project: project, server: "web"))
        }
        var rotated = Data()
        rotated.reserveCapacity(8_000 * 120)
        for index in 0..<8_000 {
            rotated.append(try event(index, project: index < 100 ? "/other" : "/p"))
        }
        var live = Data()
        live.reserveCapacity(500 * 120)
        for index in 8_000..<8_500 {
            live.append(try event(index, project: "/p"))
        }
        try rotated.write(to: current.appendingPathExtension("1"))
        try live.write(to: current)
        let store = EventStore(url: current)
        let started = ContinuousClock.now
        let tail = await store.query(tail: 3)
        #expect(tail.map(\.at) == [
            Date(timeIntervalSince1970: 1_700_000_000 + 8_497),
            Date(timeIntervalSince1970: 1_700_000_000 + 8_498),
            Date(timeIntervalSince1970: 1_700_000_000 + 8_499),
        ])
        let window = await store.query(since: Date(timeIntervalSince1970: 1_700_000_000 + 8_400))
        #expect(window.count == 100)
        let other = await store.query(project: "/other")
        #expect(other.count == 100)
        #expect(ContinuousClock.now - started < Duration.seconds(2))
    }
}

@Suite(.temporaryTree) struct WhyEngineTests {
    private func status(_ name: String, _ phase: ServerPhase, exit: Int? = nil) -> ServerStatus {
        ServerStatus(
            lastExit: exit.map { LastExit(at: Date(timeIntervalSince1970: 1_700_000_000), code: $0) },
            logPath: "/logs/\(name)/current.log",
            phase: phase,
            project: "/p",
            server: name
        )
    }

    @Test func dependencyWalkFindsDeepRootCause() {
        let statuses = [
            "web": status("web", .unhealthy),
            "api": status("api", .crashed, exit: 1),
        ]
        let specs = [
            "web": ServerSpec(command: ["w"], dependsOn: ["api"], name: "web"),
            "api": ServerSpec(command: ["a"], name: "api"),
        ]
        /** The caller supplies already stream-tagged lines (production passes
            LogRecord.contextLine), so the engine appends them verbatim rather
            than owning the prefix. */
        let result = WhyEngine.diagnose(
            target: "web", statuses: statuses, specs: specs,
            evidenceLines: { name in name == "api" ? ["err: ECONNREFUSED db:5432"] : [] })
        #expect(result.rootCause?.hasPrefix("api: crashed (exit 1)") == true)
        #expect(result.findings.count == 2)
        #expect(result.findings.first?.server == "web")
        let apiFinding = result.findings.first { $0.server == "api" }
        #expect(apiFinding?.evidence.contains("err: ECONNREFUSED db:5432") == true)
    }

    @Test func healthyTargetHasNoRootCause() {
        let result = WhyEngine.diagnose(
            target: "web",
            statuses: ["web": status("web", .running)],
            specs: ["web": ServerSpec(command: ["w"], name: "web")],
            evidenceLines: { _ in [] })
        #expect(result.rootCause == nil)
        #expect(result.findings.first?.summary == "running and healthy")
    }

    @Test func portMismatchIsSurfaced() {
        var mismatched = status("web", .running)
        mismatched.declaredPort = 3000
        mismatched.observedPort = 3001
        let result = WhyEngine.diagnose(
            target: "web",
            statuses: ["web": mismatched],
            specs: ["web": ServerSpec(command: ["w"], name: "web", port: 3000)],
            evidenceLines: { _ in [] })
        #expect(result.findings.first?.summary.contains("listening on 3001") == true)
    }

    @Test func crashedExit0SurfacesStdoutEvidence() {
        var crashed = status("web", .crashed, exit: 0)
        crashed.recentLogTail = ["[out] Another vinext REFUSAL-TOKEN already running"]
        let result = WhyEngine.diagnose(
            target: "web",
            statuses: ["web": crashed],
            specs: ["web": ServerSpec(command: ["true"], name: "web")],
            evidenceLines: { _ in [] })
        let finding = result.findings.first
        #expect(finding?.summary.contains("exit 0") == true)
        #expect(finding?.summary.contains("controlled refusal") == true)
        #expect(finding?.evidence.contains(where: { $0.contains("REFUSAL-TOKEN") }) == true)
    }

    @Test func stoppedWithNoEventHistoryStaysABareNotRunning() {
        let stopped = status("web", .stopped, exit: 0)
        let result = WhyEngine.diagnose(
            target: "web",
            statuses: ["web": stopped],
            specs: ["web": ServerSpec(command: ["w"], name: "web")],
            evidenceLines: { _ in [] })
        #expect(result.findings.first?.summary == "not running (stopped)")
    }

    @Test func ordinaryDirectaStopStaysABareNotRunning() {
        var stopped = status("web", .stopped, exit: 0)
        stopped.lastExit = LastExit(
            at: Date(timeIntervalSince1970: 1_700_000_000), signal: 15)
        let result = WhyEngine.diagnose(
            target: "web",
            statuses: ["web": stopped],
            specs: ["web": ServerSpec(command: ["w"], name: "web")],
            evidenceLines: { _ in [] },
            lastStopDetail: { $0 == "web" ? "requested by stop" : nil })
        #expect(result.findings.first?.summary == "not running (stopped)")
    }

    @Test func externallySignaledStopNamesTheSignalAndThatItWasExternal() {
        var stopped = status("web", .stopped, exit: 0)
        stopped.lastExit = LastExit(
            at: Date(timeIntervalSince1970: 1_700_000_000), signal: 15)
        let result = WhyEngine.diagnose(
            target: "web",
            statuses: ["web": stopped],
            specs: ["web": ServerSpec(command: ["w"], name: "web")],
            evidenceLines: { _ in [] },
            lastStopDetail: { $0 == "web" ? "signal=15 (external)" : nil })
        #expect(
            result.findings.first?.summary
                == "not running (stopped by signal 15 sent from outside directa)")
    }

    /** A watch-change detail names an arbitrary project file path, which can
        legitimately contain the literal substring "(external)" as a
        directory or file name. The anchored `ExternalSignalDetail.matches`
        must not read that as the external-signal marker, so the summary
        stays the bare "stopped" a directa-requested stop gets. */
    @Test func aWatchChangeDetailContainingTheSubstringIsNotMisreadAsExternal() {
        var stopped = status("web", .stopped, exit: 0)
        stopped.lastExit = LastExit(
            at: Date(timeIntervalSince1970: 1_700_000_000), signal: 15)
        let result = WhyEngine.diagnose(
            target: "web",
            statuses: ["web": stopped],
            specs: ["web": ServerSpec(command: ["w"], name: "web")],
            evidenceLines: { _ in [] },
            lastStopDetail: { $0 == "web" ? "watch change in configs/(external)/app.json" : nil })
        #expect(result.findings.first?.summary == "not running (stopped)")
    }

    @Test func prefersTerminalEvidenceWhenTailCleared() {
        var crashed = status("web", .crashed, exit: 0)
        crashed.terminalEvidence = ["[out] persisted REFUSAL-TOKEN"]
        let result = WhyEngine.diagnose(
            target: "web",
            statuses: ["web": crashed],
            specs: ["web": ServerSpec(command: ["true"], name: "web")],
            evidenceLines: { _ in ["[err] should-not-win"] })
        let finding = result.findings.first
        #expect(finding?.evidence.contains(where: { $0.contains("persisted REFUSAL-TOKEN") }) == true)
        #expect(finding?.evidence.contains(where: { $0.contains("should-not-win") }) != true)
    }
}
