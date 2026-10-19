import Foundation

/** What a hook invocation reads from the daemon: one status list for the
    project, and the latest err lines of one server. Behind a protocol so the
    compare-and-store below runs in a test over scripted answers. */
public protocol HookDaemonReading: Sendable {
    /** Nil when the daemon did not answer. */
    func status(project: String) async -> ServerListResult?

    /** Nil when the log read itself failed. An empty array is a real tail. */
    func errorLines(project: String, server: String) async -> [String]?
}

/** The compare-and-store every after-tool and session-start hook runs: take
    the agent's record lock, load its record, ask the daemon, say only what
    changed, and save the record back. The CLI supplies the daemon reads and
    writes the answer in its harness's envelope. */
public enum HookSpeaker {
    public struct Answer: Equatable, Sendable {
        public var newErrorLines: Bool
        public var text: String?

        public init(newErrorLines: Bool, text: String?) {
            self.newErrorLines = newErrorLines
            self.text = text
        }
    }

    /** Where and for whom one invocation speaks. */
    public struct Request: Sendable {
        public var directory: URL
        public var fileKey: String
        public var harness: AgentContext.Harness
        public var project: String

        public init(directory: URL, fileKey: String, harness: AgentContext.Harness, project: String) {
            self.directory = directory
            self.fileKey = fileKey
            self.harness = harness
            self.project = project
        }
    }

    /** `boundary` is read from the record already on disk. `amend` may update
        harness fields on that record before it is saved, including when the
        picture did not change. A failed status read stores nothing and answers
        empty. The record is read, compared, and saved under one lock, so tool
        calls that finish together take turns instead of all loading the same
        stored picture and all speaking. */
    public static func speak(
        _ request: Request,
        reads: any HookDaemonReading,
        boundary: (HookConversationRecord?) -> Bool,
        amend: ((inout HookConversationRecord, Answer, Bool) -> Void)? = nil
    ) async -> Answer {
        await HookSnapshotStore.exclusively(fileKey: request.fileKey, directory: request.directory) {
            await compare(request, reads: reads, boundary: boundary, amend: amend)
        }
    }

    private static func compare(
        _ request: Request,
        reads: any HookDaemonReading,
        boundary: (HookConversationRecord?) -> Bool,
        amend: ((inout HookConversationRecord, Answer, Bool) -> Void)?
    ) async -> Answer {
        let stored = HookSnapshotStore.load(fileKey: request.fileKey, directory: request.directory)
        let isBoundary = boundary(stored)
        guard let list = await reads.status(project: request.project) else {
            return Answer(newErrorLines: false, text: nil)
        }
        /** An untrusted project is invisible to the hook, so its servers read
            as new once trust is recorded. */
        let servers = list.trusted == true ? list.servers : []
        let picture = HookChange.picture(of: servers)
        let lines = await errorLines(
            request, reads: reads, stored: stored, picture: picture, boundary: isBoundary)
        let outcome = HookChange.outcome(
            stored: stored, project: request.project, picture: picture, errorLines: lines,
            summary: AgentContext.render(list: list, harness: request.harness), boundary: isBoundary)
        var record = outcome.record
        let answer = Answer(newErrorLines: outcome.newErrorLines, text: outcome.text)
        amend?(&record, answer, isBoundary)
        if record != stored {
            HookSnapshotStore.save(record, fileKey: request.fileKey, directory: request.directory)
        }
        return answer
    }

    /** The latest err lines of each server that just entered a bad state, and
        no log read for anything else. */
    private static func errorLines(
        _ request: Request,
        reads: any HookDaemonReading,
        stored: HookConversationRecord?,
        picture: HookServerPicture,
        boundary: Bool
    ) async -> [String: [String]] {
        guard !boundary else { return [:] }
        var lines: [String: [String]] = [:]
        for name in HookChange.enteringBad(
            stored: stored?.projects?[request.project]?.picture, current: picture)
        {
            if let fetched = await reads.errorLines(project: request.project, server: name) {
                lines[name] = fetched
            }
        }
        return lines
    }
}
