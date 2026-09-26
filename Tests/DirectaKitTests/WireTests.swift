import Darwin
import Foundation
import Testing

@testable import DirectaKit

@Suite struct WireCodecTests {
    @Test func requestRoundTrip() throws {
        let request = WireRequest(
            id: "c1", method: WireMethod.serverStart.rawValue,
            params: ServerTargetParams(name: "web", project: "/tmp/proj"))
        let line = try NDJSON.encodeLine(request)
        #expect(line.last == 0x0A)
        let decoded = try JSONCoding.decoder().decode(
            WireRequest<ServerTargetParams>.self, from: line.dropLast())
        #expect(decoded.id == "c1")
        #expect(decoded.params == request.params)
    }

    @Test func responseErrorEnvelope() throws {
        let response = WireResponse<WireEmpty>(
            error: WireError(code: .notFound, hint: "run: directa status --json", message: "nope"),
            id: "c2", ok: false)
        let line = try NDJSON.encodeLine(response)
        let head = try JSONCoding.decoder().decode(WireResponseHead.self, from: line.dropLast())
        #expect(head.ok == false)
        #expect(head.error?.code == .notFound)
        #expect(head.error?.hint == "run: directa status --json")
    }

    @Test func iso8601MillisecondRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_752_868_000.123)
        let text = JSONCoding.formatISO8601(date)
        #expect(text.hasSuffix("Z"))
        #expect(text.contains("."))
        let parsed = JSONCoding.parseISO8601(text)
        #expect(parsed != nil)
        #expect(abs(parsed!.timeIntervalSince(date)) < 0.001)
    }

    /** The formatter builds its fractional digits from a millisecond integer.
        Flooring that division, rather than Swift's default `/` and `%`
        truncation toward zero, keeps a pre-epoch date's negative remainder
        from rendering as `.-500Z`, which the formatter's own parser rejects;
        a timestamp that will not parse is a log line that cannot be queried.
        Nothing in directa formats a pre-1970 date today, so this pins a property
        of the formatter rather than a live path. */
    @Test(arguments: [-0.5, -1.25, -1_000_000.001, -0.999])
    func aDateBeforeTheEpochStillRoundTrips(seconds: Double) throws {
        let date = Date(timeIntervalSince1970: seconds)
        let text = JSONCoding.formatISO8601(date)
        #expect(!text.contains(".-"))
        let parsed = try #require(JSONCoding.parseISO8601(text))
        #expect(abs(parsed.timeIntervalSince(date)) < 0.001)
    }

    @Test func ndjsonBufferSplitsFrames() {
        var buffer = NDJSONBuffer()
        let first = buffer.feed(Data("{\"a\":1}\n{\"b\":".utf8))
        #expect(first.count == 1)
        let second = buffer.feed(Data("2}\n".utf8))
        #expect(second.count == 1)
        #expect(String(data: second[0], encoding: .utf8) == "{\"b\":2}")
    }

    /** A single very long line (an unbounded `directa logs` response) fed in
        fixed-size chunks comes out as exactly one identical line. `NDJSONBuffer`
        tracks how far it has already scanned for a newline (`scanned`) so each
        chunk resumes from there instead of rescanning the whole buffer; feeding
        several thousand chunks here pins correctness across that many `feed`
        calls without asserting on timing. */
    @Test func ndjsonBufferFramesAMultiMegabyteLineSplitAcrossManyChunks() {
        var buffer = NDJSONBuffer()
        let payload = Data(repeating: UInt8(ascii: "x"), count: 2_000_000)
        var line = payload
        line.append(0x0A)
        var framed: [Data] = []
        var offset = line.startIndex
        let chunkSize = 8192
        while offset < line.endIndex {
            let end = line.index(offset, offsetBy: chunkSize, limitedBy: line.endIndex) ?? line.endIndex
            framed.append(contentsOf: buffer.feed(line[offset..<end]))
            offset = end
        }
        #expect(framed.count == 1)
        #expect(framed[0] == payload)
    }

    /** Several complete lines delivered in one chunk all come back from the
        same `feed` call, in order. */
    @Test func ndjsonBufferFramesSeveralLinesInOneChunk() {
        var buffer = NDJSONBuffer()
        let lines = buffer.feed(Data("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n".utf8))
        #expect(lines.map { String(data: $0, encoding: .utf8) } == ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"])
    }

    /** A chunk boundary that lands exactly on the newline byte: the first
        `feed` call ends with `\n` and nothing else, the second starts a fresh
        line with no leftover partial data from the first. */
    @Test func ndjsonBufferHandlesAChunkBoundaryOnTheNewlineByte() {
        var buffer = NDJSONBuffer()
        let first = buffer.feed(Data("{\"a\":1}\n".utf8))
        #expect(first.map { String(data: $0, encoding: .utf8) } == ["{\"a\":1}"])
        let second = buffer.feed(Data("{\"b\":2}\n".utf8))
        #expect(second.map { String(data: $0, encoding: .utf8) } == ["{\"b\":2}"])
    }

    /** Empty lines (a bare `\n`) are dropped rather than surfaced as
        zero-length frames. */
    @Test func ndjsonBufferSkipsEmptyLines() {
        var buffer = NDJSONBuffer()
        let lines = buffer.feed(Data("\n\n{\"a\":1}\n\n".utf8))
        #expect(lines.map { String(data: $0, encoding: .utf8) } == ["{\"a\":1}"])
    }

    /** A trailing partial line with no newline yet returns nothing and stays
        buffered until the newline arrives on a later `feed`. A third feed with
        two more lines, one of them starting well within the byte count the
        earlier partial line advanced the internal scan position by, catches a
        buffer that forgets to reset that position once a line drains: a stale
        position past a later chunk's first newline would skip it and merge two
        lines into one. */
    @Test func ndjsonBufferRetainsAPartialTailAcrossFeeds() {
        var buffer = NDJSONBuffer()
        let first = buffer.feed(Data("{\"a\":1".utf8))
        #expect(first.isEmpty)
        let second = buffer.feed(Data("}\n{\"b\":2}\n".utf8))
        #expect(second.map { String(data: $0, encoding: .utf8) } == ["{\"a\":1}", "{\"b\":2}"])
        let third = buffer.feed(Data("{}\n123\n".utf8))
        #expect(third.map { String(data: $0, encoding: .utf8) } == ["{}", "123"])
    }

    @Test func statusSchemaGolden() throws {
        let status = ServerStatus(
            declaredPort: 3000,
            healthcheck: .none,
            lastExit: LastExit(at: Date(timeIntervalSince1970: 1_752_868_000), code: 1),
            logPath: "/logs/web/current.log",
            phase: .crashed,
            project: "/tmp/proj",
            server: "web"
        )
        let json = String(data: try JSONCoding.encoder().encode(status), encoding: .utf8)!
        /** Sorted keys make this deterministic; the golden string is the contract.
            A nil errorSummary is omitted, so this shape is unchanged by the field. */
        #expect(
            json
                == #"{"declaredPort":3000,"healthcheck":"none","lastExit":{"at":"2025-07-18T19:46:40.000Z","code":1},"logPath":"/logs/web/current.log","phase":"crashed","project":"/tmp/proj","server":"web"}"#
        )
    }

    @Test func aMachineWideStatusListIsOneNDJSONLine() throws {
        /** `status --all` of a 24-server monorepo is one JSON array on one
            line. Interior newlines would break NDJSON framing; a failed
            round-trip would mean the client timed out on a frame it could not
            parse. */
        let servers = (0..<24).map { index in
            ServerStatus(
                declaredPort: 3000 + index,
                healthcheck: .tcp,
                logPath: "/logs/s\(index)/current.log",
                phase: .running,
                project: "/p",
                server: "s\(String(format: "%02d", index))",
                url: "http://p.localhost:\(3000 + index)/")
        }
        let line = try NDJSON.encodeLine(ServerListResult(servers: servers, trusted: true))
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        let decoded = try JSONCoding.decoder().decode(
            ServerListResult.self, from: line.dropLast())
        #expect(decoded.servers.count == 24)
        #expect(decoded.servers.first?.server == "s00")
        #expect(decoded.servers.last?.server == "s23")
        #expect(decoded.trusted == true)
    }

    @Test func errorSummarySchemaGolden() throws {
        let status = ServerStatus(
            declaredPort: 3000,
            errorSummary: ErrorSummary(
                count: 3,
                firstAt: Date(timeIntervalSince1970: 1_752_868_000),
                lastAt: Date(timeIntervalSince1970: 1_752_868_004)),
            healthcheck: .none,
            logPath: "/logs/web/current.log",
            phase: .crashed,
            project: "/tmp/proj",
            server: "web"
        )
        let json = String(data: try JSONCoding.encoder().encode(status), encoding: .utf8)!
        #expect(
            json
                == #"{"declaredPort":3000,"errorSummary":{"count":3,"firstAt":"2025-07-18T19:46:40.000Z","lastAt":"2025-07-18T19:46:44.000Z"},"healthcheck":"none","logPath":"/logs/web/current.log","phase":"crashed","project":"/tmp/proj","server":"web"}"#
        )
    }

    /** The worktree display fields are a contract like any other: their key
        names and sort positions are pinned here, and their absence (a main
        checkout) is the golden above, which omits both. */
    @Test func statusSchemaGoldenWithAWorktreeLabel() throws {
        let status = ServerStatus(
            declaredPort: 3000,
            healthcheck: .none,
            logPath: "/logs/web/current.log",
            mainProject: "myproj",
            phase: .running,
            project: "/tmp/proj",
            server: "web",
            url: "http://proj.localhost:3000/",
            worktree: "review"
        )
        let json = String(data: try JSONCoding.encoder().encode(status), encoding: .utf8)!
        #expect(
            json
                == #"{"declaredPort":3000,"healthcheck":"none","logPath":"/logs/web/current.log","mainProject":"myproj","phase":"running","project":"/tmp/proj","server":"web","url":"http://proj.localhost:3000/","worktree":"review"}"#
        )
    }

    /** `daemon.info` is what every other command's hint points at, so its shape
        is a contract like any other and had no golden until it grew a field. A
        serving daemon encodes exactly what it always did: `restoring` is omitted
        rather than false, which is the compatibility claim. */
    @Test func daemonInfoSchemaGoldenOmitsRestoringWhenServing() throws {
        let info = DaemonInfo(
            dataDir: "/data", daemonVersion: "1.4.0", logsDir: "/logs", pid: 42, proto: 1,
            socketPath: "/data/daemon.sock")
        let json = String(data: try JSONCoding.encoder().encode(info), encoding: .utf8)!
        #expect(
            json
                == #"{"daemonVersion":"1.4.0","dataDir":"/data","logsDir":"/logs","pid":42,"proto":1,"socketPath":"/data/daemon.sock"}"#
        )
    }

    /** The one shape a client branches on to tell a daemon that is coming back
        from one that is gone. */
    @Test func daemonInfoSchemaGoldenWhileRestoring() throws {
        let info = DaemonInfo(
            dataDir: "/data", daemonVersion: "1.4.0", logsDir: "/logs", pid: 42, proto: 1,
            restoring: true, socketPath: "/data/daemon.sock")
        let json = String(data: try JSONCoding.encoder().encode(info), encoding: .utf8)!
        #expect(
            json
                == #"{"daemonVersion":"1.4.0","dataDir":"/data","logsDir":"/logs","pid":42,"proto":1,"restoring":true,"socketPath":"/data/daemon.sock"}"#
        )
    }

    /** `claimedProjects` is append-only like `restoring`: present only once a
        caller sets it, so `directa doctor` can tell a daemon that never
        claims anything (an empty array) apart from one built before the field
        existed (absent, and the orphan-log-dir finding must skip rather than
        guess). */
    @Test func daemonInfoSchemaGoldenWithClaimedProjects() throws {
        let info = DaemonInfo(
            claimedProjects: ["/p/api", "/p/web"], dataDir: "/data", daemonVersion: "1.4.0",
            logsDir: "/logs", pid: 42, proto: 1, socketPath: "/data/daemon.sock")
        let json = String(data: try JSONCoding.encoder().encode(info), encoding: .utf8)!
        #expect(
            json
                == #"{"claimedProjects":["/p/api","/p/web"],"daemonVersion":"1.4.0","dataDir":"/data","logsDir":"/logs","pid":42,"proto":1,"socketPath":"/data/daemon.sock"}"#
        )
    }

    /** A main checkout answers exactly as it did before the effective-host
        fields existed: they are omitted when nil, which is the compatibility
        claim, asserted rather than assumed. */
    @Test func checkResultSchemaGoldenIsUnchangedWithoutAnEffectiveHost() throws {
        let result = CheckResult(
            errors: [], host: "app.localhost", servers: ["api", "web"], warnings: [])
        let json = String(data: try JSONCoding.encoder().encode(result), encoding: .utf8)!
        #expect(
            json
                == #"{"errors":[],"host":"app.localhost","servers":["api","web"],"warnings":[]}"#
        )
    }

    @Test func checkResultSchemaGoldenWithAnOverlayHostAndAWorktreeLabel() throws {
        let result = CheckResult(
            effectiveHost: "pinned.localhost",
            effectiveHostReason: .localOverlay,
            errors: [],
            host: "app.localhost",
            serverHosts: [
                EffectiveHost(
                    declared: "app.localhost", effective: "pinned.localhost",
                    reason: .localOverlay, server: "api")
            ],
            servers: ["api", "web"],
            warnings: [],
            worktree: "review")
        let json = String(data: try JSONCoding.encoder().encode(result), encoding: .utf8)!
        #expect(
            json
                == #"{"effectiveHost":"pinned.localhost","effectiveHostReason":"local-overlay","errors":[],"host":"app.localhost","serverHosts":[{"declared":"app.localhost","effective":"pinned.localhost","reason":"local-overlay","server":"api"}],"servers":["api","web"],"warnings":[],"worktree":"review"}"#
        )
    }

    /** `project.forget`'s result names the servers it dropped along with the
        row, trust, and log directory: `doctor --fix` reports the count in its
        finding without a second query. */
    @Test func projectForgetResultSchemaGolden() throws {
        let result = ProjectForgetResult(servers: ["api", "web"])
        let json = String(data: try JSONCoding.encoder().encode(result), encoding: .utf8)!
        #expect(json == #"{"servers":["api","web"]}"#)
    }

    /** Append-only is a wire promise: a reason the current daemon never
        produces (the worktree label host was removed) must still decode, so an
        older daemon on the socket does not break a newer CLI. */
    @Test func legacyWorktreeReasonStillDecodes() throws {
        let json =
            #"{"effectiveHost":"worktree-review.app.localhost","effectiveHostReason":"linked-worktree","errors":[],"host":"app.localhost","servers":["web"],"warnings":[]}"#
        let result = try JSONCoding.decoder().decode(CheckResult.self, from: Data(json.utf8))
        #expect(result.effectiveHost == "worktree-review.app.localhost")
        #expect(result.effectiveHostReason == .linkedWorktree)
    }

    /** An events response from a daemon newer than this build can carry a kind
        this build predates. Decoding must not fail the whole response over one
        unrecognized string, the rest of the events must stay intact, and the
        unrecognized kind must round-trip byte-identical (a client that only
        relays events, rather than interpreting them, must never mutate data it
        does not understand). */
    @Test func unknownEventKindDecodesAndRoundTripsWithTheRestOfTheEvents() throws {
        let json =
            #"{"events":[{"at":"2025-07-18T19:46:40.000Z","kind":"started","project":"/tmp/proj","server":"web"},{"at":"2025-07-18T19:46:40.000Z","kind":"rebalanced","project":"/tmp/proj","server":"web"}]}"#
        let result = try JSONCoding.decoder().decode(EventsQueryResult.self, from: Data(json.utf8))
        #expect(result.events.count == 2)
        #expect(result.events[0].kind == .started)
        #expect(result.events[1].kind == .unknown("rebalanced"))
        let reencoded = String(data: try JSONCoding.encoder().encode(result), encoding: .utf8)
        #expect(reencoded == json)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        try #require(String(data: JSONCoding.encoder().encode(value), encoding: .utf8))
    }

    private let logAt = Date(timeIntervalSince1970: 1_752_868_000)

    /** `LogStream` is not `CodingKeyRepresentable`, so a `[LogStream: Int]`
        would encode as an alternating array; both count types are structs so
        they encode as objects. */
    @Test func logCursorAndStreamCountsEncodeAsObjects() throws {
        #expect(try encoded(LogCursor(at: logAt, count: 3)) == #"{"at":"2025-07-18T19:46:40.000Z","count":3}"#)
        #expect(
            try encoded(LogStreamCounts(err: 1, mark: 0, out: 20, sys: 4))
                == #"{"err":1,"mark":0,"out":20,"sys":4}"#)
        #expect(try encoded(LogStreamCounts(out: 300)) == #"{"out":300}"#)
        #expect(try encoded(LogCursor.origin) == #"{"at":"1970-01-01T00:00:00.000Z","count":0}"#)
        #expect(
            try encoded(LogCursor(at: logAt, count: 30_000, position: LogFilePosition(file: 1_234_567, offset: 2_097_151)))
                == #"{"at":"2025-07-18T19:46:40.000Z","count":30000,"position":{"file":1234567,"offset":2097151}}"#)
    }

    /** A cursor from a daemon that predates positions decodes with none,
        and one carrying a position decodes it whole. */
    @Test func logCursorsDecodeWithAndWithoutAPosition() throws {
        let plain = #"{"at":"2025-07-18T19:46:40.000Z","count":3}"#
        #expect(try JSONCoding.decoder().decode(LogCursor.self, from: Data(plain.utf8)) == LogCursor(at: logAt, count: 3))
        let positioned = #"{"at":"2025-07-18T19:46:40.000Z","count":3,"position":{"file":9,"offset":120}}"#
        #expect(
            try JSONCoding.decoder().decode(LogCursor.self, from: Data(positioned.utf8))
                == LogCursor(at: logAt, count: 3, position: LogFilePosition(file: 9, offset: 120)))
    }

    @Test func logsQueryParamsSchemaGolden() throws {
        let params = LogsQueryParams(
            after: LogCursor(at: logAt, count: 2), maxLineCharacters: 400, name: "web", project: "/tmp/proj",
            streams: [.out, .sys], tailByStream: LogStreamCounts(err: 300, mark: 50, out: 300, sys: 50))
        #expect(
            try encoded(params)
                == #"{"after":{"at":"2025-07-18T19:46:40.000Z","count":2},"maxLineCharacters":400,"name":"web","project":"/tmp/proj","streams":["out","sys"],"tailByStream":{"err":300,"mark":50,"out":300,"sys":50}}"#
        )
        #expect(
            try encoded(LogsQueryParams(head: 200, name: "web", project: "/tmp/proj"))
                == #"{"head":200,"name":"web","project":"/tmp/proj"}"#)
    }

    @Test func logsQueryResultSchemaGolden() throws {
        let result = LogsQueryResult(
            cursor: LogCursor(at: logAt, count: 1), lines: [LogRecord(at: logAt, stream: .out, text: "ready")],
            totals: LogStreamCounts(err: 0, mark: 0, out: 1, sys: 0))
        #expect(
            try encoded(result)
                == #"{"cursor":{"at":"2025-07-18T19:46:40.000Z","count":1},"lines":[{"at":"2025-07-18T19:46:40.000Z","stream":"out","text":"ready"}],"totals":{"err":0,"mark":0,"out":1,"sys":0}}"#
        )
    }

    /** Append-only both ways: an older client's params decode with every new
        field absent, and an older daemon's result (no cursor, no totals)
        decodes too, which is how a newer CLI tells it needs a restart. */
    @Test func olderLogsFramesStillDecode() throws {
        let oldParams = #"{"name":"web","project":"/tmp/proj","since":"2025-07-18T19:46:40.000Z","tail":5}"#
        let params = try JSONCoding.decoder().decode(LogsQueryParams.self, from: Data(oldParams.utf8))
        #expect(params == LogsQueryParams(name: "web", project: "/tmp/proj", since: logAt, tail: 5))
        #expect(params.refusal() == nil)
        let oldResult = #"{"lines":[]}"#
        let result = try JSONCoding.decoder().decode(LogsQueryResult.self, from: Data(oldResult.utf8))
        #expect(result == LogsQueryResult(lines: []))
        #expect(result.cursor == nil)
    }

    @Test func logsQueryParamsRefuseEachExclusivePair() {
        let cursor = LogCursor(at: logAt, count: 0)
        let byStream = LogStreamCounts(out: 10)
        let refused: [(LogsQueryParams, String)] = [
            (LogsQueryParams(after: cursor, name: "web", project: "/p", since: logAt), "after with since"),
            (LogsQueryParams(after: cursor, name: "web", project: "/p", sinceMark: "m1"), "after with sinceMark"),
            (LogsQueryParams(name: "web", project: "/p", tail: 5, tailByStream: byStream), "tail with tailByStream"),
            (LogsQueryParams(head: 5, name: "web", project: "/p", tail: 5), "head with tail"),
            (LogsQueryParams(head: 5, name: "web", project: "/p", tailByStream: byStream), "head with tailByStream"),
        ]
        for (params, label) in refused {
            #expect(params.refusal()?.code == .usage, "\(label)")
            #expect(params.refusal()?.hint != nil, "\(label)")
        }
        #expect(
            LogsQueryParams(after: cursor, head: 5, name: "web", project: "/p").refusal() == nil)
        #expect(
            LogsQueryParams(name: "web", project: "/p", since: logAt, sinceMark: "m1", tail: 5).refusal() == nil)
    }

    @Test func logsQueryParamsRefuseNegativeCountsAndAnEmptyLineBudget() {
        let refused: [(LogsQueryParams, String)] = [
            (LogsQueryParams(after: LogCursor(at: logAt, count: -1), name: "w", project: "/p"), "after.count"),
            (LogsQueryParams(head: -1, name: "w", project: "/p"), "head"),
            (LogsQueryParams(name: "w", project: "/p", tail: -1), "tail"),
            (LogsQueryParams(name: "w", project: "/p", tailByStream: LogStreamCounts(sys: -3)), "tailByStream.sys"),
        ]
        for (params, field) in refused {
            let refusal = params.refusal()
            #expect(refusal?.code == .usage, "\(field)")
            #expect(refusal?.message.hasPrefix("\(field) is ") == true, "\(field)")
        }
        #expect(LogsQueryParams(maxLineCharacters: 0, name: "w", project: "/p").refusal()?.code == .usage)
        #expect(LogsQueryParams(maxLineCharacters: 1, name: "w", project: "/p").refusal() == nil)
        #expect(
            LogsQueryParams(
                name: "w", project: "/p", tailByStream: LogStreamCounts(err: 0, mark: 0, out: Int.max, sys: 0)
            ).refusal() == nil)
    }
}

@Suite struct PathTests {
    @Test func sunPathLimit() {
        #expect(DirectaPaths.fitsSunPath("/tmp/short.sock"))
        #expect(!DirectaPaths.fitsSunPath(String(repeating: "x", count: 104)))
    }

    /** The client and the daemon must refuse an over-long `DIRECTA_SOCKET` with
        the exact same text, since that is the one place either side names the
        cause: the client raises it before `connect(2)`, and the daemon raises
        it before taking the single-instance lock. */
    @Test func sunPathLimitMessageNamesTheOffendingPath() {
        #expect(
            DirectaPaths.sunPathLimitMessage("/tmp/too-long.sock")
                == "socket path exceeds sun_path limit: /tmp/too-long.sock")
    }

    @Test func serverIDShape() {
        #expect(serverID(project: "/a/b", name: "web") == "/a/b::web")
        #expect(parseServerID("/a/b::web")?.project == "/a/b")
        #expect(parseServerID("/a/b::web")?.name == "web")
        /** Last `::` wins, so a project path carrying the separator still
            round-trips. Front-split would call the project `/a` and the name
            `b::web`. */
        #expect(parseServerID("/a::b::web")?.project == "/a::b")
        #expect(parseServerID("/a::b::web")?.name == "web")
        #expect(parseServerID("no-separator") == nil)
    }

    /** The menu bar logs and displays failures through `localizedDescription`,
        and a bare Error struct renders there as "The operation couldn't be
        completed. (DirectaKit.WireError error 1.)". That is what a real failed
        agent register showed: nothing wrong, nowhere, nothing to do, while the
        message and its remediation command sat unread on the value. */
    @Test func wireErrorReadsAsItsOwnMessageAndHint() {
        let withHint = WireError(
            code: .daemonUnreachable, hint: "run: directa daemon start",
            message: "ddirecta is not listening")
        #expect(withHint.localizedDescription == "ddirecta is not listening (run: directa daemon start)")

        let withoutHint = WireError(code: .internalError, message: "ddirecta never answered")
        #expect(withoutHint.localizedDescription == "ddirecta never answered")

        /** The regression guard: the Foundation default must not come back. */
        #expect(withHint.localizedDescription.contains("couldn't be completed") == false)
    }

    @Test func hash8Stable() {
        #expect(DirectaPaths.hash8("/Users/x/code/proj") == DirectaPaths.hash8("/Users/x/code/proj"))
        #expect(DirectaPaths.hash8("/a") != DirectaPaths.hash8("/b"))
        #expect(DirectaPaths.hash8("/a").count == 8)
    }

    @Test func userLibraryResidueCoversCachesPrefsAndSavedState() {
        let paths = DirectaPaths.userLibraryResidue(home: URL(fileURLWithPath: "/Users/x")).map(\.path)
        #expect(paths.contains("/Users/x/Library/Caches/dev.quantizor.directa.app"))
        #expect(paths.contains("/Users/x/Library/Caches/dev.quantizor.ddirecta"))
        #expect(paths.contains("/Users/x/Library/Caches/ddirecta"))
        #expect(paths.contains("/Users/x/Library/HTTPStorages/dev.quantizor.ddirecta"))
        #expect(paths.contains("/Users/x/Library/HTTPStorages/ddirecta"))
        #expect(paths.contains("/Users/x/Library/Preferences/dev.quantizor.directa.app.plist"))
        #expect(
            paths.contains(
                "/Users/x/Library/Saved Application State/dev.quantizor.directa.app.savedState"))
    }

    @Test func atomicWriteAndDefensiveLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "directa-test-\(UUID().uuidString)")
        let file = dir.appending(path: "state.json")
        struct Payload: Codable, Equatable {
            var value: Int
        }
        try AtomicFile.write(try JSONCoding.encoder().encode(Payload(value: 7)), to: file)
        #expect(AtomicFile.loadDefensively(Payload.self, from: file) == Payload(value: 7))
        /** Corruption quarantines instead of throwing, and the original is moved aside. */
        try Data("not json".utf8).write(to: file)
        #expect(AtomicFile.loadDefensively(Payload.self, from: file) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".corrupt-") }
        #expect(quarantined.count == 1)
        try? FileManager.default.removeItem(at: dir)
    }

    /** Two writers inside one process must both succeed: a pid-only temp name
        made them rename the same temp file out from under each other, which is
        how the app lost agent.path when launch registration and the recovery
        poll wrote it at the same moment. */
    @Test func concurrentWritesToOneFileAllSucceed() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "directa-test-\(UUID().uuidString)")
        let file = dir.appending(path: "agent.path")
        let payloads = (0..<8).map { "payload-\($0)" }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for payload in payloads {
                group.addTask {
                    try AtomicFile.write(Data(payload.utf8), to: file)
                }
            }
            try await group.waitForAll()
        }
        let written = try String(decoding: Data(contentsOf: file), as: UTF8.self)
        #expect(payloads.contains(written))
        /** No temp files survive a clean run. */
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".agent.path.tmp-") }
        #expect(leftovers.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    /** A rename that fails (here, a destination `chflags`'d immutable, which
        macOS refuses to replace) must not leave the temp file behind: nothing
        else ever names it, so a leftover here sits in the state directory
        forever, the same class of leak `sweepStaleTemps` exists to clean up
        for an earlier crash rather than a failed replace. */
    @Test func failedReplaceLeavesNoTempBehind() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "directa-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "state.json")
        try Data("{}".utf8).write(to: file)
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        defer {
            _ = chflags(file.path, 0)
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(throws: (any Error).self) {
            try AtomicFile.write(Data("{\"value\":1}".utf8), to: file)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".tmp-") }
        #expect(leftovers.isEmpty)
    }

    /** The boot-time sweep removes a temp whose writer already died and leaves
        alone one whose writer (this test process) is still running: the same
        distinction that keeps the sweep from ever touching a concurrent
        `write` mid-flight under a live daemon. */
    @Test func sweepRemovesADeadPidTempAndKeepsALivePidTemp() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "directa-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let deadProcess = Process()
        deadProcess.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try deadProcess.run()
        deadProcess.waitUntilExit()
        let deadTemp = dir.appending(
            path: ".registry.json.tmp-\(deadProcess.processIdentifier)-\(UUID().uuidString)")
        let liveTemp = dir.appending(path: ".registry.json.tmp-\(getpid())-\(UUID().uuidString)")
        try Data().write(to: deadTemp)
        try Data().write(to: liveTemp)

        AtomicFile.sweepStaleTemps(in: dir) { pid in
            guard let narrow = pid_t(exactly: pid) else { return false }
            return kill(narrow, 0) == 0
        }

        #expect(!FileManager.default.fileExists(atPath: deadTemp.path))
        #expect(FileManager.default.fileExists(atPath: liveTemp.path))
    }

    /** `tempFilePid` is the seam `sweepStaleTemps` trusts to tell a `write`
        temp from anything else in the state directory; a bare `.corrupt-`
        quarantine file or an unrelated dotfile must never parse as one. */
    @Test func tempFilePidParsesOnlyTheWriteGeneratedShape() {
        #expect(AtomicFile.tempFilePid(".registry.json.tmp-4242-\(UUID().uuidString)") == 4242)
        #expect(AtomicFile.tempFilePid("registry.json") == nil)
        #expect(AtomicFile.tempFilePid("registry.json.corrupt-2025-07-18T19-46-40.000Z") == nil)
        #expect(AtomicFile.tempFilePid(".registry.json.tmp-not-a-pid-abc") == nil)
    }
}
