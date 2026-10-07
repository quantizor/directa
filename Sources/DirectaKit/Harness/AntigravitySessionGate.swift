import Foundation

/** The last `initialNumSteps` seen for one Antigravity conversation. A later
    message whose count is lower is the harness shortening that conversation,
    which is when the context block has to be injected again. The file is a
    cache: losing it costs one extra injection, and the next message rewrites it. */
public struct AntigravitySessionState: Codable, Equatable, Sendable {
    public var lastInitialNumSteps: Int

    public init(lastInitialNumSteps: Int) {
        self.lastInitialNumSteps = lastInitialNumSteps
    }
}

/** On-disk half of `AntigravitySessionState`. One file per conversation under
    `$TMPDIR/directa-antigravity-hook`, so the OS tmp reaper is the expiry.
    `DIRECTA_ANTIGRAVITY_HOOK_STATE_DIR` relocates the directory for tests. */
public enum AntigravitySessionGate {
    public static let fallbackKey = "nosession"
    public static let maxKeyLength = 128
    public static let stateDirEnvironmentKey = "DIRECTA_ANTIGRAVITY_HOOK_STATE_DIR"
    public static let stateDirName = "directa-antigravity-hook"

    public static func directory(environment: [String: String]) -> URL {
        if let override = environment[stateDirEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let tmp = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: tmp).appending(path: stateDirName)
    }

    /** A conversation id becomes one path component. Anything outside the
        filename alphabet is dropped, the result is capped, and an empty result
        or a relative component (`.` / `..`) shares the `nosession` file rather
        than escaping the directory. */
    public static func sessionKey(_ raw: String?) -> String {
        let trimmed = (raw ?? "").replacing(/[^A-Za-z0-9._-]/) { _ in "" }
        let sliced = String(trimmed.prefix(maxKeyLength))
        if sliced.isEmpty || sliced == "." || sliced == ".." { return fallbackKey }
        return sliced
    }

    /** Nil when this conversation has no record yet. A missing, unreadable, or
        corrupt file is the same answer: inject again. */
    public static func load(sessionKey: String, directory: URL) -> AntigravitySessionState? {
        AtomicFile.loadDefensively(
            AntigravitySessionState.self, from: directory.appending(path: sessionKey))
    }

    public static func save(_ state: AntigravitySessionState, sessionKey: String, directory: URL) {
        let url = directory.appending(path: sessionKey)
        guard let data = try? JSONCoding.encoder().encode(state) else { return }
        try? AtomicFile.write(data, to: url)
    }
}
