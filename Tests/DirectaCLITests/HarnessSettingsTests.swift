import DirectaKit
import Foundation
import Testing

@testable import directa

/** `hook install` merges directa's session hook into a settings file the user
    owns and directa does not: `~/.claude/settings.json` holds every other hook,
    permission and preference the harness reads. The install writes the whole
    file back from what it read, so what the read does on a file it cannot parse
    decides whether the merge is a merge or a replacement. It used to answer with
    an empty dictionary, which the write then persisted as the entire file. */
@Suite struct HarnessSettingsTests {
    /** Stands in for a real adapter so these exercise the shared load/write pair
        rather than either harness's key layout. */
    private struct StubAdapter: HarnessAdapter {
        let name = "stub"
        let settingsURL: URL
        func install(cliPath: String) throws -> String { "" }
        func uninstall() throws -> String { "" }
        func hookState() -> HarnessHookState { .harnessAbsent }
    }

    private func inScratch(_ body: (StubAdapter) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "directa-harness-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(StubAdapter(settingsURL: dir.appending(path: "settings.json")))
    }

    /** Stands in for a harness whose settings file directa must refuse. */
    private struct FailingAdapter: HarnessAdapter {
        let name = "failing"
        let settingsURL: URL
        func install(cliPath: String) throws -> String { "" }
        func uninstall() throws -> String {
            throw WireError(code: .configInvalid, hint: "h", message: "nope")
        }
        func hookState() -> HarnessHookState { .harnessAbsent }
    }

    @Test func aMissingFileSeedsAnEmptyMerge() throws {
        try inScratch { adapter in
            let loaded = try adapter.loadSettings()
            #expect(loaded.isEmpty)
        }
    }

    /** Zero bytes is a seed rather than a loss: there is nothing in the file to
        erase, and refusing would strand anyone whose editor left one behind. */
    @Test func anEmptyFileSeedsAnEmptyMerge() throws {
        try inScratch { adapter in
            try Data().write(to: adapter.settingsURL)
            let loaded = try adapter.loadSettings()
            #expect(loaded.isEmpty)
        }
    }

    @Test func anExistingObjectLoadsWholeSoTheMergeKeepsIt() throws {
        try inScratch { adapter in
            try Data(#"{"permissions":{"allow":["Bash"]},"model":"opus"}"#.utf8)
                .write(to: adapter.settingsURL)
            let loaded = try adapter.loadSettings()
            #expect(loaded.count == 2)
            #expect(loaded["model"] as? String == "opus")
        }
    }

    /** The regression that matters. Before the refusal this returned `[:]`, and
        the caller wrote that back as the whole file: every unrelated setting in
        it was gone, reported as a successful install. */
    @Test(arguments: [
        #"{"model": "opus","#,  // truncated by a partial write
        #"["not", "an", "object"]"#,  // valid JSON, wrong top level
        "not json at all",
    ])
    func aFilePresentButUnparseableIsRefusedRatherThanReplaced(contents: String) throws {
        try inScratch { adapter in
            try Data(contents.utf8).write(to: adapter.settingsURL)
            #expect(throws: WireError.self) { try adapter.loadSettings() }
            /** The refusal is only worth anything if the file is still there
                afterwards, so assert the bytes, not just the throw. */
            let after = try String(contentsOf: adapter.settingsURL, encoding: .utf8)
            #expect(after == contents)
        }
    }

    /** Whoever hits this is looking at a file directa declined to touch, so the
        message has to name the file, say why directa stopped, and leave them a
        command to rerun. */
    @Test func theRefusalNamesTheFileAndWhatToDo() throws {
        try inScratch { adapter in
            try Data("nope".utf8).write(to: adapter.settingsURL)
            let error = #expect(throws: WireError.self) { try adapter.loadSettings() }
            #expect(error?.code == .configInvalid)
            #expect(error?.message.contains(adapter.settingsURL.path) == true)
            #expect(error?.hint == "directa hook install")
        }
    }

    @Test func aWriteRoundTripsThroughTheLoad() throws {
        try inScratch { adapter in
            try adapter.writeSettings(["hooks": ["SessionStart": []], "keep": "me"])
            let loaded = try adapter.loadSettings()
            #expect(loaded["keep"] as? String == "me")
        }
    }

    private func inScratchDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "directa-harness-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    /** Install then uninstall leaves the file byte-for-byte as it started, and
        preserves an unrelated setting throughout: the round trip must not clobber
        what the user owns. */
    @Test func claudeInstallThenUninstallRestoresAndKeepsOtherSettings() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "settings.json")
            try Data(#"{"model":"opus"}"#.utf8).write(to: settings)
            let adapter = ClaudeCodeAdapter(settingsURLOverride: settings)

            let cliPath = dir.appending(path: "bin/directa").path
            _ = try adapter.install(cliPath: cliPath)
            if case .installed(let path, let exists) = adapter.hookState() {
                #expect(path == cliPath)
                #expect(!exists)  // a path under the scratch dir that we never create
            } else {
                Issue.record("expected the hook to read as installed")
            }
            let afterInstall = try adapter.loadSettings()
            #expect(afterInstall["model"] as? String == "opus")

            let summary = try adapter.uninstall()
            #expect(summary.contains("removed"))
            #expect(adapter.hookState() == .notInstalled)
            let afterUninstall = try adapter.loadSettings()
            #expect(afterUninstall["model"] as? String == "opus")
            /** The whole `hooks` key is gone once it held only directa's hook, so
                the file is back to just what the user had. */
            #expect(afterUninstall["hooks"] == nil)
        }
    }

    @Test func claudeUninstallWithoutAHookIsANoOp() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "settings.json")
            try Data(#"{"model":"opus"}"#.utf8).write(to: settings)
            let adapter = ClaudeCodeAdapter(settingsURLOverride: settings)
            let summary = try adapter.uninstall()
            #expect(summary.contains("not present"))
            #expect(try adapter.loadSettings()["model"] as? String == "opus")
        }
    }

    @Test func claudeUninstallKeepsAForeignHookInTheSameEntry() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "settings.json")
            let adapter = ClaudeCodeAdapter(settingsURLOverride: settings)
            try adapter.writeSettings([
                "hooks": [
                    "SessionStart": [
                        [
                            "hooks": [
                                ["command": "/x/directa hook claude-session-start", "type": "command"],
                                ["command": "/other/tool run", "type": "command"],
                            ],
                            "matcher": "startup",
                        ]
                    ]
                ]
            ])
            _ = try adapter.uninstall()
            let loaded = try adapter.loadSettings()
            let entries = (loaded["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]
            let commands =
                (entries?.first?["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String }
                ?? []
            #expect(commands == ["/other/tool run"])
        }
    }

    @Test func cursorInstallThenUninstallRoundTrips() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks.json")
            let adapter = CursorAdapter(settingsURLOverride: settings)
            let cliPath = dir.appending(path: "bin/directa").path
            _ = try adapter.install(cliPath: cliPath)
            if case .installed(let path, _) = adapter.hookState() {
                #expect(path == cliPath)
            } else {
                Issue.record("expected the cursor hook to read as installed")
            }
            _ = try adapter.uninstall()
            #expect(adapter.hookState() == .notInstalled)
        }
    }

    @Test func antigravityInstallThenUninstallRestoresAndKeepsOtherSettings() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks.json")
            try Data(#"{"other-tool":{"PostToolUse":[]}}"#.utf8).write(to: settings)
            let adapter = AntigravityAdapter(settingsURLOverride: settings)

            let cliPath = dir.appending(path: "bin/directa").path
            _ = try adapter.install(cliPath: cliPath)
            if case .installed(let path, let exists) = adapter.hookState() {
                #expect(path == cliPath)
                #expect(!exists)
            } else {
                Issue.record("expected the antigravity hook to read as installed")
            }
            let afterInstall = try adapter.loadSettings()
            #expect(afterInstall["other-tool"] != nil)
            #expect(afterInstall["directa"] != nil)

            let summary = try adapter.uninstall()
            #expect(summary.contains("removed"))
            #expect(adapter.hookState() == .notInstalled)
            let afterUninstall = try adapter.loadSettings()
            #expect(afterUninstall["other-tool"] != nil)
            #expect(afterUninstall["directa"] == nil)
        }
    }

    @Test func antigravityUninstallWithoutAHookIsANoOp() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks.json")
            try Data(#"{"other-tool":{"PostToolUse":[]}}"#.utf8).write(to: settings)
            let adapter = AntigravityAdapter(settingsURLOverride: settings)
            let summary = try adapter.uninstall()
            #expect(summary.contains("not present"))
            #expect(try adapter.loadSettings()["other-tool"] != nil)
        }
    }

    @Test func antigravityUninstallKeepsAForeignHookInSameGroup() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks.json")
            let adapter = AntigravityAdapter(settingsURLOverride: settings)
            try adapter.writeSettings([
                "directa": [
                    "PreInvocation": [
                        ["command": "/x/directa hook antigravity-session-start", "type": "command"],
                        ["command": "/other/tool run", "type": "command"],
                    ]
                ]
            ])
            _ = try adapter.uninstall()
            let loaded = try adapter.loadSettings()
            let directa = loaded["directa"] as? [String: Any]
            let entries = directa?["PreInvocation"] as? [[String: Any]]
            let commands = entries?.compactMap { $0["command"] as? String } ?? []
            #expect(commands == ["/other/tool run"])
        }
    }

    @Test func antigravityRepairHookPath() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks.json")
            let adapter = AntigravityAdapter(settingsURLOverride: settings)
            try adapter.writeSettings([
                "directa": [
                    "PreInvocation": [
                        ["command": "/old/path/directa hook antigravity-session-start", "type": "command"]
                    ]
                ]
            ])
            let newPath = dir.appending(path: "bin/directa").path
            let summary = try adapter.install(cliPath: newPath)
            #expect(summary.contains("repaired"))
            if case .installed(let path, _) = adapter.hookState() {
                #expect(path == newPath)
            } else {
                Issue.record("expected the repaired hook to read as installed")
            }
        }
    }

    @Test func grokInstallThenUninstallRestoresAndKeepsOtherSettings() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks/directa.json")
            try FileManager.default.createDirectory(
                at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"keep":true}"#.utf8).write(to: settings)
            let sibling = dir.appending(path: "rules/other.md")
            try FileManager.default.createDirectory(
                at: sibling.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("leave me\n".utf8).write(to: sibling)
            let adapter = GrokAdapter(settingsURLOverride: settings)

            let cliPath = dir.appending(path: "bin/directa").path
            _ = try adapter.install(cliPath: cliPath)
            if case .installed(let path, let exists) = adapter.hookState() {
                #expect(path == cliPath)
                #expect(!exists)
            } else {
                Issue.record("expected the grok hook to read as installed")
            }
            let afterInstall = try adapter.loadSettings()
            #expect(afterInstall["keep"] as? Bool == true)
            let hooks = afterInstall["hooks"] as? [String: Any]
            for event in GrokAdapter.registeredEvents {
                let groups = hooks?[event] as? [[String: Any]]
                #expect(groups?.count == 1)
                #expect(groups?.first?["matcher"] == nil)
                let handlers = groups?.first?["hooks"] as? [[String: Any]]
                #expect(handlers?.first?["timeout"] as? Int == 10)
                #expect((handlers?.first?["command"] as? String)?.hasSuffix(" hook grok-session-start") == true)
            }
            #expect(hooks?["SessionStart"] == nil)
            #expect(hooks?["SessionEnd"] == nil)
            #expect(hooks?["PostCompact"] == nil)
            #expect(hooks?["Stop"] == nil)
            let rules = try String(contentsOf: adapter.rulesURL, encoding: .utf8)
            #expect(rules.contains("directa ensure"))
            #expect(rules.contains("`directa context`"))
            #expect(!rules.contains("<directa-servers>"))

            let summary = try adapter.uninstall()
            #expect(summary.contains("removed"))
            #expect(adapter.hookState() == .notInstalled)
            #expect(!FileManager.default.fileExists(atPath: adapter.rulesURL.path))
            let afterUninstall = try adapter.loadSettings()
            #expect(afterUninstall["keep"] as? Bool == true)
            #expect(afterUninstall["hooks"] == nil)
            let siblingAfter = try String(contentsOf: sibling, encoding: .utf8)
            #expect(siblingAfter == "leave me\n")
        }
    }

    @Test func grokUninstallWithoutAHookIsANoOp() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks/directa.json")
            try FileManager.default.createDirectory(
                at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"keep":true}"#.utf8).write(to: settings)
            let adapter = GrokAdapter(settingsURLOverride: settings)
            try FileManager.default.createDirectory(
                at: adapter.rulesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("user rule\n".utf8).write(to: adapter.rulesURL)
            let summary = try adapter.uninstall()
            #expect(summary.contains("not present"))
            #expect(try adapter.loadSettings()["keep"] as? Bool == true)
            let leftover = try String(contentsOf: adapter.rulesURL, encoding: .utf8)
            #expect(leftover == "user rule\n")
        }
    }

    @Test func grokUninstallKeepsAForeignHookInTheSameEntry() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks/directa.json")
            try FileManager.default.createDirectory(
                at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let adapter = GrokAdapter(settingsURLOverride: settings)
            try adapter.writeSettings([
                "hooks": [
                    "SessionStart": [
                        [
                            "hooks": [
                                ["command": "/x/directa hook grok-session-start", "type": "command"],
                                ["command": "/other/tool run", "type": "command"],
                            ]
                        ]
                    ]
                ]
            ])
            _ = try adapter.uninstall()
            let loaded = try adapter.loadSettings()
            let entries = (loaded["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]
            let commands =
                (entries?.first?["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String }
                ?? []
            #expect(commands == ["/other/tool run"])
        }
    }

    @Test func grokRepairHookPath() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks/directa.json")
            try FileManager.default.createDirectory(
                at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let adapter = GrokAdapter(settingsURLOverride: settings)
            let oldHandler: [String: Any] = [
                "command": "/old/path/directa hook grok-session-start", "type": "command",
            ]
            try adapter.writeSettings([
                "hooks": [
                    "PreToolUse": [["hooks": [oldHandler]]],
                    "UserPromptSubmit": [["hooks": [oldHandler]]],
                ]
            ])
            let newPath = dir.appending(path: "bin/directa").path
            let summary = try adapter.install(cliPath: newPath)
            #expect(summary.contains("repaired"))
            if case .installed(let path, _) = adapter.hookState() {
                #expect(path == newPath)
            } else {
                Issue.record("expected the repaired hook to read as installed")
            }
            let hooks = try adapter.loadSettings()["hooks"] as? [String: Any]
            #expect(hooks?["SessionStart"] == nil)
        }
    }

    @Test func standingInstructionWriteIsStaticInstructionOnly() throws {
        try inScratchDir { dir in
            let url = dir.appending(path: "rules/directa.md")
            try HarnessStandingInstruction.write(to: url)
            let body = try String(contentsOf: url, encoding: .utf8)
            #expect(body.contains(HarnessStandingInstruction.preamble))
            #expect(!body.contains("<directa-servers>"))
            try HarnessStandingInstruction.remove(at: url)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func grokUninstallDeletesAFileThatHeldOnlyDirectaHooks() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks/directa.json")
            try FileManager.default.createDirectory(
                at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let adapter = GrokAdapter(settingsURLOverride: settings)
            _ = try adapter.install(cliPath: dir.appending(path: "bin/directa").path)
            #expect(FileManager.default.fileExists(atPath: settings.path))
            _ = try adapter.uninstall()
            #expect(!FileManager.default.fileExists(atPath: settings.path))
            #expect(!FileManager.default.fileExists(atPath: adapter.rulesURL.path))
        }
    }

    @Test func grokInstallIsIdempotentWhenRegisteredEventsAlreadyMatch() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks/directa.json")
            try FileManager.default.createDirectory(
                at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let adapter = GrokAdapter(settingsURLOverride: settings)
            let cliPath = dir.appending(path: "bin/directa").path
            let handler: [String: Any] = [
                "command": "\(cliPath) hook grok-session-start", "type": "command",
            ]
            var events: [String: Any] = [:]
            for event in GrokAdapter.registeredEvents {
                events[event] = [["hooks": [handler]]]
            }
            try adapter.writeSettings(["hooks": events])
            let summary = try adapter.install(cliPath: cliPath)
            #expect(summary.contains("already installed"))
            let hooks = try adapter.loadSettings()["hooks"] as? [String: Any]
            for event in GrokAdapter.registeredEvents {
                #expect((hooks?[event] as? [[String: Any]])?.count == 1)
            }
            #expect(hooks?["Stop"] == nil)
            #expect(FileManager.default.fileExists(atPath: adapter.rulesURL.path))
        }
    }

    @Test func grokInstallUpgradesASessionStartOnlyHook() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks/directa.json")
            try FileManager.default.createDirectory(
                at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let adapter = GrokAdapter(settingsURLOverride: settings)
            let cliPath = dir.appending(path: "bin/directa").path
            try adapter.writeSettings([
                "hooks": [
                    "SessionStart": [
                        [
                            "hooks": [
                                ["command": "\(cliPath) hook grok-session-start", "type": "command"]
                            ]
                        ]
                    ]
                ]
            ])
            #expect(adapter.hookState() == .notInstalled)
            let summary = try adapter.install(cliPath: cliPath)
            #expect(summary.contains("installed"))
            #expect(!summary.contains("already"))
            if case .installed(let path, _) = adapter.hookState() {
                #expect(path == cliPath)
            } else {
                Issue.record("expected the upgraded hook to read as installed")
            }
            let hooks = try adapter.loadSettings()["hooks"] as? [String: Any]
            for event in GrokAdapter.registeredEvents {
                let commands =
                    ((hooks?[event] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?
                    .compactMap { $0["command"] as? String } ?? []
                #expect(commands.contains("\(cliPath) hook grok-session-start"))
            }
            #expect(hooks?["SessionStart"] == nil)
        }
    }

    @Test func grokHookStateRequiresBothPreToolUseAndUserPromptSubmit() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks/directa.json")
            try FileManager.default.createDirectory(
                at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let adapter = GrokAdapter(settingsURLOverride: settings)
            let command = "\(dir.appending(path: "bin/directa").path) hook grok-session-start"
            let group: [[String: Any]] = [["hooks": [["command": command, "type": "command"]]]]
            try adapter.writeSettings(["hooks": ["PreToolUse": group]])
            #expect(adapter.hookState() == .notInstalled)
            try adapter.writeSettings(["hooks": ["UserPromptSubmit": group]])
            #expect(adapter.hookState() == .notInstalled)
            try adapter.writeSettings(["hooks": ["PreToolUse": group, "UserPromptSubmit": group]])
            if case .installed = adapter.hookState() {
            } else {
                Issue.record("expected both events to read as installed")
            }
        }
    }

    @Test func grokHookEventParse() {
        #expect(GrokHookEvent.parse("pre_tool_use") == .preToolUse)
        #expect(GrokHookEvent.parse("PRE_TOOL_USE") == .preToolUse)
        #expect(GrokHookEvent.parse("user_prompt_submit") == .userPromptSubmit)
        #expect(GrokHookEvent.parse(nil) == .unspecified)
        #expect(GrokHookEvent.parse("session_start") == .leftover)
        #expect(GrokHookEvent.parse("stop") == .leftover)
        #expect(GrokHookEvent.parse("post_tool_use") == .leftover)
    }

    @Test func grokSessionHookActionMatrix() {
        var state = GrokSessionHook.TurnState(emittedThisTurn: false, turn: 0)
        #expect(GrokSessionHook.action(for: .leftover, state: &state) == .silent)
        #expect(state.turn == 0)
        #expect(GrokSessionHook.action(for: .unspecified, state: &state) == .emitUnmarked)
        #expect(state.emittedThisTurn == false)

        #expect(GrokSessionHook.action(for: .preToolUse, state: &state) == .emitAndMark)
        #expect(state.emittedThisTurn == false)
        GrokSessionHook.markEmitted(&state)
        #expect(state.emittedThisTurn == true)
        #expect(GrokSessionHook.action(for: .preToolUse, state: &state) == .silent)

        #expect(GrokSessionHook.action(for: .userPromptSubmit, state: &state) == .silentPersist)
        #expect(state.turn == 1)
        #expect(state.emittedThisTurn == false)
        #expect(GrokSessionHook.action(for: .preToolUse, state: &state) == .emitAndMark)
        GrokSessionHook.markEmitted(&state)
        #expect(state.emittedThisTurn == true)
        #expect(GrokSessionHook.action(for: .preToolUse, state: &state) == .silent)

        #expect(GrokSessionHook.action(for: .userPromptSubmit, state: &state) == .silentPersist)
        #expect(state.turn == 2)
        #expect(GrokSessionHook.action(for: .preToolUse, state: &state) == .emitAndMark)
        GrokSessionHook.markEmitted(&state)
        #expect(state.emittedThisTurn == true)
    }

    @Test func grokTurnGateSessionKeySanitizes() {
        #expect(GrokTurnGate.sessionKey(nil) == GrokTurnGate.fallbackKey)
        #expect(GrokTurnGate.sessionKey("") == GrokTurnGate.fallbackKey)
        #expect(GrokTurnGate.sessionKey("ok-id_1.2") == "ok-id_1.2")
        #expect(GrokTurnGate.sessionKey(".") == GrokTurnGate.fallbackKey)
        #expect(GrokTurnGate.sessionKey("..") == GrokTurnGate.fallbackKey)
        #expect(!GrokTurnGate.sessionKey("../../etc/passwd").contains("/"))
        let long = String(repeating: "a", count: 200)
        #expect(GrokTurnGate.sessionKey(long).count == GrokTurnGate.maxKeyLength)
    }

    @Test func grokTurnGateReadsSessionIdFromStdin() {
        #expect(GrokTurnGate.sessionId(in: Data(#"{"sessionId":"abc"}"#.utf8)) == "abc")
        #expect(GrokTurnGate.sessionId(in: Data(#"{"session_id":"def"}"#.utf8)) == "def")
        #expect(GrokTurnGate.sessionId(in: Data("{}".utf8)) == nil)
    }

    @Test func grokTurnGateRoundTripsState() throws {
        try inScratchDir { dir in
            let stateDir = dir.appending(path: "state")
            let original = GrokSessionHook.TurnState(emittedThisTurn: true, turn: 3)
            GrokTurnGate.save(original, sessionKey: "sess1", directory: stateDir)
            #expect(GrokTurnGate.load(sessionKey: "sess1", directory: stateDir) == original)
            let missing = GrokTurnGate.load(sessionKey: "other", directory: stateDir)
            #expect(missing == GrokSessionHook.TurnState(emittedThisTurn: false, turn: 0))
        }
    }

    /** The CLI persist protocol: UPS save is immediate; PreToolUse marks only
        after a successful emit. Dropping either save would make the next
        PreToolUse of the same turn emit again. */
    @Test func grokTurnGateDiskProtocolSkipsASecondPreToolUseOfTheSameTurn() throws {
        try inScratchDir { dir in
            let stateDir = dir.appending(path: "state")
            let key = "sess-disk"
            var state = GrokTurnGate.load(sessionKey: key, directory: stateDir)
            #expect(GrokSessionHook.action(for: .userPromptSubmit, state: &state) == .silentPersist)
            GrokTurnGate.save(state, sessionKey: key, directory: stateDir)

            state = GrokTurnGate.load(sessionKey: key, directory: stateDir)
            #expect(state.turn == 1)
            #expect(GrokSessionHook.action(for: .preToolUse, state: &state) == .emitAndMark)
            GrokSessionHook.markEmitted(&state)
            GrokTurnGate.save(state, sessionKey: key, directory: stateDir)

            state = GrokTurnGate.load(sessionKey: key, directory: stateDir)
            #expect(GrokSessionHook.action(for: .preToolUse, state: &state) == .silent)
        }
    }

    @Test func grokTurnGateDirectoryHonorsOverride() {
        let override = "/tmp/directa-grok-test-dir"
        #expect(
            GrokTurnGate.directory(environment: ["DIRECTA_GROK_HOOK_STATE_DIR": override]).path
                == override)
        let fromTmp = GrokTurnGate.directory(environment: ["TMPDIR": "/tmp/custom-tmp"])
        #expect(fromTmp.lastPathComponent == GrokTurnGate.stateDirName)
    }

    @Test func grokInstallStripsALeftoverStopHook() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks/directa.json")
            try FileManager.default.createDirectory(
                at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let adapter = GrokAdapter(settingsURLOverride: settings)
            let cliPath = dir.appending(path: "bin/directa").path
            try adapter.writeSettings([
                "hooks": [
                    "SessionStart": [
                        [
                            "hooks": [
                                ["command": "\(cliPath) hook grok-session-start", "type": "command"]
                            ]
                        ]
                    ],
                    "Stop": [
                        [
                            "hooks": [
                                ["command": "\(cliPath) hook grok-session-start", "type": "command"],
                                ["command": "/other/tool run", "type": "command"],
                            ]
                        ]
                    ],
                ]
            ])
            let summary = try adapter.install(cliPath: cliPath)
            #expect(summary.contains("installed"))
            let hooks = try adapter.loadSettings()["hooks"] as? [String: Any]
            for event in GrokAdapter.registeredEvents {
                #expect((hooks?[event] as? [[String: Any]])?.count == 1)
            }
            #expect(hooks?["SessionStart"] == nil)
            let stopCommands =
                ((hooks?["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?
                .compactMap { $0["command"] as? String } ?? []
            #expect(stopCommands == ["/other/tool run"])
        }
    }

    @Test func grokInstallStripsALeftoverStopHookWhenAlreadyInstalled() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks/directa.json")
            try FileManager.default.createDirectory(
                at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let adapter = GrokAdapter(settingsURLOverride: settings)
            let cliPath = dir.appending(path: "bin/directa").path
            let handler: [String: Any] = [
                "command": "\(cliPath) hook grok-session-start", "type": "command",
            ]
            var events: [String: Any] = [
                "Stop": [
                    [
                        "hooks": [
                            ["command": "\(cliPath) hook grok-session-start", "type": "command"]
                        ]
                    ]
                ]
            ]
            for event in GrokAdapter.registeredEvents {
                events[event] = [["hooks": [handler]]]
            }
            try adapter.writeSettings(["hooks": events])
            let summary = try adapter.install(cliPath: cliPath)
            #expect(summary.contains("leftover hook removed"))
            let hooks = try adapter.loadSettings()["hooks"] as? [String: Any]
            #expect(hooks?["Stop"] == nil)
            #expect(hooks?["SessionStart"] == nil)
        }
    }

    @Test func grokInstallStripsLeftoverSessionStartWhenAlreadyInstalled() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "hooks/directa.json")
            try FileManager.default.createDirectory(
                at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let adapter = GrokAdapter(settingsURLOverride: settings)
            let cliPath = dir.appending(path: "bin/directa").path
            let handler: [String: Any] = [
                "command": "\(cliPath) hook grok-session-start", "type": "command",
            ]
            var events: [String: Any] = [
                "SessionStart": [["hooks": [handler]]]
            ]
            for event in GrokAdapter.registeredEvents {
                events[event] = [["hooks": [handler]]]
            }
            try adapter.writeSettings(["hooks": events])
            let summary = try adapter.install(cliPath: cliPath)
            #expect(summary.contains("leftover hook removed"))
            let hooks = try adapter.loadSettings()["hooks"] as? [String: Any]
            #expect(hooks?["SessionStart"] == nil)
            for event in GrokAdapter.registeredEvents {
                #expect((hooks?[event] as? [[String: Any]])?.count == 1)
            }
        }
    }

    /** OpenCode merges opencode.json and opencode.jsonc with a later file's
        `instructions` array replacing an earlier file's, so the round trip has
        to preserve foreign entries and never touch the file that loses. */
    @Test func opencodeInstallThenUninstallRestoresAndKeepsOtherSettings() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "opencode.jsonc")
            try Data(
                #"{"$schema":"https://opencode.ai/config.json","model":"claude-sonnet-4-5"}"#
                    .utf8
            ).write(to: settings)
            let adapter = OpenCodeAdapter(settingsURLOverride: settings)

            _ = try adapter.install(cliPath: "")
            if case .installed(let path, let exists) = adapter.hookState() {
                #expect(path == adapter.instructionsFileURL.path)
                #expect(exists)
            } else {
                Issue.record("expected the opencode wiring to read as installed")
            }
            let afterInstall = try adapter.loadSettings()
            #expect(afterInstall["model"] as? String == "claude-sonnet-4-5")
            #expect(afterInstall["instructions"] as? [String] == [adapter.instructionsEntry])
            let managed = try String(contentsOf: adapter.instructionsFileURL, encoding: .utf8)
            #expect(managed.contains("`directa context`"))
            #expect(!managed.contains("<directa-servers>"))

            let summary = try adapter.uninstall()
            #expect(summary.contains("removed"))
            #expect(adapter.hookState() == .notInstalled)
            #expect(!FileManager.default.fileExists(atPath: adapter.instructionsFileURL.path))
            let afterUninstall = try adapter.loadSettings()
            #expect(afterUninstall["model"] as? String == "claude-sonnet-4-5")
            #expect(afterUninstall["instructions"] == nil)
        }
    }

    @Test func opencodeInstallIsIdempotentAndRefreshesTheManagedFile() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "opencode.jsonc")
            let adapter = OpenCodeAdapter(settingsURLOverride: settings)
            try adapter.writeSettings(["instructions": [adapter.instructionsEntry]])
            try HarnessStandingInstruction.write(to: adapter.instructionsFileURL)
            try Data("stale\n".utf8).write(to: adapter.instructionsFileURL)

            let summary = try adapter.install(cliPath: "")
            #expect(summary.contains("already installed"))
            #expect(
                try adapter.loadSettings()["instructions"] as? [String]
                    == [adapter.instructionsEntry])
            let managed = try String(contentsOf: adapter.instructionsFileURL, encoding: .utf8)
            #expect(managed == HarnessStandingInstruction.preamble + "\n")
        }
    }

    @Test func opencodeInstallKeepsForeignInstructions() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "opencode.jsonc")
            let adapter = OpenCodeAdapter(settingsURLOverride: settings)
            try adapter.writeSettings(["instructions": ["CONTRIBUTING.md", "docs/*.md"]])
            _ = try adapter.install(cliPath: "")
            #expect(
                try adapter.loadSettings()["instructions"] as? [String]
                    == ["CONTRIBUTING.md", "docs/*.md", adapter.instructionsEntry])
        }
    }

    @Test func opencodeInstallRefusesANonArrayInstructionsAndLeavesItAlone() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "opencode.jsonc")
            let contents = #"{"instructions":"CONTRIBUTING.md"}"#
            try Data(contents.utf8).write(to: settings)
            let adapter = OpenCodeAdapter(settingsURLOverride: settings)
            let error = #expect(throws: WireError.self) { try adapter.install(cliPath: "") }
            #expect(error?.code == .configInvalid)
            #expect(error?.message.contains("not an array of paths") == true)
            let after = try String(contentsOf: settings, encoding: .utf8)
            #expect(after == contents)
            #expect(!FileManager.default.fileExists(atPath: adapter.instructionsFileURL.path))
        }
    }

    /** A comment-bearing opencode.jsonc is legal for OpenCode and unreadable
        for JSONSerialization, so the install refuses instead of rewriting the
        file without its comments. */
    @Test func opencodeInstallRefusesACommentedJsoncAndLeavesItAlone() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "opencode.jsonc")
            let contents = """
                {
                  // the user's own note
                  "model": "claude-sonnet-4-5",
                }
                """
            try Data(contents.utf8).write(to: settings)
            let adapter = OpenCodeAdapter(settingsURLOverride: settings)
            let error = #expect(throws: WireError.self) { try adapter.install(cliPath: "") }
            #expect(error?.code == .configInvalid)
            #expect(error?.message.contains("JSONC") == true)
            #expect(error?.message.contains("directa.md") == true)
            let after = try String(contentsOf: settings, encoding: .utf8)
            #expect(after == contents)
            #expect(!FileManager.default.fileExists(atPath: adapter.instructionsFileURL.path))
        }
    }

    /** The winner's `instructions` array replaces the losing file's on merge,
        so entries effective from opencode.json must move into the array the
        jsonc write carries, or landing the entry would deactivate them. */
    @Test func opencodeInstallCarriesShadowedEntriesIntoTheWinner() throws {
        try inScratchDir { dir in
            let winner = dir.appending(path: "opencode.jsonc")
            let loser = dir.appending(path: "opencode.json")
            try Data(#"{"instructions":["CONTRIBUTING.md"]}"#.utf8).write(to: loser)
            let adapter = OpenCodeAdapter(settingsURLOverride: winner)

            _ = try adapter.install(cliPath: "")
            #expect(
                try adapter.loadSettings()["instructions"] as? [String]
                    == ["CONTRIBUTING.md", adapter.instructionsEntry])
            let losingAfter = try String(contentsOf: loser, encoding: .utf8)
            #expect(losingAfter == #"{"instructions":["CONTRIBUTING.md"]}"#)

            let summary = try adapter.uninstall()
            #expect(summary.contains("removed"))
            /** The carried entries stay; only directa's entry goes. */
            #expect(try adapter.loadSettings()["instructions"] as? [String] == ["CONTRIBUTING.md"])
        }
    }

    @Test func opencodeUninstallDropsTheKeyAndAFileThatHeldOnlyDirecta() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "opencode.jsonc")
            let adapter = OpenCodeAdapter(settingsURLOverride: settings)
            try adapter.writeSettings([
                "instructions": ["CONTRIBUTING.md", adapter.instructionsEntry],
                "model": "claude-sonnet-4-5",
            ])
            _ = try adapter.uninstall()
            /** The foreign entry stays; only directa's goes. */
            #expect(
                try adapter.loadSettings()["instructions"] as? [String] == ["CONTRIBUTING.md"])
            #expect(try adapter.loadSettings()["model"] as? String == "claude-sonnet-4-5")

            try adapter.writeSettings(["instructions": [adapter.instructionsEntry]])
            _ = try adapter.uninstall()
            /** The file held only directa's entry, so it is directa's litter. */
            #expect(!FileManager.default.fileExists(atPath: settings.path))
        }
    }

    @Test func opencodeUninstallWithoutAnEntryRemovesOnlyAStaleManagedFile() throws {
        try inScratchDir { dir in
            let settings = dir.appending(path: "opencode.jsonc")
            try Data(#"{"model":"claude-sonnet-4-5"}"#.utf8).write(to: settings)
            let adapter = OpenCodeAdapter(settingsURLOverride: settings)
            try HarnessStandingInstruction.write(to: adapter.instructionsFileURL)

            let summary = try adapter.uninstall()
            #expect(summary.contains("not present"))
            #expect(summary.contains("stale managed instructions file"))
            #expect(!FileManager.default.fileExists(atPath: adapter.instructionsFileURL.path))
            #expect(try adapter.loadSettings()["model"] as? String == "claude-sonnet-4-5")

            let again = try adapter.uninstall()
            #expect(again.contains("not present"))
        }
    }

    @Test func opencodeHookStateFollowsTheArrayThatWinsTheMerge() throws {
        try inScratchDir { dir in
            let winner = dir.appending(path: "opencode.jsonc")
            let loser = dir.appending(path: "opencode.json")
            let adapter = OpenCodeAdapter(settingsURLOverride: winner)

            /** The winner's array replaces the losing file's on merge: an
                entry in opencode.json is invisible once opencode.jsonc holds a
                key. */
            try Data(#"{"instructions":["other.md"]}"#.utf8).write(to: winner)
            try Data("{\"instructions\":[\"\(adapter.instructionsEntry)\"]}".utf8)
                .write(to: loser)
            #expect(adapter.hookState() == .notInstalled)

            /** With no key in the winner, the losing file's array is the
                effective one, so ours there reads as installed (broken, since
                the managed file is absent). */
            try FileManager.default.removeItem(at: winner)
            if case .installed(let path, let exists) = adapter.hookState() {
                #expect(path == adapter.instructionsFileURL.path)
                #expect(!exists)
            } else {
                Issue.record("expected the opencode wiring to read as installed")
            }

            /** The winner carrying ours decides, with the managed file present. */
            try Data(
                "{\"instructions\":[\"\(adapter.instructionsEntry)\",\"other.md\"]}".utf8
            ).write(to: winner)
            try HarnessStandingInstruction.write(to: adapter.instructionsFileURL)
            if case .installed(let path, let exists) = adapter.hookState() {
                #expect(path == adapter.instructionsFileURL.path)
                #expect(exists)
            } else {
                Issue.record("expected the opencode wiring to read as installed")
            }

            /** The managed file going missing reads as a broken install, the
                same signal every other adapter reports. */
            try HarnessStandingInstruction.remove(at: adapter.instructionsFileURL)
            if case .installed(_, let exists) = adapter.hookState() {
                #expect(!exists)
            } else {
                Issue.record("expected the opencode wiring to read as installed")
            }
        }
    }

    @Test func opencodeHookStateReportsNotInstalledWhenTheConfigDirectoryExists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "directa-oc-home-\(UUID().uuidString)/.config/opencode")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appending(path: "opencode.jsonc")
        let adapter = OpenCodeAdapter(settingsURLOverride: settings)
        #expect(adapter.harnessPresent)
        #expect(adapter.hookState() == .notInstalled)
    }

    /** The entry references the managed file tilde-relative under the home so
        it never collides with a same-named project file and survives a synced
        config; anywhere else keeps the absolute form. */
    @Test func opencodeInstructionsEntryIsTildeRelativeUnderHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let managed = OpenCodeWiring.managedFileURL(inHome: home)
        #expect(
            OpenCodeWiring.instructionsEntry(forManagedFileAt: managed)
                == "~/.config/opencode/" + OpenCodeWiring.managedFileName)
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "directa-oc-entry-\(UUID().uuidString)/directa.md")
        #expect(OpenCodeWiring.instructionsEntry(forManagedFileAt: scratch) == scratch.path)
    }

    /** A set OPENCODE_CONFIG_DIR changes how OpenCode merges its globals, so
        install refuses instead of silently wiring a surface the harness may
        not honor. */
    @Test func opencodeInstallRefusesWhenTheConfigDirectoryIsOverridden() {
        #expect(OpenCodeAdapter.wiringRefusal(configDirectoryOverride: nil) == nil)
        #expect(OpenCodeAdapter.wiringRefusal(configDirectoryOverride: "") == nil)
        let refusal = OpenCodeAdapter.wiringRefusal(configDirectoryOverride: "/tmp/oc-config")
        #expect(refusal?.code == .configInvalid)
        #expect(refusal?.message.contains("OPENCODE_CONFIG_DIR") == true)
        #expect(refusal?.message.contains("/tmp/oc-config/directa.md") == true)
    }

    @Test func opencodeConfigDirectoryHonorsAnXDGOverride() {
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(
            OpenCodeWiring.configDirectory(home: home, xdgConfigHome: nil)
                == home.appending(path: ".config/opencode"))
        #expect(
            OpenCodeWiring.configDirectory(home: home, xdgConfigHome: "")
                == home.appending(path: ".config/opencode"))
        #expect(
            OpenCodeWiring.configDirectory(home: home, xdgConfigHome: "/xdg/config")
                == URL(fileURLWithPath: "/xdg/config/opencode"))
    }

    /** The one merge rule both the adapter and the app share: the first
        existing config file (winner first) holding the key decides, an
        unparseable file is skipped (OpenCode reads the JSONC we cannot), and a
        schema-invalid key leaves nothing effective. */
    @Test func opencodeEffectiveInstructionsFollowsTheWinnerAndSkipsTheUnreadable() throws {
        try inScratchDir { dir in
            #expect(OpenCodeWiring.effectiveInstructions(inDirectory: dir) == nil)

            try Data(#"{"instructions":["a"]}"#.utf8).write(
                to: dir.appending(path: "opencode.json"))
            let jsonOnly = OpenCodeWiring.effectiveInstructions(inDirectory: dir)
            #expect(jsonOnly?.file == dir.appending(path: "opencode.json"))
            #expect(jsonOnly?.entries == ["a"])

            try Data(#"{"instructions":["b"]}"#.utf8).write(
                to: dir.appending(path: "opencode.jsonc"))
            #expect(OpenCodeWiring.effectiveInstructions(inDirectory: dir)?.entries == ["b"])

            try Data(#"{"instructions":5}"#.utf8).write(
                to: dir.appending(path: "opencode.jsonc"))
            #expect(OpenCodeWiring.effectiveInstructions(inDirectory: dir) == nil)

            try Data("{ // comment }".utf8).write(to: dir.appending(path: "opencode.jsonc"))
            let skipped = OpenCodeWiring.effectiveInstructions(inDirectory: dir)
            #expect(skipped?.entries == ["a"])
        }
    }

    /** A refusal from one harness must not discard the others: their files are
        already rewritten when the throw lands, so uninstallAll collects. */
    @Test func uninstallAllCollectsFailuresInsteadOfAborting() throws {
        try inScratchDir { dir in
            let good = StubAdapter(settingsURL: dir.appending(path: "a.json"))
            let bad = FailingAdapter(settingsURL: dir.appending(path: "b.json"))
            let result = HookUninstall.uninstallAll([good, bad, good])
            #expect(result.summaries.count == 2)
            #expect(result.failures.count == 1)
            #expect(result.failures.first?.name == "failing")
            #expect(result.failures.first?.message == "nope")
        }
    }

    /** OpenCode's own preference order decides which global config file wins:
        jsonc over json over the legacy config.json, and opencode.jsonc is what
        OpenCode seeds on a fresh machine. */
    @Test func opencodeSettingsURLFollowsTheHarnessPreferenceOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "directa-oc-pref-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home")
        let dir = OpenCodeWiring.configDirectory(home: home)

        #expect(
            OpenCodeWiring.settingsURL(inHome: home) == dir.appending(path: "opencode.jsonc"))

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appending(path: "opencode.json"))
        #expect(
            OpenCodeWiring.settingsURL(inHome: home) == dir.appending(path: "opencode.json"))

        try Data("{}".utf8).write(to: dir.appending(path: "opencode.jsonc"))
        #expect(
            OpenCodeWiring.settingsURL(inHome: home) == dir.appending(path: "opencode.jsonc"))

        try FileManager.default.removeItem(at: dir.appending(path: "opencode.jsonc"))
        try FileManager.default.removeItem(at: dir.appending(path: "opencode.json"))
        try Data("{}".utf8).write(to: dir.appending(path: "config.json"))
        #expect(
            OpenCodeWiring.settingsURL(inHome: home) == dir.appending(path: "config.json"))
    }

    @Test func hookStateIsAbsentWhenTheHarnessDirectoryIsMissing() throws {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "directa-absent-\(UUID().uuidString)/settings.json")
        let adapter = ClaudeCodeAdapter(settingsURLOverride: missing)
        #expect(adapter.hookState() == .harnessAbsent)
        let antigravityMissing = FileManager.default.temporaryDirectory
            .appending(path: "directa-ag-absent-\(UUID().uuidString)/config/hooks.json")
        let agAdapter = AntigravityAdapter(settingsURLOverride: antigravityMissing)
        #expect(agAdapter.hookState() == .harnessAbsent)
        let grokMissing = FileManager.default.temporaryDirectory
            .appending(path: "directa-grok-absent-\(UUID().uuidString)/hooks/directa.json")
        let grokAdapter = GrokAdapter(settingsURLOverride: grokMissing)
        #expect(grokAdapter.hookState() == .harnessAbsent)
        let opencodeMissing = FileManager.default.temporaryDirectory
            .appending(path: "directa-oc-absent-\(UUID().uuidString)/.config/opencode/opencode.jsonc")
        let ocAdapter = OpenCodeAdapter(settingsURLOverride: opencodeMissing)
        #expect(ocAdapter.hookState() == .harnessAbsent)
    }

    @Test func hookStateReportsNotInstalledWhenAntigravityHomeDirectoryExists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "directa-ag-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appending(path: "config/hooks.json")
        let agAdapter = AntigravityAdapter(settingsURLOverride: settings)
        #expect(agAdapter.hookState() == .notInstalled)
    }

    @Test func hookStateReportsNotInstalledWhenGrokHomeDirectoryExists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "directa-grok-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appending(path: "hooks/directa.json")
        let grokAdapter = GrokAdapter(settingsURLOverride: settings)
        #expect(grokAdapter.hookState() == .notInstalled)
    }

    @Test func sessionCwdResolvesAntigravityWorkspacePaths() {
        let json = #"{"workspacePaths":["/my/workspace/path"]}"#
        let resolved = HookSessionCwd.resolve(stdin: Data(json.utf8))
        #expect(resolved == "/my/workspace/path")
    }

    @Test func sessionCwdResolvesClaudeCwd() {
        let json = #"{"cwd":"/my/claude/cwd"}"#
        let resolved = HookSessionCwd.resolve(stdin: Data(json.utf8))
        #expect(resolved == "/my/claude/cwd")
    }

    @Test func sessionCwdResolvesCursorWorkspaceRoots() {
        let json = #"{"workspace_roots":["/my/cursor/root"]}"#
        let resolved = HookSessionCwd.resolve(stdin: Data(json.utf8))
        #expect(resolved == "/my/cursor/root")
    }

    @Test func sessionCwdResolvesGrokWorkspaceRoot() {
        let json = #"{"workspaceRoot":"/my/grok/root"}"#
        let resolved = HookSessionCwd.resolve(stdin: Data(json.utf8))
        #expect(resolved == "/my/grok/root")
    }

    @Test func sessionCwdPrefersGrokCwdOverWorkspaceRoot() {
        let json = #"{"cwd":"/my/grok/cwd","workspaceRoot":"/my/grok/root"}"#
        let resolved = HookSessionCwd.resolve(stdin: Data(json.utf8))
        #expect(resolved == "/my/grok/cwd")
    }
}
