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

    /** The formatter builds its fractional digits from a millisecond integer,
        and Swift's `/` and `%` round toward zero, so a date before the epoch
        used to render as `.-500Z`: the formatter's own parser rejects that, and
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
}

@Suite struct PathTests {
    @Test func sunPathLimit() {
        #expect(DirectaPaths.fitsSunPath("/tmp/short.sock"))
        #expect(!DirectaPaths.fitsSunPath(String(repeating: "x", count: 104)))
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
}
