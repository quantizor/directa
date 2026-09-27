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
        checkouts and non-git trees return false. Only a path with no `.git`
        of its own runs git. */
    public static func isLinkedWorktree(project: String) -> Bool {
        if linkedWorktreeGitDir(of: project) != nil { return true }
        guard !hasGitEntry(project) else { return false }
        return isInsideLinkedWorktree(project: project)
    }

    /** Whether `directory` has a `.git` of either kind at its root: a main
        checkout's directory, or a worktree's or submodule's file. */
    private static func hasGitEntry(_ directory: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: directory).appending(path: ".git").path)
    }

    /** The subdirectory case: one git read prints both directories, and they
        differ only inside a linked worktree. */
    private static func isInsideLinkedWorktree(project: String) -> Bool {
        guard let output = git(project: project, args: ["rev-parse", "--git-common-dir", "--git-dir"])
        else { return false }
        let lines = output.split(whereSeparator: \.isNewline).map {
            canonicalProjectPath(absoluteGitPath(String($0), project: project))
        }
        guard lines.count == 2 else { return false }
        return lines[0] != lines[1]
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
        guard let common = linkedWorktreeGitDir(of: directory).flatMap(commonDir(ofAdminDir:)),
            common.lastPathComponent == ".git"
        else { return nil }
        return canonicalProjectPath(common.deletingLastPathComponent().path)
    }

    /** The common git directory a worktree admin directory's `commondir` file
        names. */
    private static func commonDir(ofAdminDir gitDir: String) -> URL? {
        guard let pointer = try? String(
            contentsOf: URL(fileURLWithPath: gitDir).appending(path: "commondir"), encoding: .utf8)
        else { return nil }
        return URL(
            fileURLWithPath: pointer.trimmingCharacters(in: .whitespacesAndNewlines),
            relativeTo: URL(fileURLWithPath: gitDir, isDirectory: true)
        ).standardizedFileURL
    }

    /** Display identity of a linked worktree: its sanitized checkout-directory
        label and the main checkout's slug, shown together ("myproj · review")
        so a worktree server reads as part of the project family in status,
        Spotlight, and the app. The label never touches the host: every
        `*.localhost` name resolves to loopback, so the host disambiguated
        nothing, and a third-level subdomain breaks apps whose auth config
        (callback allow lists, cookie domains, trusted origins) pins one
        origin. Sibling checkouts are told apart by the rebound port instead.
        Nil for main checkouts and non-git trees. A worktree root answers from
        its admin files; only a directory below one runs git. */
    public static func worktreeDisplay(project: String) -> WorktreeDisplay? {
        let main: String
        if let gitDir = linkedWorktreeGitDir(of: project) {
            guard let common = commonDir(ofAdminDir: gitDir) else { return nil }
            /** Git's own rule for the main worktree's path (worktree.c,
                get_main_worktree): the common directory with a trailing
                `/.git` removed, which leaves a bare repository's own path. */
            main = common.lastPathComponent == ".git" ? common.deletingLastPathComponent().path : common.path
        } else {
            guard !hasGitEntry(project), isInsideLinkedWorktree(project: project),
                let listing = git(project: project, args: ["worktree", "list", "--porcelain"]),
                /** `git worktree list` names the primary worktree first. */
                let line = listing.split(separator: "\n", omittingEmptySubsequences: false)
                    .first(where: { $0.hasPrefix("worktree ") })
            else { return nil }
            main = String(line.dropFirst("worktree ".count))
        }
        return WorktreeDisplay(
            label: sanitizeLabel((project as NSString).lastPathComponent),
            mainProject: ProjectConfigLoader.defaultSlug(project: canonicalProjectPath(main)))
    }

    /** Where a sibling rebind search starts: 1 to 1000 ports above the
        declared one, fixed per checkout path, so a checkout keeps landing on
        the same port. Kept above the privileged ports and at or below the top
        of `SiblingRebind.range`. */
    public static func siblingPortCandidate(declared: Int, project: String) -> Int {
        let offset = (Int(DirectaPaths.hash8(project).prefix(4), radix: 16) ?? 1) % 1000
        let base = declared + offset + 1
        return min(max(base, 1024), SiblingRebind.range.upperBound)
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

    /** Blocks the calling thread until git exits, or until its timeout, when
        git and anything it started that still holds its output are killed.
        stderr goes to /dev/null: only stdout answers the caller, and a git
        warning must not mix in. */
    static func git(
        project: String, args: [String], timeoutSeconds: Double = gitTimeoutSeconds
    ) -> String? {
        let outcome = HelperCommand.run(
            "/usr/bin/git", args, currentDirectory: project, includeStderr: false,
            timeoutSeconds: timeoutSeconds)
        guard case .exited(status: 0, let output) = outcome else { return nil }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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

    public static func shareCommonDir(_ a: String, _ b: String) async -> Bool {
        await BlockingLane.repository.run { shareCommonDir(a, b) }
    }

    public static func worktreeDisplay(project: String) async -> WorktreeDisplay? {
        await BlockingLane.repository.run { worktreeDisplay(project: project) }
    }
}
