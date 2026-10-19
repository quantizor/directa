import DirectaKit
import Foundation
import Testing

@testable import directa

/** A failure's `hint` is the literal command that fixes it (`run: …`), pasteable
    as is; the detail a human needs sits in the message, and a failure no
    command fixes carries no hint. */
@Suite struct ErrorHintTests {
    private func server(heads: [String: String]? = nil, name: String = "web") -> ServerStatus {
        ServerStatus(
            heads: heads, logPath: "/logs/\(name)", phase: .running, project: "/code/app", server: name)
    }

    @Test func aMissingHeadPointsAtTheStatusThatListsHeadsAndNamesThemInTheMessage() {
        let error = OpenFailure.headNotFound(
            head: "cold", server: server(heads: ["wren": "http://wren.localhost:1/", "ash": "http://ash.localhost:1/"]))
        #expect(
            error
                == WireError(
                    code: .notFound, hint: "run: directa status web --json",
                    message: "no head named 'cold' on web; known heads: ash, wren"))
    }

    @Test func aServerWithNoHeadsSaysSoInTheMessage() {
        #expect(
            OpenFailure.headNotFound(head: "cold", server: server()).message
                == "no head named 'cold' on web; this server declares no heads")
    }

    /** No command adds a URL, so the failure carries the devservers.json edit
        in its message and no hint. */
    @Test func aServerWithNoURLNamesTheConfigEditAndCarriesNoHint() {
        let error = OpenFailure.noURL(server: server(), code: .usage)
        #expect(error.code == .usage)
        #expect(error.hint == nil)
        #expect(
            error.message
                == "web has no URL to open (no port declared and no url configured); add a port, url, or heads to web in devservers.json"
        )
        #expect(OpenFailure.noURL(server: server(), code: .notFound).code == .notFound)
    }

    @Test func anUnknownLinkVerbHintsTheSameCommandWithAVerbThatExists() {
        #expect(
            Link.unknownVerbError(verb: "launch", name: "web")
                == WireError(
                    code: .usage, hint: "run: directa link open web",
                    message: "unknown verb 'launch' (verbs: ensure, open, stop, why)"))
        #expect(Link.unknownVerbError(verb: "x", name: "my app").hint == "run: directa link open 'my app'")
    }

    @Test func aDirtyTreeHintsTheStatusThatShowsWhatIsDirty() {
        #expect(
            Switch.dirtyTreeError(project: "/code/my app")
                == WireError(
                    code: .usage, hint: "run: git -C '/code/my app' status",
                    message:
                        "the working tree has uncommitted changes; commit your work first (directa never stashes or discards changes)"
                ))
    }

    @Test func aFailedLifecycleCommandHintsDirectaUp() {
        #expect(
            Switch.lifecycleFailureError(status: 2, argv: ["bun", "install"])
                == WireError(
                    code: .internalError, hint: "run: directa up",
                    message:
                        "lifecycle command failed (2): bun install; fix the failure, then bring the servers up"))
    }

    @Test func aRelativeCliPathHintsTheInstallWithAnAbsoluteOne() {
        #expect(
            HookInstall.relativeCliPathError("bin/directa")
                == WireError(
                    code: .usage, hint: "run: directa hook install --cli-path /opt/homebrew/bin/directa",
                    message: "--cli-path must be absolute, got 'bin/directa'"))
    }

    /** The class guard: every `hint: "…"` literal in the code that builds the
        CLI's and the daemon's failures starts with `run: `. A new hint that is
        advice rather than a command fails here, so its detail goes in the
        message instead. */
    @Test func everyHintLiteralInTheCLIAndDaemonIsALiteralCommand() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources")
        let roots = ["directa", "DirectaDaemonCore", "DirectaKit/DeepLink/DeepLinkRunner.swift"]
        let advice = /hint:\s*"(?!run: )/
        var offenders: [String] = []
        for root in roots {
            let url = sources.appending(path: root)
            let files: [String]
            if root.hasSuffix(".swift") {
                files = [""]
            } else {
                let walker = try #require(FileManager.default.enumerator(atPath: url.path))
                files = walker.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
            }
            for relative in files {
                let file = relative.isEmpty ? url : url.appending(path: relative)
                let text = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where line.contains(advice) {
                    offenders.append("\(root)/\(relative):\(index + 1)")
                }
            }
        }
        #expect(offenders == [], "a hint is a literal `run: <command>`; put advice in the message")
    }
}
