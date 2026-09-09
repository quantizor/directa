import DirectaKit
import Foundation
import ServiceManagement

/** SMAppService registration for the in-bundle LaunchAgent.
    Must run inside the app process: `SMAppService.agent(plistName:)` resolves
    the plist relative to `Bundle.main`. Nonisolated: setup runs off the main
    actor and Service Management is thread-safe for these calls. */
enum AgentService {
    nonisolated static let plistName = "dev.quantizor.directa.plist"

    /** Why registration could not finish. `needsApproval` is not a malfunction:
        macOS registered the job and is waiting for the user to switch it on, so
        callers must say so rather than retry or fall back to another install. */
    enum Failure: Error, LocalizedError, Sendable {
        case missingPlist(String)
        case needsApproval

        var errorDescription: String? {
            switch self {
            case .missingPlist(let name):
                return
                    "This copy of directa.app is missing \(name). Reinstall from the DMG or run make app."
            case .needsApproval:
                return
                    "macOS is waiting for you to allow directa to run in the background. Turn on quantizor/directa in System Settings > General > Login Items & Extensions."
            }
        }
    }

    private nonisolated static var agent: SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    nonisolated static var status: SMAppService.Status { agent.status }

    /** Status by name: the raw values are easy to misread in a log line
        (`enabled` is 1, `requiresApproval` is 2). */
    nonisolated static var statusDescription: String {
        switch agent.status {
        case .enabled: "enabled"
        case .notFound: "not found"
        case .notRegistered: "not registered"
        case .requiresApproval: "requires approval"
        @unknown default: "unknown"
        }
    }

    /** True when this process ships the in-bundle LaunchAgents plist. */
    nonisolated static var bundleHasAgentPlist: Bool {
        let url = Bundle.main.bundleURL
            .appending(path: "Contents/Library/LaunchAgents")
            .appending(path: plistName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /** Register the agent. Writes agent.path first so the daemon inherits the
        login-shell PATH after start. Registering often lands in
        `requiresApproval`, which reads as success from `register()` alone, so the
        status is re-read afterwards and reported as `Failure.needsApproval`. */
    nonisolated static func register() throws {
        guard bundleHasAgentPlist else { throw Failure.missingPlist(plistName) }
        try LaunchdAdmin.writeAgentPath()
        migrateLegacyHomeAgent()
        if agent.status != .enabled {
            /** Registering an already-registered job throws; the status check
                above plus this tolerance keeps re-launches idempotent. */
            do {
                try agent.register()
            } catch {
                if agent.status != .requiresApproval { throw error }
            }
        }
        if agent.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            throw Failure.needsApproval
        }
    }

    /** Unregister then register: required after the helper binary or plist
        changes inside the bundle (SDK guidance), and the only way to reload a
        job that is registered but not running.

        Ad-hoc resigns change the helper CDHash. Registering (or KeepAlive
        respawning) before BTM drops the prior launch constraint produces
        `SIGKILL (Code Signature Invalid)` / Launch Constraint Violation. So
        unregister always waits for launchd + a BTM settle before register. */
    nonisolated static func reregister() async throws {
        try LaunchdAdmin.writeAgentPath()
        migrateLegacyHomeAgent()
        if agent.status == .enabled || agent.status == .requiresApproval {
            try? await agent.unregister()
            let unloaded = await LaunchdAdmin.waitUntilAgentUnloaded()
            if !unloaded {
                DirectaLog.app.error(
                    "agent still loaded after unregister; register may hit a Launch Constraint Violation")
            }
        }
        try agent.register()
        if agent.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            throw Failure.needsApproval
        }
    }

    /** Unregistering is a deliberate stand-down, so it records the stop intent
        first: without the marker the recovery poll sees an unreachable daemon a
        moment later and registers the agent right back. */
    nonisolated static func unregister(paths: DirectaPaths = DirectaPaths()) async throws {
        try AtomicFile.write(Data(), to: paths.stoppedIntentFile)
        migrateLegacyHomeAgent()
        guard agent.status != .notRegistered else { return }
        try await agent.unregister()
        DirectaLog.app.info("agent unregistered on request")
    }

    /** Drop Start at Login. Idempotent when it was never on. */
    nonisolated static func unregisterLoginItem() {
        let item = SMAppService.mainApp
        guard item.status != .notRegistered else { return }
        try? item.unregister()
        DirectaLog.app.info("Start at Login unregistered on request")
    }

    /** Agent plus Start at Login. Full uninstall uses this; `--agent-only` does
        not, so a Homebrew upgrade keeps the user's login preference. */
    nonisolated static func unregisterAllLaunchItems(paths: DirectaPaths = DirectaPaths()) async throws {
        try await unregister(paths: paths)
        unregisterLoginItem()
    }

    /** Deep-link / recovery entry: register, then wait until the socket answers.
        `Failure.needsApproval` short-circuits the wait, since no amount of
        polling starts a job the user has not switched on.

        A status of `enabled` does not prove the job is loaded. Escalate fast when
        launchd has nothing; only wait out ThrottleInterval (~10s) when the job is
        present but still spawning after a bad first attempt. */
    nonisolated static func ensureRunning(paths: DirectaPaths = DirectaPaths()) async throws {
        try? FileManager.default.removeItem(at: paths.stoppedIntentFile)
        try register()
        try await waitForHelloOrEscalate(paths: paths, escalate: true)
    }

    /** At launch: keep the agent registered when this bundle can host it,
        unless the user deliberately stopped the daemon. Copies running from a
        DMG or Downloads skip registration: they share a bundle id with
        `/Applications/directa.app`, so registering from there races the relocate
        handoff and can unregister or bind BTM to the volume path.

        A post-replace `agent.rebind` marker means the DMG installer already
        unregistered. The first register often dies on an ad-hoc CDHash mismatch;
        KeepAlive's in-place LWCR repair fails (`smd` error 22), so a brief hello
        miss forces unregister+register instead of waiting out ThrottleInterval. */
    nonisolated static func ensureAtLaunchIfNeeded() async {
        guard bundleHasAgentPlist else {
            DirectaLog.app.info("no in-bundle LaunchAgent; leaving the daemon to the CLI")
            return
        }
        if SetupPlanner.isRunningOutsideApplications(bundlePath: Bundle.main.bundlePath) {
            DirectaLog.app.info(
                "running outside Applications; deferring agent register until relocated")
            return
        }
        let paths = DirectaPaths()
        let rebind = LaunchdAdmin.agentRebindNeeded(paths: paths)
        guard
            AgentRebindPolicy.shouldRegisterAtLaunch(
                deliberatelyStopped: LaunchdAdmin.deliberatelyStopped(paths: paths),
                rebindNeeded: rebind)
        else {
            DirectaLog.app.info(
                "skipping agent register: ddirecta was stopped on purpose (Start in the menu clears that)")
            return
        }
        do {
            if rebind {
                try? FileManager.default.removeItem(at: paths.stoppedIntentFile)
            }
            try register()
            DirectaLog.app.info("agent register at launch: \(statusDescription)")
            if AgentRebindPolicy.shouldForceReregisterAfterHelloMiss(rebindNeeded: rebind) {
                if (try? await LaunchdAdmin.pollHello(
                    paths: paths, timeoutSeconds: AgentRebindPolicy.postReplaceHelloSeconds))
                    == nil
                {
                    DirectaLog.app.info(
                        "post-replace spawn missed (ad-hoc LWCR repair is a dead end); re-registering")
                    try await reregister()
                    /** Not `try`: a miss here used to throw straight out of
                        launch, which abandoned the sequence and left the daemon
                        to whatever recovery poll came next, a whole cooldown
                        later. Falling through instead keeps the escalation in
                        this call, where the marker is still set and the next
                        step is already written. */
                    if (try? await LaunchdAdmin.pollHello(
                        paths: paths,
                        timeoutSeconds: AgentRebindPolicy.postReregisterHelloSeconds)) == nil
                    {
                        try await waitForHelloOrEscalate(paths: paths, escalate: true)
                    }
                }
                LaunchdAdmin.clearAgentRebindMarker(paths: paths)
            } else {
                await bounceStaleDaemon(paths: paths)
                try await waitForHelloOrEscalate(paths: paths, escalate: true)
            }
        } catch Failure.needsApproval {
            DirectaLog.app.error("agent awaiting approval in Login Items")
        } catch {
            DirectaLog.app.error("agent register at launch: \(error.localizedDescription)")
        }
    }

    /** Wait for the socket, escalating only when needed.
        Fast path (~2s): covers a clean RunAtLoad spawn.
        Missing job: re-register immediately (register was a no-op on a ghost).
        Spawn scheduled / silent job: wait out launchd's ~10s throttle before
        another unregister+register, which would reset that window. */
    nonisolated static func waitForHelloOrEscalate(
        paths: DirectaPaths = DirectaPaths(), escalate: Bool
    ) async throws {
        if (try? await LaunchdAdmin.pollHello(paths: paths, timeoutSeconds: 2)) != nil {
            return
        }
        guard agent.status == .enabled else {
            throw WireError(code: .daemonUnreachable, message: "ddirecta never answered")
        }
        guard !LaunchdAdmin.deliberatelyStopped(paths: paths) else { return }

        if !LaunchdAdmin.isAgentLoaded() {
            guard escalate else { return }
            DirectaLog.app.info("agent enabled but not loaded; re-registering")
            try await reregister()
            try await LaunchdAdmin.pollHello(paths: paths, timeoutSeconds: 12)
            return
        }

        /** KeepAlive's in-place LWCR repair after a Launch Constraint Violation
            fails for ad-hoc helpers (`Unable to update LWCR with smd: 22`) and
            only burns another ThrottleInterval. Prefer a fresh register. */
        if LaunchdAdmin.agentRebindNeeded(paths: paths)
            || LaunchdAdmin.agentSpawnScheduled()
        {
            if LaunchdAdmin.agentRebindNeeded(paths: paths) {
                DirectaLog.app.info(
                    "post-replace agent still silent; re-registering instead of waiting on LWCR repair")
                guard escalate else { return }
                try await reregister()
                try await LaunchdAdmin.pollHello(paths: paths, timeoutSeconds: 12)
                LaunchdAdmin.clearAgentRebindMarker(paths: paths)
                return
            }
            DirectaLog.app.info("agent spawn scheduled (launchd throttle); waiting")
        }
        if (try? await LaunchdAdmin.pollHello(paths: paths, timeoutSeconds: 12)) != nil {
            return
        }
        guard escalate else { return }
        DirectaLog.app.info("agent still silent after throttle window; re-registering")
        try await reregister()
        try await LaunchdAdmin.pollHello(paths: paths, timeoutSeconds: 12)
    }

    /** Restart ddirecta when the running one predates this app. Installing a new
        version replaces the helper on disk, but the old process keeps running the
        old inode and `register()` is a no-op while the service stays registered,
        so without this an upgrade silently leaves the previous daemon in charge.

        The test is the reported version, which does not move between rebuilds of
        the same version during development: use `directa daemon restart` there. */
    nonisolated static func bounceStaleDaemon(paths: DirectaPaths = DirectaPaths()) async {
        let client = AppDaemon.client
        guard
            let info = try? await client.request(
                .daemonInfo, params: WireEmpty(), expecting: DaemonInfo.self),
            info.daemonVersion != DirectaVersion.version
        else { return }
        DirectaLog.app.info(
            "ddirecta v\(info.daemonVersion) predates this app (v\(DirectaVersion.version)); restarting it")
        do {
            try await reregister()
            try await waitForHelloOrEscalate(paths: paths, escalate: false)
        } catch {
            DirectaLog.app.error("could not restart the stale daemon: \(error.localizedDescription)")
        }
    }

    /** Reopen the Login Items pane for the popover's approval affordance. */
    nonisolated static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /** Drop a leftover `~/Library/LaunchAgents` job so BTM does not show two rows. */
    nonisolated static func migrateLegacyHomeAgent() {
        let plist = LaunchdAdmin.plistURL
        guard FileManager.default.fileExists(atPath: plist.path) else { return }
        _ = LaunchdAdmin.shell(
            "/bin/launchctl", ["bootout", "\(LaunchdJobs.guiDomain)/\(LaunchdAdmin.label)"])
        try? FileManager.default.removeItem(at: plist)
        DirectaLog.app.info("migrated away from legacy home LaunchAgent")
    }
}
