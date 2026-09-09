import DirectaKit
import Foundation
import Observation
import UserNotifications

/** The app's one daemon connection. connect() short-circuits on a live fd and
    reconnects on error, so every polling loop (the 2s status refresh, the log
    and timeline panes) holds this instead of paying a full socket
    create/connect/hello handshake per tick. */
enum AppDaemon {
    nonisolated static let client = DaemonClient(socketPath: DirectaPaths().socketPath)
}

/** How the popover orders its project groups. Persisted in UserDefaults so the
    choice survives relaunches. */
enum ProjectSortOrder: String, CaseIterable, Identifiable {
    case alphabetical
    case frequentlyUsed
    case recentlyUsed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alphabetical: "A to Z"
        case .frequentlyUsed: "Frequently used"
        case .recentlyUsed: "Recently used"
        }
    }
}

/** A 7-day access journal: every interaction that opens or controls a server
    appends a timestamped entry for that project. Powers both "frequently used"
    (count-weighted, most first) and "recently used" (latest first) ordering.
    Entries older than the window are pruned on write so the store stays small. */
@Observable
final class ProjectAccessLog {
    static let shared = ProjectAccessLog()

    /** Accesses within this window count toward "frequently used". */
    static let windowSeconds: TimeInterval = 7 * 24 * 3600

    private static let defaultsKey = "project access log"
    private static let maxEntries = 400

    /** project path -> epoch seconds of each recorded access, newest last. */
    private var log: [String: [TimeInterval]] = [:]

    init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: [TimeInterval]] ?? [:]
        log = raw
        prune()
    }

    /** Record an interaction for the project that owns `projectPath`. */
    func record(projectPath: String) {
        let now = Date().timeIntervalSince1970
        log[projectPath, default: []].append(now)
        prune()
        persist()
    }

    /** Most-accessed-first within the rolling window; ties break by recency. */
    func frequencyScore(projectPath: String) -> Int {
        let cutoff = Date().timeIntervalSince1970 - Self.windowSeconds
        return (log[projectPath] ?? []).count { $0 >= cutoff }
    }

    func lastAccess(projectPath: String) -> TimeInterval {
        log[projectPath]?.last ?? 0
    }

    private func prune() {
        let cutoff = Date().timeIntervalSince1970 - Self.windowSeconds
        for (path, stamps) in log {
            var kept = stamps.filter { $0 >= cutoff }
            if kept.count > Self.maxEntries { kept = Array(kept.suffix(Self.maxEntries)) }
            if kept.isEmpty { log.removeValue(forKey: path) } else { log[path] = kept }
        }
    }

    private func persist() {
        UserDefaults.standard.set(log, forKey: Self.defaultsKey)
    }
}

/** The app's single source of truth: polls the daemon over the local socket
    (2s; polling is restart-safe and deletes the reconnect problem a push
    subscription would carry), groups servers by project, derives the ambient
    icon state, and posts crash notifications from the event feed. */
@Observable
final class DaemonModel {
    /** Bumped on system theme change so the baked menu bar label re-renders. */
    var appearanceTick = 0
    var daemonReachable = false
    /** True while the daemon answers but is still bringing supervised servers
        back, which is a busy daemon rather than a missing one. */
    var daemonRestoring = false
    /** Last failed recovery, surfaced in the popover so a dead daemon is never
        a dead end. */
    var daemonRecoveryError: String?
    /** True while a bootstrap/kickstart is in flight, so the row can say so and
        the poll does not stack attempts. */
    var daemonRecovering = false
    /** macOS registered the background agent but is waiting for the user to
        switch it on. Nothing the app can retry, so the popover asks for the
        approval instead of looping. */
    var daemonNeedsApproval = false
    /** `directa daemon stop` wrote the deliberate-stop marker: the app offers
        Start instead of resurrecting the daemon behind the user's back. */
    var daemonStoppedOnPurpose = false
    var projects: [ProjectGroup] = []
    /** Newest release when one is available, for the popover footer. Nil when up
        to date, unchecked, or the check is switched off in Settings. */
    var updateStatus: UpdateStatus?

    private var lastRecoveryAttempt: Date?
    private var updateTask: Task<Void, Never>?

    struct ProjectGroup: Identifiable {
        var id: String { path }
        let name: String
        let path: String
        let servers: [ServerStatus]

        /** One home for the group's display name. A linked worktree reads as
            "myproj · review" so its relation to the main project survives
            everywhere the name flows: menu bar, dashboard, and Spotlight
            titles. A main checkout keeps its directory name. */
        static func displayName(path: String, servers: [ServerStatus]) -> String {
            guard let status = servers.first,
                let worktree = status.worktree,
                let main = status.mainProject
            else { return (path as NSString).lastPathComponent }
            return "\(main) · \(worktree)"
        }
    }

    /** Worst phase across every server, for the menu bar glyph. */
    enum AmbientState {
        case attention
        case busy
        case quiet

        init(servers: [ServerStatus]) {
            if servers.contains(where: { $0.phase == .crashed || $0.phase == .failed || $0.phase == .unhealthy }) {
                self = .attention
            } else if servers.contains(where: { $0.phase == .starting || $0.phase == .stopping }) {
                self = .busy
            } else {
                self = .quiet
            }
        }
    }

    var ambient: AmbientState {
        AmbientState(servers: projects.flatMap(\.servers))
    }

    /** Presence counts for the collapsed menu bar label. */
    var attentionCount: Int {
        projects.flatMap(\.servers)
            .count { $0.phase == .crashed || $0.phase == .failed || $0.phase == .unhealthy }
    }

    var busyCount: Int {
        projects.flatMap(\.servers).count { $0.phase == .starting || $0.phase == .stopping }
    }

    var runningCount: Int {
        projects.flatMap(\.servers).count { $0.phase == .running }
    }

    /** Order projects per the user's sort choice. Usage orders are computed
        from the shared access log; alphabetical is stable by name. */
    func sortedProjects(_ order: ProjectSortOrder) -> [ProjectGroup] {
        switch order {
        case .alphabetical:
            return projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .frequentlyUsed:
            let log = ProjectAccessLog.shared
            return projects.sorted {
                let a = log.frequencyScore(projectPath: $0.path)
                let b = log.frequencyScore(projectPath: $1.path)
                if a != b { return a > b }
                let ra = log.lastAccess(projectPath: $0.path)
                let rb = log.lastAccess(projectPath: $1.path)
                if ra != rb { return ra > rb }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .recentlyUsed:
            let log = ProjectAccessLog.shared
            return projects.sorted {
                let a = log.lastAccess(projectPath: $0.path)
                let b = log.lastAccess(projectPath: $1.path)
                if a != b { return a > b }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    private var lastEventCheck = Date()
    private var notificationsReady = false
    private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        requestNotificationPermission()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appearanceTick += 1
            }
        }
        /** Launch-time registration runs behind the same in-flight flag and
            cooldown as recovery. Left outside them, the 2s poll sees the socket
            still silent inside launchd's respawn throttle and fires a second
            unregister + register on top of the first. */
        Task { [weak self] in
            guard let self else { return }
            daemonRecovering = true
            await AgentService.ensureAtLaunchIfNeeded()
            lastRecoveryAttempt = Date()
            daemonRecovering = false
            await refresh()
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        /** Update polling on its own slow cadence, honoring the Settings toggle.
            The app owns the cadence; doctor reads the same cache. */
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForUpdates()
                try? await Task.sleep(for: .seconds(UpdateCheck.defaultMaxAge))
            }
        }
    }

    /** Refresh the update cache when the preference allows, publishing the result
        for the popover footer. Clears the banner when the check is off, so turning
        it off in Settings takes effect without a relaunch. */
    func checkForUpdates() async {
        guard UpdatePreference.enabled else {
            updateStatus = nil
            return
        }
        let status = await UpdateCheck.refresh()
        updateStatus = (status?.updateAvailable == true) ? status : nil
    }

    func refresh() async {
        let client = AppDaemon.client
        do {
            let all = try await client.request(
                .serverStatus, params: ProjectParams(project: ""), expecting: ServerListResult.self)
            daemonReachable = true
            let grouped = Dictionary(grouping: all.servers, by: \.project)
            projects = grouped.keys.sorted().map { path in
                let servers = (grouped[path] ?? []).sorted { $0.server < $1.server }
                return ProjectGroup(
                    name: ProjectGroup.displayName(path: path, servers: servers),
                    path: path,
                    servers: servers)
            }
            SpotlightIndexer.sync(projects: projects)
            daemonRecoveryError = nil
            daemonRestoring = false
            lastRecoveryAttempt = nil
            daemonStoppedOnPurpose = false
            await surfaceCrashNotifications(client: client)
        } catch let error as WireError where error.code == .daemonStarting {
            /** A restoring daemon is answering, so it is reachable: treating the
                refusal as a dead socket emptied the popover and fired agent
                recovery at a daemon that was working, across every install,
                restart and login. The server list is held rather than cleared,
                since it is about to be correct again. */
            daemonReachable = true
            daemonRestoring = true
            daemonStoppedOnPurpose = false
        } catch {
            daemonReachable = false
            daemonRestoring = false
            projects = []
            daemonStoppedOnPurpose = LaunchdAdmin.deliberatelyStopped()
            await recoverDaemonIfNeeded()
        }
    }

    /** Bring the daemon back on its own after a crash or a failed relaunch.
        Skipped when the user stopped it on purpose (their intent wins) and
        rate-limited so a permanently broken install does not spin. */
    private func recoverDaemonIfNeeded() async {
        let decision = DaemonRecoveryPolicy.decide(
            reachable: daemonReachable,
            stoppedOnPurpose: daemonStoppedOnPurpose,
            recovering: daemonRecovering,
            lastAttempt: lastRecoveryAttempt)
        guard decision == .recover else { return }
        lastRecoveryAttempt = Date()
        daemonRecovering = true
        let recovered = await recoverAgent()
        daemonRecovering = false
        if recovered {
            daemonRecoveryError = nil
            await refresh()
        } else if daemonNeedsApproval {
            daemonRecoveryError = AgentService.Failure.needsApproval.localizedDescription
        } else {
            daemonRecoveryError = "could not start ddirecta automatically"
        }
    }

    /** Prefer SMAppService inside this app process; fall back to the legacy home
        LaunchAgent only when this bundle cannot host an agent. Falling back while
        approval is pending would write back the very `~/Library/LaunchAgents`
        job the migration removed, and Login Items would name it `ddirecta` again. */
    private func recoverAgent() async -> Bool {
        if AgentService.bundleHasAgentPlist {
            do {
                try await AgentService.ensureRunning()
                daemonNeedsApproval = false
                return true
            } catch AgentService.Failure.needsApproval {
                daemonNeedsApproval = true
                DirectaLog.app.error("agent awaiting approval in Login Items")
                return false
            } catch {
                DirectaLog.app.error("SMAppService recover failed: \(error.localizedDescription)")
                return false
            }
        }
        return await LaunchdAdmin.attemptBootstrap(
            extraDaemonCandidates: Self.bundledDaemonCandidates(), forceLegacy: true)
    }

    /** Explicit Start from the popover: clears a deliberate-stop marker, so it
        also works when auto recovery is intentionally standing down. */
    func startDaemon() {
        guard !daemonRecovering else { return }
        Task {
            daemonRecovering = true
            daemonRecoveryError = nil
            do {
                if AgentService.bundleHasAgentPlist {
                    try await AgentService.ensureRunning()
                } else {
                    try await LaunchdAdmin.startOrInstall(
                        extraDaemonCandidates: Self.bundledDaemonCandidates(),
                        forceLegacy: true)
                }
                daemonNeedsApproval = false
                daemonStoppedOnPurpose = false
            } catch AgentService.Failure.needsApproval {
                daemonNeedsApproval = true
                daemonRecoveryError = AgentService.Failure.needsApproval.localizedDescription
            } catch let error as WireError {
                daemonRecoveryError = error.message
            } catch {
                daemonRecoveryError = error.localizedDescription
            }
            daemonRecovering = false
            await refresh()
        }
    }

    /** The version-matched ddirecta inside this app bundle's Resources, which is
        the right install source when no LaunchAgent exists yet. */
    private static func bundledDaemonCandidates() -> [URL] {
        guard
            let url = Bundle.main.url(
                forResource: SetupPlanner.daemonBinaryName, withExtension: nil)
        else { return [] }
        return [url]
    }

    func startServer(_ server: ServerStatus) {
        ProjectAccessLog.shared.record(projectPath: server.project)
        Task {
            let client = AppDaemon.client
            _ = try? await client.request(
                .serverEnsure,
                params: EnsureParams(name: server.server, project: server.project, timeoutSeconds: 60),
                expecting: EnsureResult.self)
            await refresh()
        }
    }

    func stopServer(_ server: ServerStatus) {
        ProjectAccessLog.shared.record(projectPath: server.project)
        Task {
            let client = AppDaemon.client
            _ = try? await client.request(
                .serverStop,
                params: ServerTargetParams(name: server.server, project: server.project),
                expecting: ServerResult.self)
            await refresh()
        }
    }

    func restartServer(_ server: ServerStatus) {
        ProjectAccessLog.shared.record(projectPath: server.project)
        Task {
            let client = AppDaemon.client
            /** One request rather than a stop followed by an ensure: the pair
                leaves the server down if the ensure is refused, and lets another
                session's ensure land in between. */
            _ = try? await client.request(
                .serverRestart,
                params: RestartParams(
                    names: [server.server], project: server.project, timeoutSeconds: 60),
                expecting: GroupResult.self)
            await refresh()
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationsReady = granted
            }
        }
    }

    /** Crash notifications ride the event feed so nothing is missed between
        polls; lastEventCheck advances to the newest seen event. */
    private func surfaceCrashNotifications(client: DaemonClient) async {
        guard notificationsReady else { return }
        guard
            let feed = try? await client.request(
                .eventsQuery,
                params: EventsQueryParams(since: lastEventCheck),
                expecting: EventsQueryResult.self)
        else { return }
        /** The cursor advances once, after the whole batch. Advancing it inside
            the loop made the loop's own `where` clause filter on a value the
            loop had just moved: event timestamps are millisecond-resolution, so
            two servers crashing together share an `at` and the second was
            dropped, permanently, since the cursor had already passed it. */
        let fresh = feed.events.filter { $0.at > lastEventCheck }
        lastEventCheck = fresh.reduce(lastEventCheck) { max($0, $1.at) }
        for event in fresh {
            guard CrashNotificationPolicy.shouldNotify(kind: event.kind, detail: event.detail)
            else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(event.server) \(event.kind.rawValue)"
            content.body = event.detail.map { "\($0) · \((event.project as NSString).lastPathComponent)" }
                ?? (event.project as NSString).lastPathComponent
            content.categoryIdentifier = AppDeepLinkDispatch.serverAlertCategory
            content.userInfo = [
                AppDeepLinkDispatch.userInfoProject: event.project,
                AppDeepLinkDispatch.userInfoServer: event.server,
            ]
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "directa-\(event.server)-\(event.at.timeIntervalSince1970)",
                content: content,
                trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
            DirectaLog.app.info("notified \(event.kind.rawValue) \(event.server)")
        }
    }
}
