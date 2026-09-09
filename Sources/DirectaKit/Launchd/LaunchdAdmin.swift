import Foundation
import os

/** launchd administration: install renders the LaunchAgent and bootstraps it;
    upgrades stage-and-rename the binary (overwriting a running signed Mach-O
    gets it SIGKILLed); restart drains, kickstarts, and re-ensures what ran.
    Shared by the CLI and the menu bar app so both can bring the daemon back. */
public enum LaunchdAdmin {
    public static let label = "dev.quantizor.directa"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
    }

    /** Menu bar app at the standard install location. When present, agent
        registration must go through SMAppService inside that process. */
    public static var applicationsAppURL: URL {
        URL(fileURLWithPath: SetupPlanner.applicationsAppPath)
    }

    public static func applicationsAppPresent() -> Bool {
        FileManager.default.fileExists(atPath: applicationsAppURL.path)
    }

    /** Ask the menu bar app to register/ensure the SMAppService agent.
        CLI processes cannot call `SMAppService.agent` (wrong `Bundle.main`).
        Prefer `-a /Applications/directa.app` so a DMG/Downloads copy with the
        same bundle id does not steal the URL. */
    @discardableResult
    public static func requestAppAgentEnsure() -> (status: Int32, output: String) {
        openDaemonControl(.ensure)
    }

    /** Ask the menu bar app to unregister the SMAppService agent. */
    @discardableResult
    public static func requestAppAgentUnregister() -> (status: Int32, output: String) {
        openDaemonControl(.unregister)
    }

    /** Ask the menu bar app to drop the agent and Start at Login. */
    @discardableResult
    public static func requestAppLaunchItemsUnregister() -> (status: Int32, output: String) {
        openDaemonControl(.unregisterAll)
    }

    @discardableResult
    private static func openDaemonControl(_ action: DaemonControlAction) -> (
        status: Int32, output: String
    ) {
        if applicationsAppPresent() {
            return shell("/usr/bin/open", ["-a", applicationsAppURL.path, action.urlString])
        }
        return shell("/usr/bin/open", [action.urlString])
    }

    /** True when launchd currently has our agent in the gui domain. */
    public static func isAgentLoaded() -> Bool {
        shell("/bin/launchctl", ["print", "\(LaunchdJobs.guiDomain)/\(label)"]).status == 0
    }

    /** Wait until launchd drops the agent after an unregister, then idle so BTM
        can drop the prior launch constraint. Returns false if the job is still
        loaded after the timeout (and a last-resort bootout); callers must not
        replace the helper in that case. */
    @discardableResult
    public static func waitUntilAgentUnloaded(
        timeoutSeconds: Double = 10,
        settleSeconds: Double = AgentRebindPolicy.settleSeconds
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline, isAgentLoaded() {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if isAgentLoaded() {
            _ = shell("/bin/launchctl", ["bootout", "\(LaunchdJobs.guiDomain)/\(label)"])
            let bootoutDeadline = Date().addingTimeInterval(3)
            while Date() < bootoutDeadline, isAgentLoaded() {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        guard !isAgentLoaded() else { return false }
        if settleSeconds > 0 {
            try? await Task.sleep(for: .seconds(settleSeconds))
        }
        return !isAgentLoaded()
    }

    /** Marker for the Applications copy: settle, then register, after a DMG
        replace that unregistered first. */
    public static func markAgentRebindNeeded(paths: DirectaPaths = DirectaPaths()) throws {
        try FileManager.default.createDirectory(
            at: paths.dataDir, withIntermediateDirectories: true)
        try AtomicFile.write(Data(), to: paths.agentRebindFile)
    }

    public static func agentRebindNeeded(paths: DirectaPaths = DirectaPaths()) -> Bool {
        FileManager.default.fileExists(atPath: paths.agentRebindFile.path)
    }

    public static func clearAgentRebindMarker(paths: DirectaPaths = DirectaPaths()) {
        try? FileManager.default.removeItem(at: paths.agentRebindFile)
    }

    /** True when launchd has the job but is waiting out ThrottleInterval
        (`minimum runtime` defaults to 10s) after a failed spawn. */
    public static func agentSpawnScheduled() -> Bool {
        LaunchdJobs.loadAgentStatus()?.state?.contains("spawn scheduled") == true
    }

    public static func pollHello(paths: DirectaPaths, timeoutSeconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError: Error = WireError(code: .daemonUnreachable, message: "daemon never answered")
        while Date() < deadline {
            do {
                let client = DaemonClient(socketPath: paths.socketPath)
                _ = try await client.request(
                    .daemonInfo, params: WireEmpty(), expecting: DaemonInfo.self)
                return
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        throw lastError
    }

    /** True when `directa daemon stop` left the deliberate-stop marker. Auto
        bootstrap honors it; an explicit Start clears it. */
    public static func deliberatelyStopped(paths: DirectaPaths = DirectaPaths()) -> Bool {
        FileManager.default.fileExists(atPath: paths.stoppedIntentFile.path)
    }

    /** First executable `ddirecta` among `extraCandidates`, then argv0 sibling,
        `~/.local/bin/ddirecta`, and the Application Support install path. */
    public static func resolveDaemonBinary(extraCandidates: [URL] = []) -> URL? {
        var candidates = extraCandidates
        /** Resolve symlinks first: invoked through a Homebrew shim, argv0 is
            `<brew prefix>/bin/directa`, whose sibling `ddirecta` does not exist,
            while the resolved path sits next to the real `ddirecta` in the bundle
            or install directory. */
        let arg0 = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(arg0.deletingLastPathComponent().appending(path: "ddirecta"))
        candidates.append(SetupPlanner.installedDaemonSiblingURL())
        candidates.append(DirectaPaths().daemonBinaryDir.appending(path: "ddirecta"))
        let fm = FileManager.default
        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    /** Auto-bootstrap: only against the default socket (never a test override),
        never past a deliberate-stop marker. Prefers the Applications app's
        SMAppService path when present; otherwise kickstarts/installs the
        legacy home LaunchAgent. */
    @discardableResult
    public static func attemptBootstrap(
        paths: DirectaPaths = DirectaPaths(),
        extraDaemonCandidates: [URL] = [],
        forceLegacy: Bool = false
    ) async -> Bool {
        guard ProcessInfo.processInfo.environment["DIRECTA_SOCKET"] == nil else { return false }
        guard !deliberatelyStopped(paths: paths) else { return false }
        /** With the app installed it owns registration, so a silent socket is
            answered by waiting, never by installing a second job. Falling through
            to the legacy path here wrote `~/Library/LaunchAgents` back whenever a
            command landed inside launchd's respawn throttle, leaving two jobs
            competing for one label and socket. The wait clears that throttle. */
        if !forceLegacy, applicationsAppPresent() {
            try? writeAgentPath(paths: paths)
            _ = requestAppAgentEnsure()
            return (try? await pollHello(paths: paths, timeoutSeconds: 12)) != nil
        }
        if FileManager.default.fileExists(atPath: plistURL.path) {
            return (try? await start(paths: paths)) != nil
        }
        guard let binary = resolveDaemonBinary(extraCandidates: extraDaemonCandidates) else {
            return false
        }
        return (try? await install(daemonBinary: binary, paths: paths, forceLegacy: true)) != nil
    }

    /** Explicit user start: clears the stop marker, then kickstarts or installs. */
    public static func startOrInstall(
        paths: DirectaPaths = DirectaPaths(),
        extraDaemonCandidates: [URL] = [],
        forceLegacy: Bool = false
    ) async throws {
        try? FileManager.default.removeItem(at: paths.stoppedIntentFile)
        if !forceLegacy, applicationsAppPresent() {
            try writeAgentPath(paths: paths)
            _ = requestAppAgentEnsure()
            try await pollHello(paths: paths, timeoutSeconds: 12)
            return
        }
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try await start(paths: paths)
            return
        }
        guard let binary = resolveDaemonBinary(extraCandidates: extraDaemonCandidates) else {
            throw WireError(
                code: .internalError,
                hint: "run: make install  (or open the setup panel from the DMG)",
                message: "no LaunchAgent and no ddirecta binary found to install")
        }
        _ = try await install(daemonBinary: binary, paths: paths, forceLegacy: true)
    }

    /** Install (or upgrade) the agent. When `/Applications/directa.app` exists
        and `forceLegacy` is false, asks the app to register via SMAppService
        (correct Bundle.main). Otherwise writes the home LaunchAgent.

        Same bounce contract as restart either way: capture what is running,
        drain, swap binary + bootstrap, re-ensure. The daemon's recoverAtStartup
        is the reboot path; install cannot rely on it alone because a pre-feature
        state.json may lack resumeOnBoot, and the CLI already knows the live
        names from status. */
    @discardableResult
    public static func install(
        daemonBinary: URL, paths: DirectaPaths, forceLegacy: Bool = false
    ) async throws -> [(
        project: String, name: String
    )] {
        let client = DaemonClient(socketPath: paths.socketPath)
        let runningServers = await captureActiveServers(client: client)
        /** Drain through the daemon FIRST: bootout's own kill can outrun the
            SIGTERM drain and orphan server trees mid-escalation. */
        _ = try? await client.request(.daemonShutdown, params: WireEmpty(), expecting: WireEmpty.self)
        for _ in 0..<50 where FileManager.default.fileExists(atPath: paths.socketPath) {
            if (try? await DaemonClient(socketPath: paths.socketPath)
                .request(.daemonInfo, params: WireEmpty(), expecting: DaemonInfo.self)) == nil
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? FileManager.default.removeItem(at: paths.stoppedIntentFile)

        if !forceLegacy, applicationsAppPresent() {
            try writeAgentPath(paths: paths)
            /** Leave any legacy home plist for the app to migrate on ensure. */
            _ = requestAppAgentEnsure()
            do {
                try await pollHello(paths: paths, timeoutSeconds: 10)
            } catch {
                /** The app owns registration, so the usual reason for silence is
                    an unapproved background item. Say that instead of a timeout. */
                throw WireError(
                    code: .daemonUnreachable,
                    hint: "open \"x-apple.systempreferences:com.apple.LoginItems-Settings.extension\"",
                    message:
                        "asked \(SetupPlanner.applicationsAppPath) to start ddirecta, but it never answered. If macOS is waiting for permission, turn on quantizor/directa in System Settings > General > Login Items & Extensions, or run: directa daemon install --legacy")
            }
            await reensure(runningServers, paths: paths)
            return runningServers
        }

        let fm = FileManager.default
        try fm.createDirectory(at: paths.daemonBinaryDir, withIntermediateDirectories: true)
        let destination = paths.daemonBinaryDir.appending(path: "ddirecta")
        /** Stage-and-rename: never cp over a running signed binary. */
        let staged = paths.daemonBinaryDir.appending(path: ".ddirecta.staged-\(getpid())")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: daemonBinary, to: staged)
        _ = try fm.replaceItemAt(destination, withItemAt: staged)
        let plist = renderPlist(daemonPath: destination.path, paths: paths)
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(plist.utf8).write(to: plistURL)
        try? fm.removeItem(at: paths.stoppedIntentFile)
        _ = shell("/bin/launchctl", ["bootout", "\(LaunchdJobs.guiDomain)/\(label)"])
        let bootstrap = shell("/bin/launchctl", ["bootstrap", "\(LaunchdJobs.guiDomain)", plistURL.path])
        /** A concurrent session bootstrapping first reports already-bootstrapped;
            the socket poll below is the actual success signal. */
        if bootstrap.status != 0, !bootstrap.output.contains("already bootstrapped"),
            !bootstrap.output.contains("Bootstrap failed: 5: Input/output error")
        {
            throw WireError(
                code: .internalError,
                hint: "run: launchctl bootstrap \(LaunchdJobs.guiDomain) \(plistURL.path)",
                message: "launchctl bootstrap failed (\(bootstrap.status)): \(bootstrap.output)")
        }
        try await pollHello(paths: paths)
        await reensure(runningServers, paths: paths)
        return runningServers
    }

    /** Tear down launchd + SMAppService. `loginItem` also drops Start at Login;
        `--agent-only` (cask upgrade) leaves that preference alone. Waits for
        launchd to drop the agent instead of a fixed sleep, then boots out and
        removes any leftover home plist. */
    public static func uninstall(loginItem: Bool = false, paths: DirectaPaths, purge: Bool) async {
        let client = DaemonClient(socketPath: paths.socketPath)
        _ = try? await client.request(.daemonShutdown, params: WireEmpty(), expecting: WireEmpty.self)
        if applicationsAppPresent() {
            if loginItem {
                _ = requestAppLaunchItemsUnregister()
            } else {
                _ = requestAppAgentUnregister()
            }
            _ = await waitUntilAgentUnloaded()
        }
        _ = shell("/bin/launchctl", ["bootout", "\(LaunchdJobs.guiDomain)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        if purge {
            try? FileManager.default.removeItem(at: paths.dataDir)
            try? FileManager.default.removeItem(at: paths.logsDir)
        }
    }

    public static func start(paths: DirectaPaths) async throws {
        try? FileManager.default.removeItem(at: paths.stoppedIntentFile)
        try? writeAgentPath(paths: paths)
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            throw WireError(
                code: .internalError,
                hint: "run: directa daemon install",
                message: "no LaunchAgent installed at \(plistURL.path)")
        }
        let result = shell("/bin/launchctl", ["kickstart", "\(LaunchdJobs.guiDomain)/\(label)"])
        if result.status != 0 {
            _ = shell("/bin/launchctl", ["bootstrap", "\(LaunchdJobs.guiDomain)", plistURL.path])
        }
        try await pollHello(paths: paths)
    }

    /** Drain, kickstart -k, re-ensure what was running: "servers bounce, then
        come back" is the restart contract. */
    @discardableResult
    public static func restart(paths: DirectaPaths) async throws -> [(project: String, name: String)] {
        let client = DaemonClient(socketPath: paths.socketPath)
        let runningServers = await captureActiveServers(client: client)
        try? FileManager.default.removeItem(at: paths.stoppedIntentFile)
        let result = shell("/bin/launchctl", ["kickstart", "-k", "\(LaunchdJobs.guiDomain)/\(label)"])
        if result.status != 0 {
            throw WireError(
                code: .internalError,
                hint: "run: directa daemon install",
                message: "launchctl kickstart failed (\(result.status)): \(result.output)")
        }
        try await pollHello(paths: paths)
        await reensure(runningServers, paths: paths)
        return runningServers
    }

    public static func captureActiveServers(client: DaemonClient) async -> [(
        project: String, name: String
    )] {
        guard
            let all = try? await client.request(
                .serverStatus, params: ProjectParams(project: ""), expecting: ServerListResult.self)
        else { return [] }
        return all.servers
            .filter { $0.phase == .running || $0.phase == .starting || $0.phase == .unhealthy }
            .map { (project: $0.project, name: $0.server) }
    }

    public static func reensure(
        _ servers: [(project: String, name: String)], paths: DirectaPaths
    ) async {
        let fresh = DaemonClient(socketPath: paths.socketPath)
        for server in servers {
            _ = try? await fresh.request(
                .serverEnsure,
                params: EnsureParams(name: server.name, project: server.project, timeoutSeconds: 60),
                expecting: EnsureResult.self)
        }
    }

    public static func launchdState() -> String {
        launchdState(
            from: shell("/bin/launchctl", ["print", "\(LaunchdJobs.guiDomain)/\(label)"]))
    }

    public static func launchdState(from result: (status: Int32, output: String)) -> String {
        if result.status != 0 { return "not bootstrapped" }
        let status = LaunchdJobs.parseAgentPrint(result.output)
        if let state = status.state { return "state = \(state)" }
        if let pid = status.pid { return "pid = \(pid)" }
        return "bootstrapped"
    }

    /** Floor PATH for sealed in-bundle LaunchAgent plists. Dynamic user PATH
        lives in `agent.path` and is applied by the daemon at start. */
    public static let pathFloor =
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /** How long a shell profile gets to finish before the capture gives up and
        falls back to `pathFloor`. Sourcing a file the user wrote means directa
        does not control how long it takes, and a profile that waits on the
        network or on a terminal that is not there would otherwise hang the app
        at launch. Generous by the standards of the same probe elsewhere: VS Code
        allows 10 seconds by default, JetBrains 20. Measured locally at about
        1.2s, so this is roughly ten times the real cost. */
    public static let pathCaptureTimeoutSeconds = 12.0

    /** The PATH the user actually has, so launchd children can find the tools
        the user installed; launchd agents otherwise get a minimal PATH. Goes
        stale after a Homebrew migration, which doctor surfaces via daemon.info.

        `.zshrc` is sourced explicitly because `-lc` is a login but NON
        interactive shell, so zsh runs `.zshenv`, `.zprofile` and `.zlogin` and
        skips `.zshrc` entirely. That is where most tools put themselves: on the
        machine this was measured, `-lc` alone missed `~/.local/bin` (so a server
        directa spawned could not run `directa`), plus pnpm, conda, gcloud and the
        rest. Sourcing it produces byte-identical output to an interactive login
        shell and costs less, without running an interactive session, so rc files
        that gate prompts and completions on interactivity stay skipped.

        Errors from the source are discarded rather than checked: a machine with
        no `.zshrc` is ordinary, and the fallback is the login-only PATH, which
        is what this returned before.

        Do not measure this from a terminal. A shell started from a shell
        inherits its parent's PATH, so `zsh -lc 'echo $PATH'` looks complete
        there and is missing entries under launchd, where there is no parent to
        inherit from. Use `env -i HOME=$HOME PATH=/usr/bin:/bin ...` to see what
        the daemon really gets.

        zsh is hardcoded on purpose. It is the macOS default and the tools that
        solve this elsewhere pick the user's shell from `$SHELL` or `getpwuid`,
        which would also mean branching the invocation per shell family, since
        fish has no login/interactive split and csh rejects these flags. That
        buys nothing until a directa user is on another shell, so it waits for
        one rather than being built on speculation. A bash or fish user gets the
        login-only PATH here, which degrades rather than breaks. */
    public static func capturedPath() -> String {
        /** Built, not inherited, so the answer is the same whoever asks. A child
            shell inherits its parent's environment, so this returned the user's
            full PATH when the CLI called it from a terminal and a much shorter
            one when the app called it under launchd, and whichever binary
            happened to write `agent.path` last decided what every spawned server
            got.

            Overriding PATH alone is not enough, which is worth stating because
            it is the obvious half-fix: an rc file can read any variable, and
            tools that initialize themselves idempotently go quiet when they see
            their own. Measured here, inheriting `CONDA_SHLVL` and `CONDA_EXE`
            made conda's hook decide it had already run, so its directory was
            missing from the captured PATH while every other entry was present.
            Only these four are set, being what a login shell can rely on. */
        let environment = [
            /** Set so a profile can tell this apart from a real session and skip
                whatever needs a terminal. VS Code and the JetBrains IDEs both
                publish one for the same purpose; ours is documented in the
                README so it is worth guarding against. */
            "DIRECTA_RESOLVING_ENVIRONMENT": "1",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LOGNAME": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "USER": NSUserName(),
        ]
        let result = shell(
            "/bin/zsh", ["-lc", #"source "$HOME/.zshrc" >/dev/null 2>&1; echo $PATH"#],
            environment: environment, timeoutSeconds: pathCaptureTimeoutSeconds)
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? pathFloor : path
    }

    /** Persist the login-shell PATH for the daemon to merge at start. */
    public static func writeAgentPath(
        _ path: String = capturedPath(), paths: DirectaPaths = DirectaPaths()
    ) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = trimmed.isEmpty ? pathFloor : trimmed
        try AtomicFile.write(Data(payload.utf8), to: paths.agentPathFile)
    }

    public static func readAgentPath(paths: DirectaPaths = DirectaPaths()) -> String? {
        guard let data = try? Data(contentsOf: paths.agentPathFile),
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return text
    }

    /** Apply the persisted PATH into this process before spawning children. */
    public static func applyAgentPathToProcess(paths: DirectaPaths = DirectaPaths()) {
        guard let path = readAgentPath(paths: paths) else { return }
        setenv("PATH", path, 1)
    }

    /** LaunchAgent plist for CLI-only installs. AssociatedBundleIdentifiers is
        a best-effort BTM hint; Login Items naming for the app path comes from
        SMAppService + the responsible app's CFBundleDisplayName. Legacy plists
        still bake PATH; the daemon also reads agent.path so both stay in sync. */
    public static func renderPlist(daemonPath: String, paths: DirectaPaths) -> String {
        let resolvedPath: String
        do {
            try writeAgentPath(paths: paths)
            resolvedPath = readAgentPath(paths: paths) ?? capturedPath()
        } catch {
            resolvedPath = capturedPath()
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AssociatedBundleIdentifiers</key>
            <array>
                <string>dev.quantizor.directa.app</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>\(resolvedPath)</string>
            </dict>
            <key>ExitTimeOut</key>
            <integer>60</integer>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(daemonPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardErrorPath</key>
            <string>\(paths.daemonLog.path)</string>
            <key>StandardOutPath</key>
            <string>\(paths.daemonLog.path)</string>
        </dict>
        </plist>
        """
    }

    @discardableResult
    /** `environment` nil inherits this process's, which is what most callers
        want. Pass one to make the child's answer independent of who asked.

        `timeoutSeconds` nil waits forever, which is right for a command directa
        controls end to end. Pass one for anything that runs a file the user
        wrote: a shell profile can prompt, wait on the network, or expect a
        terminal that is not there, and waiting forever for it is how a menu bar
        app hangs at launch with nothing on screen explaining why. */
    public static func shell(
        _ path: String, _ arguments: [String], environment: [String: String]? = nil,
        timeoutSeconds: Double? = nil
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        /** Drained on another thread because the timeout path below waits on
            termination first, and a read to EOF on this thread would block until
            the child closed the pipe, which is the thing being timed out. The
            untimed path could read inline as it always did; it shares this one
            so both return output the same way. */
        let collected = OSAllocatedUnfairLock(initialState: Data())
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            collected.withLock { $0 = data }
            drained.signal()
        }
        /** Installed before `run()`, not after: a child that exits in the window
            between `run()` returning and a later assignment is already terminated
            when the handler is set, and Foundation does not fire terminationHandler
            for an already-dead process. The timeout path below would then wait out
            its full ceiling and SIGKILL a pid the kernel may have recycled, and the
            PATH capture that rides this would silently fall back to `pathFloor`. */
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            drained.signal()
            return (status: -1, output: String(describing: error))
        }
        guard let timeoutSeconds else {
            process.waitUntilExit()
            drained.wait()
            return (
                status: process.terminationStatus,
                output: String(decoding: collected.withLock { $0 }, as: UTF8.self)
            )
        }
        if exited.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            /** SIGKILL rather than SIGTERM: this is already the path where the
                child ignored its chance to finish, and a profile blocked on a
                read will not act on a term either. */
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
            return (status: -1, output: "")
        }
        drained.wait()
        return (
            status: process.terminationStatus,
            output: String(decoding: collected.withLock { $0 }, as: UTF8.self)
        )
    }
}
