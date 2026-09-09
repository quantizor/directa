import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "directa-pipe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct LogStoreTests {
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

@Suite struct SpoolLineSplitTests {
    @Test func splitsLinesAndKeepsIncompleteTail() {
        let pulled = SpoolLineSplit.pull(
            from: Data("one\ntwo\nthree".utf8), maxPartialBytes: 16 * 1024)
        #expect(pulled.lines.map { String(decoding: $0, as: UTF8.self) } == ["one", "two"])
        #expect(String(decoding: pulled.remainder, as: UTF8.self) == "three")
    }

    @Test func skipsEmptyLines() {
        let pulled = SpoolLineSplit.pull(from: Data("a\n\nb\n".utf8), maxPartialBytes: 16)
        #expect(pulled.lines.map { String(decoding: $0, as: UTF8.self) } == ["a", "b"])
        #expect(pulled.remainder.isEmpty)
    }

    @Test func segmentsANewlineLessTailPastTheCap() {
        let pulled = SpoolLineSplit.pull(
            from: Data(repeating: 0x61, count: 10), maxPartialBytes: 4)
        #expect(pulled.lines.map(\.count) == [4, 4])
        #expect(pulled.remainder.count == 2)
        #expect(pulled.remainder == Data(repeating: 0x61, count: 2))
    }

    @Test func aTailAtTheCapStaysUnflushed() {
        let pulled = SpoolLineSplit.pull(
            from: Data(repeating: 0x61, count: 4), maxPartialBytes: 4)
        #expect(pulled.lines.isEmpty)
        #expect(pulled.remainder.count == 4)
    }

    @Test func pullDoesNotCopyTheUnreadTailOncePerLine() {
        /** 50k short lines is enough that a per-line `removeSubrange` from the
            front of `Data` spends seconds memmoving the remainder; an index
            walk finishes immediately. */
        var buffer = Data()
        buffer.reserveCapacity(50_000 * 8)
        for index in 0..<50_000 {
            buffer.append(contentsOf: "l\(index)\n".utf8)
        }
        let started = ContinuousClock.now
        let pulled = SpoolLineSplit.pull(from: buffer, maxPartialBytes: 16 * 1024)
        let elapsed = ContinuousClock.now - started
        #expect(pulled.lines.count == 50_000)
        #expect(String(decoding: pulled.lines[0], as: UTF8.self) == "l0")
        #expect(String(decoding: pulled.lines[49_999], as: UTF8.self) == "l49999")
        #expect(pulled.remainder.isEmpty)
        #expect(elapsed < Duration.seconds(1))
    }
}

@Suite struct SpoolTailerTests {
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
        try await Task.sleep(for: .milliseconds(200))
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

@Suite struct EventStoreTests {
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

@Suite struct WhyEngineTests {
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
