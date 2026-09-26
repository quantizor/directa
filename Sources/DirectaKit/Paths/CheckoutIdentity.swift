import Foundation

/** Git checkout identity helpers for sibling port rebind, the worktree
    display label, and project resolution. The linked-worktree checks read
    files; the rest shell out to `git`. Failures return nil so non-git
    projects keep the pre-coexistence path. */
public enum CheckoutIdentity {
    /** Absolute path to the shared git directory, or nil if not a git checkout. */
    public static func gitCommonDir(project: String) -> String? {
        git(project: project, args: ["rev-parse", "--git-common-dir"]).map {
            canonicalProjectPath(absoluteGitPath($0, project: project))
        }
    }

    /** True when this path is a linked worktree: its `.git` file points into a
        repository's `worktrees/` directory, or (for a path below a checkout
        root) git-dir differs from common-dir. A submodule also has a `.git`
        file, pointing into `modules/`, and is not a linked worktree. Main
        checkouts and non-git trees return false. */
    public static func isLinkedWorktree(project: String) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: project).appending(path: ".git").path, isDirectory: &isDir),
            !isDir.boolValue
        {
            return linkedWorktreeGitDir(of: project) != nil
        }
        guard let common = gitCommonDir(project: project),
            let gitDir = git(project: project, args: ["rev-parse", "--git-dir"]).map({
                canonicalProjectPath(absoluteGitPath($0, project: project))
            })
        else { return false }
        return common != gitDir
    }

    /** The worktree admin directory a `.git` file at the root of `directory`
        points to, when that file makes `directory` a linked worktree; nil for
        a `.git` directory, a submodule's `.git` file, or no `.git` at all.
        Git keeps a linked worktree's admin directory at
        `<common-dir>/worktrees/<id>`, holding a `commondir` file; a
        submodule's git directory sits at `<git-dir>/modules/<name>` (inside
        a worktree, `.../worktrees/<id>/modules/<name>`, and a name may itself
        contain slashes) and is a full repository with no `commondir`. So
        neither the path alone nor the parent directory's name settles it;
        the `worktrees` parent plus the `commondir` file does. File reads
        only, no git subprocess, because project resolution runs in every
        session hook. */
    public static func linkedWorktreeGitDir(of directory: String) -> String? {
        let gitFile = URL(fileURLWithPath: directory).appending(path: ".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitFile.path, isDirectory: &isDir), !isDir.boolValue,
            let contents = try? String(contentsOf: gitFile, encoding: .utf8),
            let line = contents.split(whereSeparator: \.isNewline).first,
            line.hasPrefix("gitdir:")
        else { return nil }
        let pointer = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !pointer.isEmpty else { return nil }
        let gitDir = URL(
            fileURLWithPath: pointer, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)
        ).standardizedFileURL
        guard gitDir.deletingLastPathComponent().lastPathComponent == "worktrees",
            FileManager.default.fileExists(atPath: gitDir.appending(path: "commondir").path)
        else { return nil }
        return gitDir.path
    }

    /** The main checkout a linked worktree belongs to: the directory holding
        the common `.git` directory that the admin directory's `commondir`
        names. Nil when `directory` is not a linked worktree or its
        repository is bare. */
    public static func mainCheckout(ofLinkedWorktree directory: String) -> String? {
        guard let gitDir = linkedWorktreeGitDir(of: directory),
            let pointer = try? String(
                contentsOf: URL(fileURLWithPath: gitDir).appending(path: "commondir"), encoding: .utf8)
        else { return nil }
        let common = URL(
            fileURLWithPath: pointer.trimmingCharacters(in: .whitespacesAndNewlines),
            relativeTo: URL(fileURLWithPath: gitDir, isDirectory: true)
        ).standardizedFileURL
        guard common.lastPathComponent == ".git" else { return nil }
        return canonicalProjectPath(common.deletingLastPathComponent().path)
    }

    /** Display identity of a linked worktree: its sanitized checkout-directory
        label and the main checkout's slug, shown together ("myproj · review")
        so a worktree server reads as part of the project family in status,
        Spotlight, and the app. The label never touches the host: every
        `*.localhost` name resolves to loopback, so the host disambiguated
        nothing, and a third-level subdomain breaks apps whose auth config
        (callback allow lists, cookie domains, trusted origins) pins one
        origin. Sibling checkouts are told apart by the rebound port instead.
        Nil for main checkouts and non-git trees. */
    public static func worktreeDisplay(project: String) -> WorktreeDisplay? {
        guard isLinkedWorktree(project: project),
            let listing = git(project: project, args: ["worktree", "list", "--porcelain"])
        else { return nil }
        /** `git worktree list` names the primary worktree first. */
        guard let line = listing.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix("worktree ") })
        else { return nil }
        let main = canonicalProjectPath(String(line.dropFirst("worktree ".count)))
        return WorktreeDisplay(
            label: sanitizeLabel((project as NSString).lastPathComponent),
            mainProject: ProjectConfigLoader.defaultSlug(project: main))
    }

    /** Stable free-port candidate near the declared port for sibling rebind. */
    public static func siblingPortCandidate(declared: Int, project: String) -> Int {
        let offset = (Int(DirectaPaths.hash8(project).prefix(4), radix: 16) ?? 1) % 1000
        let base = declared + offset + 1
        return min(max(base, 1024), 65_000)
    }

    public static func sanitizeLabel(_ raw: String) -> String {
        raw.lowercased()
            .replacing(/[^a-z0-9-]+/) { _ in "-" }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func shareCommonDir(_ a: String, _ b: String) -> Bool {
        guard let left = gitCommonDir(project: a), let right = gitCommonDir(project: b) else {
            return false
        }
        return left == right
    }

    private static func absoluteGitPath(_ path: String, project: String) -> String {
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: project).appending(path: path).path
    }

    /** How long one git read may run before it is terminated and answers nil.
        The async forms share a fixed-width lane, so a git that never returns
        would otherwise hold a lane thread, and every project's reads queued
        behind it, forever. */
    static let gitTimeoutSeconds: Double = 10

    /** Blocks the calling thread until git exits. stderr goes to /dev/null
        (only stdout answers the caller, and a git warning must not mix in),
        which leaves one pipe, read to end of file on this same thread before
        the wait: a git that fills the stdout buffer never blocks on a write
        nothing is reading, and no helper thread is needed. */
    static func git(
        project: String, args: [String], timeoutSeconds: Double = gitTimeoutSeconds
    ) -> String? {
        DaemonActivity.shared.measure(.git, label: "git \(args.joined(separator: " ")) in \(project)") {
            gitUnmeasured(project: project, args: args, timeoutSeconds: timeoutSeconds)
        }
    }

    private static func gitUnmeasured(project: String, args: [String], timeoutSeconds: Double) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: project)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        /** Terminating git closes its end of the pipe, which ends the read
            below. A timer, not a thread: nothing waits for it. */
        let deadline = DispatchWorkItem { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeoutSeconds, execute: deadline)
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return text
    }
}

/** A linked worktree's checkout-directory label and its main checkout's slug. */
public struct WorktreeDisplay: Equatable, Sendable {
    public var label: String
    public var mainProject: String

    public init(label: String, mainProject: String) {
        self.label = label
        self.mainProject = mainProject
    }
}

/** The forms async code calls: each runs its synchronous namesake on
    `BlockingLane.repository`, so a git stuck on a slow or locked repository
    parks one lane thread instead of a cooperative-pool thread. Swift picks
    these over the synchronous forms in any async context, and the synchronous
    forms remain for the CLI and app code that is not on the pool. */
extension CheckoutIdentity {
    public static func gitCommonDir(project: String) async -> String? {
        await BlockingLane.repository.run { gitCommonDir(project: project) }
    }

    public static func isLinkedWorktree(project: String) async -> Bool {
        await BlockingLane.repository.run { isLinkedWorktree(project: project) }
    }

    public static func shareCommonDir(_ a: String, _ b: String) async -> Bool {
        await BlockingLane.repository.run { shareCommonDir(a, b) }
    }

    public static func worktreeDisplay(project: String) async -> WorktreeDisplay? {
        await BlockingLane.repository.run { worktreeDisplay(project: project) }
    }
}
