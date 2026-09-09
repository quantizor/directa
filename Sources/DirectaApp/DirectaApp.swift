import AppKit
import CoreSpotlight
import DirectaKit
import ServiceManagement
import SwiftUI
import UserNotifications

/** One selectable row in the popover's keyboard model. A server row or one of
    its heads; `actions` are the Left/Right targets in display order. */
struct KeyNavRow: Identifiable {
    enum Kind {
        case head(project: String, server: String, head: String)
        case server(project: String, server: String)
    }
    enum Action: String {
        case open
        case pin
        case restart
        case start
        case stop
    }
    let kind: Kind
    let actions: [Action]

    var id: String {
        switch kind {
        case .head(let project, let server, let head): "\(project)::\(server)::\(head)"
        case .server(let project, let server): "\(project)::\(server)"
        }
    }
}

/** Arrow-key navigation for the popover. The `.window` MenuBarExtra does not
    give SwiftUI buttons arrow-key focus, so a local key monitor owns Up/Down
    (row), Left/Right (action within a row), Return (activate), and Escape
    (clear). The highlighted cell is published; rows render it as a soft ring.
    Installed only while the popover is open so it never eats keys elsewhere. */
@Observable
final class KeyNavModel {
    var selection: (rowID: KeyNavRow.ID, action: KeyNavRow.Action)?

    /** The live model, injected by MenuContent so controls resolve against the
        same daemon connection the rows render from. */
    var daemon: DaemonModel?

    private var monitor: Any?
    private var projects: [DaemonModel.ProjectGroup] = []
    private var rows: [KeyNavRow] = []

    /** Whether `rowID`'s `action` is the highlighted cell, for row rendering. */
    func isHighlighted(_ rowID: KeyNavRow.ID, _ action: KeyNavRow.Action) -> Bool {
        selection?.rowID == rowID && selection?.action == action
    }

    /** Rebuild the flat row list from the currently visible (filtered) tree. */
    func sync(projects: [DaemonModel.ProjectGroup]) {
        self.projects = projects
        var next: [KeyNavRow] = []
        for project in projects {
            for server in project.servers {
                var actions: [KeyNavRow.Action] = [.open]
                switch server.phase {
                case .running, .unhealthy, .starting:
                    actions += [.restart, .stop]
                case .stopped, .crashed, .failed, .stopping:
                    actions += [.start]
                }
                next.append(KeyNavRow(kind: .server(project: project.path, server: server.server), actions: actions))
                if let heads = server.heads {
                    for name in heads.keys.sorted() {
                        next.append(KeyNavRow(
                            kind: .head(project: project.path, server: server.server, head: name),
                            actions: [.open, .pin]))
                    }
                }
            }
        }
        rows = next
        /** Drop a selection that scrolled out of existence (phase flip changed
            a row's action set, or the filter hid it). */
        if let sel = selection, !rows.contains(where: { $0.id == sel.rowID && $0.actions.contains(sel.action) }) {
            selection = nil
        }
    }

    func installIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    func tearDown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        selection = nil
    }

    /** Returns true when the key was consumed. */
    private func handle(_ event: NSEvent) -> Bool {
        guard !rows.isEmpty else { return false }
        switch event.keyCode {
        case 125: move(1); return true   // down
        case 126: move(-1); return true  // up
        case 123: stepAction(-1); return true // left
        case 124: stepAction(1); return true  // right
        case 36, 76: activate(); return true  // return / keypad enter
        case 53: selection = nil; return false // escape: pass through to close
        default: return false
        }
    }

    private func move(_ delta: Int) {
        guard let sel = selection, let index = rows.firstIndex(where: { $0.id == sel.rowID }) else {
            select(row: delta > 0 ? rows.first : rows.last)
            return
        }
        select(row: rows[(index + delta + rows.count) % rows.count], preferring: sel.action)
    }

    private func stepAction(_ delta: Int) {
        guard let sel = selection, let row = rows.first(where: { $0.id == sel.rowID }),
            let index = row.actions.firstIndex(of: sel.action)
        else { return }
        selection = (row.id, row.actions[(index + delta + row.actions.count) % row.actions.count])
    }

    private func select(row: KeyNavRow?, preferring action: KeyNavRow.Action? = nil) {
        guard let row else { selection = nil; return }
        let chosen = action.flatMap { row.actions.contains($0) ? $0 : nil } ?? row.actions.first ?? .open
        selection = (row.id, chosen)
    }

    private func server(_ project: String, _ name: String) -> ServerStatus? {
        projects.first { $0.path == project }?.servers.first { $0.server == name }
    }

    /** Run the highlighted action against the live model so a stale row never
        fires a control on a server that vanished. */
    private func activate() {
        guard let sel = selection, let row = rows.first(where: { $0.id == sel.rowID }) else { return }
        switch row.kind {
        case .server(let project, let name):
            guard let server = server(project, name) else { return }
            switch sel.action {
            case .open:
                ProjectAccessLog.shared.record(projectPath: project)
                SpotlightIndexer.noteOpened(identifier: "\(project)::\(name)")
                if let url = server.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
            case .start: daemon?.startServer(server)
            case .stop: daemon?.stopServer(server)
            case .restart: daemon?.restartServer(server)
            case .pin: break
            }
        case .head(let project, let name, let head):
            guard let server = server(project, name), let url = server.heads?[head] else { return }
            switch sel.action {
            case .open:
                ProjectAccessLog.shared.record(projectPath: project)
                SpotlightIndexer.noteOpened(identifier: "\(project)::\(name)::\(head)")
                if let parsed = URL(string: url) { NSWorkspace.shared.open(parsed) }
            case .pin:
                let identifier = "\(project)::\(name)::\(head)"
                let wasPinned = HeadPins.shared.isPinned(project: project, server: name, head: head)
                HeadPins.shared.toggle(project: project, server: name, head: head)
                if !wasPinned { SpotlightIndexer.noteOpened(identifier: identifier) }
            default: break
            }
        }
    }
}

/** Handles Spotlight, `directa://` URL opens, and notification action taps. A
    background (LSUIElement) app receives these through the app delegate, not a
    scene view: the popover's view tree may not exist when Launch Services or
    Spotlight launches us. */
final class AppActivationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        /** GetURL first, even on the volume copy: the installer and
            `/Applications/directa.app` share a bundle id, so Launch Services can
            deliver `directa://daemon/unregister` here. The handler forwards that
            URL to the Applications copy, which owns SMAppService. A second copy
            of the same bundle path still stands down immediately after. */
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
        guard !SetupPerformer.quitIfTwinIsRunning() else { return }
        /** The volume copy is a headless installer: no menu bar item, no
            notifications, just the setup window shown here. SwiftUI still
            renders the MenuBarExtra label view even with the item hidden, so the
            label-hosted opener would also fire; it guards itself against the volume
            copy (SetupWindowOpener) so setup is not presented twice. */
        if SetupPerformer.runningFromMountedVolume() {
            InstallerWindowController.shared.present()
            return
        }
        /** MenuBarExtra is not a window TAL counts as "in use", so AppKit's
            automatic termination will quit an LSUIElement extra that looks idle,
            especially after a memory-pressure pass. Start at Login does not
            relaunch mid-session. The matching Info.plist keys refuse TAL at
            Launch Services; these calls refuse it in-process. */
        ProcessInfo.processInfo.disableAutomaticTermination("menu bar extra")
        ProcessInfo.processInfo.disableSuddenTermination()
        AppFocus.installObservers()
        AppDeepLinkDispatch.registerNotificationCategories()
        UNUserNotificationCenter.current().delegate = self
    }

    @objc private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor
    ) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: raw)
        else { return }
        AppDeepLinkDispatch.run(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "directa" {
            AppDeepLinkDispatch.run(url)
        }
    }

    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        let fromSpotlight = userActivity.activityType == CSSearchableItemActionType
        let fromDonation = userActivity.activityType == SpotlightIndexer.activityType
        guard fromSpotlight || fromDonation,
            let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
            let url = SpotlightIndexer.url(forIdentifier: identifier)
        else { return false }
        SpotlightIndexer.noteOpened(identifier: identifier)
        NSWorkspace.shared.open(url)
        return true
    }

    /** MenuBarExtra is often foreground; without willPresent the SDK drops the
        banner entirely (UNUserNotificationCenter.h). Prefer .banner/.list over
        the deprecated .alert. */
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let project = info[AppDeepLinkDispatch.userInfoProject] as? String
        let server = info[AppDeepLinkDispatch.userInfoServer] as? String
        let head = info[AppDeepLinkDispatch.userInfoHead] as? String
        if let project, let server,
            let link = DeepLinkNotificationAction.link(
                actionId: response.actionIdentifier,
                projectSlug: (project as NSString).lastPathComponent,
                server: server,
                head: head)
        {
            AppDeepLinkDispatch.run(link)
        }
        completionHandler()
    }
}

/** directa.app: quiet instrument panel in the menu bar. The glyph reports
    aggregate health ambiently; the dropdown is per-project rows with tally-light
    dots; the dashboard window carries logs/timeline (its phase). Unsandboxed by
    necessity (unix socket), LSUIElement, no Dock icon. */
@main
struct DirectaApp: App {
    @NSApplicationDelegateAdaptor(AppActivationDelegate.self) private var appDelegate
    @State private var model = DaemonModel()
    @State private var setupSession = SetupSession()

    /** The DMG/volume copy runs as a pure installer: it draws no menu bar item
        (the MenuBarExtra below is not inserted for it) and presents its setup
        window through the app delegate instead, so an upgrade never shows the
        volume copy and the installed copy on the menu bar at once. */
    private let isVolumeInstaller = SetupPerformer.runningFromMountedVolume()

    /** Polling starts at launch, not first popover open: the collapsed label's
        presence dots must be live from the first frame. The installer copy has no
        menu bar UI to feed and exits after handing off, so it never polls. */
    init() {
        let launched = DaemonModel()
        if !isVolumeInstaller { launched.start() }
        _model = State(initialValue: launched)
    }

    var body: some Scene {
        /** SceneBuilder has no conditional, so the scene set is fixed and the
            installer copy hides its item via `isInserted` rather than by omitting
            the MenuBarExtra. */
        MenuBarExtra(isInserted: .constant(!isVolumeInstaller)) {
            MenuContent(model: model)
        } label: {
            /** A real child View, not inline scene content: App.body scene
                closures do not participate in Observation tracking, so counts
                read here directly would never re-render the collapsed label. */
            PresenceLabel(model: model)
                .background(SetupWindowOpener(session: setupSession))
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About directa") {
                    AboutPanel.present()
                }
            }
        }

        Window("directa", id: "dashboard") {
            DashboardView(model: model)
        }
        .defaultSize(width: 860, height: 560)

        Window("directa Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 520)

        Window(setupSession.migration || setupSession.replacingApplicationsApp
            ? "Upgrade directa" : "Install directa", id: "setup") {
            SetupPanel(
                cliOwnedByBrew: setupSession.cliOwnedByBrew,
                installAppToApplications: setupSession.installAppToApplications,
                migration: setupSession.migration,
                offers: setupSession.offers,
                pathWarning: setupSession.pathWarning,
                replacingApplicationsApp: setupSession.replacingApplicationsApp
            ) {
                setupSession.shouldPresent = false
                SetupWindowCloser.close()
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 420)
    }
}

/** The system About panel (directa > About directa). Name is passed explicitly
    so the panel does not pick up `CFBundleDisplayName` (`quantizor/directa`,
    which is for Login Items). Version and copyright come from Info.plist;
    the MIT line is credits, the slot the panel already has for that. */
enum AboutPanel {
    static func present() {
        AppFocus.promote()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "directa",
            .credits: NSAttributedString(string: "MIT License"),
        ])
    }
}

/** Hosts the volume copy's installer window. That copy draws no menu bar item, but
    SwiftUI still renders its MenuBarExtra label view, so the label-hosted window
    opener would also fire; that opener guards itself against the volume copy, and
    the delegate presents the setup UI here directly instead. */
@MainActor
final class InstallerWindowController: NSObject, NSWindowDelegate {
    static let shared = InstallerWindowController()
    private var window: NSWindow?
    private let session = SetupSession()

    func present() {
        guard window == nil else { return }
        let hosting = NSHostingController(rootView: InstallerRootView(session: session))
        let win = NSWindow(contentViewController: hosting)
        win.title = "directa"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win
        win.identifier = NSUserInterfaceItemIdentifier("setup")
        AppFocus.promote()
        win.makeKeyAndOrderFront(nil)
    }

    /** Closing the installer window quits the volume copy, so it stops running
        from (and pinning) the mounted DMG whether the user finished setup or
        dismissed it. Without this the accessory app would keep running invisibly
        after its only window closed, and the volume would still refuse to eject. */
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

/** The volume copy's only UI. Evaluates setup on appear, shows the panel, and
    quits when there is nothing to do. It draws no menu bar item, so an upgrade
    never shows the volume copy and the installed copy on the menu bar at once;
    the installed copy, launched at the end of the handoff, is the only one with a
    tally. */
struct InstallerRootView: View {
    var session: SetupSession
    @State private var didStart = false

    var body: some View {
        Group {
            if session.shouldPresent {
                SetupPanel(
                    cliOwnedByBrew: session.cliOwnedByBrew,
                    installAppToApplications: session.installAppToApplications,
                    migration: session.migration,
                    offers: session.offers,
                    pathWarning: session.pathWarning,
                    replacingApplicationsApp: session.replacingApplicationsApp
                ) {
                    /** The panel only reaches its non-relaunching finish when there
                        was nothing to relocate; the installer copy has no reason to
                        linger. The relocating path hands off and quits itself. */
                    NSApp.terminate(nil)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing directa…").foregroundStyle(.secondary)
                }
                .frame(width: 460)
                .padding(32)
            }
        }
        .task {
            guard !didStart else { return }
            didStart = true
            await session.evaluate()
            if session.shouldPresent {
                AppFocus.promote()
                await session.refreshPathWarning()
            } else {
                /** Double-clicked from the volume but already current: do not
                    linger as a windowed, dock-less process with nothing to do. */
                NSApp.terminate(nil)
            }
        }
    }
}

struct MenuContent: View {
    @State private var contentHeight: CGFloat = 0
    @State private var filterText: String = ""
    @Environment(\.openWindow) private var openWindow
    var model: DaemonModel
    @State private var sortOrder: ProjectSortOrder = {
        ProjectSortOrder(rawValue: UserDefaults.standard.string(forKey: "project sort order") ?? "") ?? .alphabetical
    }()
    @State private var keyNav = KeyNavModel()

    private var orderedProjects: [DaemonModel.ProjectGroup] {
        model.sortedProjects(sortOrder)
    }

    private var filteredProjects: [DaemonModel.ProjectGroup] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return orderedProjects }
        return orderedProjects.compactMap { project in
            let projectMatches = FuzzyMatcher.matches(project.name, query: query)
            let matchingServers = project.servers.filter { server in
                if projectMatches { return true }
                if FuzzyMatcher.matches(server.server, query: query) { return true }
                if FuzzyMatcher.matches(server.url ?? "", query: query) { return true }
                if let heads = server.heads {
                    return heads.keys.contains { FuzzyMatcher.matches($0, query: query) } ||
                           heads.values.contains { FuzzyMatcher.matches($0, query: query) }
                }
                return false
            }
            if matchingServers.isEmpty { return nil }
            return DaemonModel.ProjectGroup(
                name: project.name, path: project.path, servers: matchingServers)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.daemonReachable {
                DaemonDownRow(model: model)
                    .padding(12)
            } else if model.projects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No servers registered")
                    Text("directa register --name myproj --cmd …")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            } else {
                let projects = filteredProjects
                ZStack(alignment: .topLeading) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if projects.isEmpty {
                                Text("No matching servers")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(projects) { project in
                                    ProjectSection(
                                        filterText: filterText, keyNav: keyNav, model: model, project: project)
                                }
                            }
                        }
                        /** Top pad = filter band so at rest nothing sits under it;
                            rows still scroll beneath the floating control. */
                        .padding(.horizontal, 12)
                        .padding(.top, FilterBox.restClearance)
                        .padding(.bottom, 12)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { measured in
                            contentHeight = measured
                        }
                    }
                    .frame(height: min(max(contentHeight, 44), 560))

                    /** Top band: sort menu floats left, filter floats right. */
                    HStack(spacing: 0) {
                        SortOrderMenu(selection: $sortOrder)
                            .onChange(of: sortOrder) { _, new in
                                UserDefaults.standard.set(new.rawValue, forKey: "project sort order")
                            }
                        Spacer(minLength: 0)
                        FilterBox(text: $filterText)
                    }
                    .padding(.top, FilterBox.topInset)
                    .padding(.leading, 8)
                    .padding(.trailing, 8)
                    .zIndex(1)
                }
            }
            if let update = model.updateStatus {
                Divider()
                UpdateFooterRow(status: update)
            }
            Divider()
            HStack(spacing: 0) {
                Button {
                    AppFocus.promote()
                    openWindow(id: "dashboard")
                } label: {
                    FooterIconLabel(systemImage: "rectangle.split.2x1", title: "Dashboard")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open the dashboard window")
                .accessibilityLabel(Text("Open dashboard"))
                /** Generous air between primary action and the settings entry. */
                Button {
                    AppFocus.promote()
                    openWindow(id: "settings")
                } label: {
                    FooterIconLabel(systemImage: "gearshape", title: "Settings")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Manage hooks, login, and updates")
                .accessibilityLabel(Text("Open settings"))
                .padding(.leading, 22)
                Spacer(minLength: 8)
                Button {
                    NSApp.terminate(nil)
                } label: {
                    FooterIconLabel(systemImage: "power", title: "Quit")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Quit directa")
                .accessibilityLabel(Text("Quit directa"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        .onAppear {
            keyNav.daemon = model
            keyNav.installIfNeeded()
            keyNav.sync(projects: filteredProjects)
        }
        .onDisappear { keyNav.tearDown() }
        /** Re-sync on any tree change the nav model cares about: servers
            appearing, the filter narrowing, or a phase flip changing a row's
            action set (start vs restart+stop). */
        .onChange(of: syncStamp) { _, _ in
            keyNav.sync(projects: filteredProjects)
        }
    }

    /** A cheap fingerprint of everything that changes the nav row set. */
    private var syncStamp: String {
        filteredProjects.flatMap { p in
            p.servers.map { "\(p.path)::\($0.server)::\($0.phase.rawValue)::\($0.heads?.count ?? 0)" }
        }.joined(separator: "|") + "?\(filterText)"
    }
}

/** Shown when the socket does not answer. The app tries to bring the daemon
    back on its own, so this states what is happening and still offers the
    manual action: a deliberate `directa daemon stop` suppresses auto recovery,
    and a failed recovery needs somewhere to report. */
struct DaemonDownRow: View {
    var model: DaemonModel

    private var message: String {
        if model.daemonRecovering { return "Starting ddirecta…" }
        if model.daemonNeedsApproval { return "directa needs your approval" }
        if model.daemonStoppedOnPurpose { return "ddirecta is stopped" }
        if model.daemonRecoveryError != nil { return "ddirecta is not running" }
        return "ddirecta is not running; restarting"
    }

    private var glyph: String {
        if model.daemonRecovering { return "bolt" }
        if model.daemonNeedsApproval { return "hand.raised" }
        return "bolt.slash"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label(message, systemImage: glyph)
                    .foregroundStyle(.secondary)
                if let error = model.daemonRecoveryError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            /** Approval is the only action that can help while the switch is
                off, so it replaces Start rather than sitting beside it. */
            if model.daemonNeedsApproval {
                Button("Open Login Items") {
                    AgentService.openLoginItemsSettings()
                }
                .buttonStyle(.borderless)
                .help("Turn on quantizor/directa in System Settings")
            } else {
                Button("Start") {
                    model.startDaemon()
                }
                .buttonStyle(.borderless)
                .disabled(model.daemonRecovering)
                .help("Start ddirecta now")
            }
        }
    }
}

struct ProjectSection: View {
    let filterText: String
    let keyNav: KeyNavModel
    var model: DaemonModel
    let project: DaemonModel.ProjectGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FuzzyMatcher.highlightedText(project.name, query: filterText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(project.servers, id: \.server) { server in
                ServerRow(filterText: filterText, keyNav: keyNav, model: model, server: server)
            }
        }
    }
}

struct ServerRow: View {
    let filterText: String
    let keyNav: KeyNavModel
    var model: DaemonModel
    let server: ServerStatus

    private var rowID: String { "\(server.project)::\(server.server)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            /** One line: dot, the descriptive address, phase, lifecycle. The
                bare server name ("dev"/"web") adds nothing the address and the
                project header don't already say, so it's folded away. */
            HStack(alignment: .center, spacing: 8) {
                TallyDot(phase: server.phase)
                /** Clicking the row opens the server's URL: the whole point of
                    the signature is a one-click browser origin. */
                Button {
                    ProjectAccessLog.shared.record(projectPath: server.project)
                    SpotlightIndexer.noteOpened(identifier: "\(server.project)::\(server.server)")
                    if let url = server.url.flatMap(URL.init(string:)) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    FuzzyMatcher.highlightedText(address, query: filterText)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(server.url == nil)
                .help(server.url ?? "no URL configured")
                .modifier(KeyNavCell(active: keyNav.isHighlighted(rowID, .open)))
                Text(server.phase.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ServerLifecycleControls(keyNav: keyNav, model: model, rowID: rowID, server: server)
            }
            /** Multi-headed servers list their surfaces as nested compact rows,
                each a direct click-to-open; pinned heads float to the top. */
            if let heads = server.heads, !heads.isEmpty {
                let pins = HeadPins.shared
                let ordered = heads.sorted { a, b in
                    let aPinned = pins.isPinned(project: server.project, server: server.server, head: a.key)
                    let bPinned = pins.isPinned(project: server.project, server: server.server, head: b.key)
                    if aPinned != bPinned { return aPinned }
                    return a.key < b.key
                }
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(ordered, id: \.key) { name, url in
                        HeadRow(
                            filterText: filterText,
                            keyNav: keyNav,
                            name: name,
                            onOpen: {
                                ProjectAccessLog.shared.record(projectPath: server.project)
                            },
                            onTogglePin: {
                                pins.toggle(project: server.project, server: server.server, head: name)
                            },
                            parentURL: server.url,
                            pinned: pins.isPinned(project: server.project, server: server.server, head: name),
                            rowID: "\(server.project)::\(server.server)::\(name)",
                            url: url
                        )
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /** The address half of the old subtitle, which is what actually identifies
                the server once the redundant name is gone. */
    private var address: String {
        if let url = server.url, let parsed = URL(string: url), let host = parsed.host {
            let port = parsed.port.map { ":\($0)" } ?? ""
            return "\(host)\(port)"
        }
        if let port = server.displayPort {
            return "port \(port)"
        }
        return server.server
    }
}

/** The keyboard-highlight ring: a quiet rounded outline around the selected
    cell, matching the instrument-panel restraint (never a filled shout). */
struct KeyNavCell: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                }
            }
    }
}

/** Start / stop / restart icon strip shared by the popover rows and the
    dashboard detail header. `reserveSlot` keeps popover rows from jumping
    when the phase swaps play for restart+stop. */
struct ServerLifecycleControls: View {
    var keyNav: KeyNavModel? = nil
    var model: DaemonModel
    /** When true, hold a blank 14pt slot so the play button lines up with stop. */
    var reserveSlot: Bool = true
    var rowID: String = ""
    let server: ServerStatus
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 8) {
            switch server.phase {
            case .running, .unhealthy, .starting:
                iconButton("arrow.clockwise", help: "Restart", action: .restart) {
                    model.restartServer(server)
                }
                iconButton("stop.fill", help: "Stop", action: .stop) {
                    model.stopServer(server)
                }
            case .stopped, .crashed, .failed, .stopping:
                if reserveSlot {
                    Color.clear.frame(width: size, height: size)
                }
                iconButton("play.fill", help: "Start", action: .start, disabled: server.phase == .stopping) {
                    model.startServer(server)
                }
            }
        }
    }

    private func iconButton(
        _ systemName: String, help: String, action: KeyNavRow.Action, disabled: Bool = false,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.85, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .disabled(disabled)
        .accessibilityLabel(Text(help))
        .modifier(KeyNavCell(active: keyNav?.isHighlighted(rowID, action) ?? false))
    }
}

/** Collapsed menu bar label: colored tally dots only (running / busy /
    attention). One AppKit 2x bitmap with renderingMode(.original); all-quiet
    is a single dim template dot so the status item does not vanish. */
struct PresenceLabel: View {
    var model: DaemonModel

    var body: some View {
        /** Read counts so Observation re-renders when the poll updates them;
            scene-level label closures alone do not track the model. */
        let attention = model.attentionCount
        let busy = model.busyCount
        let running = model.runningCount
        Image(nsImage: PresenceDots.image(
            attention: attention, busy: busy, running: running))
            .renderingMode(.original)
            .accessibilityLabel(Text(accessibilitySummary(
                attention: attention, busy: busy, running: running)))
    }

    private func accessibilitySummary(attention: Int, busy: Int, running: Int) -> String {
        var parts = ["directa"]
        if running > 0 { parts.append("\(running) running") }
        if busy > 0 { parts.append("\(busy) starting or stopping") }
        if attention > 0 { parts.append("\(attention) need attention") }
        if parts.count == 1 { parts.append("all quiet") }
        return parts.joined(separator: ", ")
    }
}

/** Menu bar presence: colored running/busy/attention pairs only. Built as one
    non-template 2x bitmap so the bar keeps color and a single Image. Quiet
    state is a single tertiary-gray dot so the item stays clickable. */
enum PresenceDots {
    private struct Key: Hashable {
        let attention: Int
        let busy: Int
        let running: Int
    }

    @MainActor private static var cache: [Key: NSImage] = [:]

    /** Mid-tones that still read after the bar's slight dimming of non-template art. */
    private static let runningColor = NSColor(calibratedRed: 0.32, green: 0.88, blue: 0.48, alpha: 1)
    private static let busyColor = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.24, alpha: 1)
    private static let attentionColor = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.38, alpha: 1)
    private static let quietColor = NSColor(calibratedWhite: 0.55, alpha: 1)

    @MainActor static func image(attention: Int, busy: Int, running: Int) -> NSImage {
        let key = Key(attention: attention, busy: busy, running: running)
        if let cached = cache[key] { return cached }

        var pairs: [(Int, NSColor)] = []
        if running > 0 { pairs.append((running, runningColor)) }
        if busy > 0 { pairs.append((busy, busyColor)) }
        if attention > 0 { pairs.append((attention, attentionColor)) }

        let scale: CGFloat = 2
        let height: CGFloat = 16
        let dot: CGFloat = 7
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let spacing: CGFloat = 5
        let pairGap: CGFloat = 2.5

        let width: CGFloat
        if pairs.isEmpty {
            width = dot
        } else {
            var w: CGFloat = 0
            for (index, pair) in pairs.enumerated() {
                if index > 0 { w += spacing }
                let textSize = NSAttributedString(
                    string: "\(pair.0)", attributes: [.font: font]
                ).size()
                w += dot + pairGap + ceil(textSize.width)
            }
            width = w
        }

        let pixelW = max(Int(ceil(width * scale)), 1)
        let pixelH = max(Int(ceil(height * scale)), 1)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.shouldAntialias = true

        if pairs.isEmpty {
            quietColor.setFill()
            let dy = (height - dot) / 2
            NSBezierPath(ovalIn: NSRect(x: 0, y: dy, width: dot, height: dot)).fill()
        } else {
            var x: CGFloat = 0
            for (index, pair) in pairs.enumerated() {
                if index > 0 { x += spacing }
                let (count, color) = pair
                color.setFill()
                let dy = (height - dot) / 2
                NSBezierPath(ovalIn: NSRect(x: x, y: dy, width: dot, height: dot)).fill()
                x += dot + pairGap
                let text = NSAttributedString(
                    string: "\(count)",
                    attributes: [
                        .font: font,
                        .foregroundColor: color,
                    ])
                let textSize = text.size()
                let ty = (height - textSize.height) / 2 - 0.5
                text.draw(at: NSPoint(x: x, y: ty))
                x += ceil(textSize.width)
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        image.isTemplate = false
        if cache.count > 32 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/** Pinned-head preference, persisted across launches (UserDefaults). Keys are
    `project::server::head`. A server rename (dev → web) orphans the old key;
    `reconcile` remaps when the project still has exactly one server that exposes
    that head, otherwise drops the dead pin. */
@Observable
final class HeadPins {
    static let shared = HeadPins()

    private static let defaultsKey = "pinned heads"
    private var pinned: Set<String>

    init() {
        pinned = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    func isPinned(project: String, server: String, head: String) -> Bool {
        pinned.contains("\(project)::\(server)::\(head)")
    }

    func toggle(project: String, server: String, head: String) {
        let key = "\(project)::\(server)::\(head)"
        if pinned.contains(key) {
            pinned.remove(key)
        } else {
            pinned.insert(key)
        }
        persist()
    }

    /** Drop or remap pins that no longer match a live head (server renames). */
    func reconcile(projects: [DaemonModel.ProjectGroup]) {
        var valid: Set<String> = []
        /** projectPath → head → [server names that expose it] */
        var byProjectHead: [String: [String: [String]]] = [:]
        for project in projects {
            for server in project.servers {
                for head in (server.heads ?? [:]).keys {
                    let key = "\(project.path)::\(server.server)::\(head)"
                    valid.insert(key)
                    byProjectHead[project.path, default: [:]][head, default: []].append(server.server)
                }
            }
        }
        var next = pinned
        for key in pinned where !valid.contains(key) {
            next.remove(key)
            let parts = key.split(separator: "::", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count == 3 else { continue }
            let project = parts[0]
            let head = parts[2]
            let candidates = byProjectHead[project]?[head] ?? []
            if candidates.count == 1, let server = candidates.first {
                next.insert("\(project)::\(server)::\(head)")
            }
        }
        guard next != pinned else { return }
        pinned = next
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(pinned.sorted(), forKey: Self.defaultsKey)
    }
}

/** A nested head entry: compact, quiet, the whole line clickable; the pin
    toggle appears on hover and pinned rows keep a subtle filled pin. */
struct HeadRow: View {
    @State private var hovering = false
    let filterText: String
    let keyNav: KeyNavModel
    let name: String
    let onOpen: () -> Void
    let onTogglePin: () -> Void
    let parentURL: String?
    let pinned: Bool
    let rowID: String
    let url: String

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onOpen()
                SpotlightIndexer.noteOpened(identifier: rowID)
                if let parsed = URL(string: url) {
                    NSWorkspace.shared.open(parsed)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    FuzzyMatcher.highlightedText(name, query: filterText)
                        .font(.caption)
                    if !displayHost.isEmpty {
                        FuzzyMatcher.highlightedText(displayHost, query: filterText)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
                .padding(.trailing, 6)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(url)
            .accessibilityLabel(Text("Open \(name)"))
            .modifier(KeyNavCell(active: keyNav.isHighlighted(rowID, .open)))

            HStack(spacing: 8) {
                Color.clear.frame(width: 14, height: 14)
                if pinned || hovering {
                    Button {
                        onTogglePin()
                        if !pinned { SpotlightIndexer.noteOpened(identifier: rowID) }
                    } label: {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                            .font(.system(size: 9))
                            .foregroundStyle(pinned ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .help(pinned ? "Unpin" : "Pin to top")
                    .accessibilityLabel(Text(pinned ? "Unpin \(name)" : "Pin \(name) to top"))
                    .modifier(KeyNavCell(active: keyNav.isHighlighted(rowID, .pin)))
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
            }
        }
        .background(
            hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 4))
        .onHover { hovering = $0 }
    }

    private var displayHost: String {
        guard let parsed = URL(string: url), let host = parsed.host else { return url }
        let headHostPort = parsed.port.map { "\(host):\($0)" } ?? host
        let headPath = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if let parentURL, let parentParsed = URL(string: parentURL), let parentHost = parentParsed.host {
            let parentHostPort = parentParsed.port.map { "\(parentHost):\($0)" } ?? parentHost
            if headHostPort == parentHostPort {
                return headPath.isEmpty ? "" : "/\(headPath)"
            }
        }
        return headPath.isEmpty ? headHostPort : "\(headHostPort)/\(headPath)"
    }
}

/** The tally light: state as color, `starting` breathes. Never shouts. */
struct TallyDot: View {
    @State private var breathing = false
    let phase: ServerPhase

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(phase == .starting ? (breathing ? 1.0 : 0.35) : 1.0)
            .animation(
                phase == .starting
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: breathing
            )
            .onAppear { breathing = true }
            .accessibilityLabel(Text(phase.rawValue))
    }

    private var color: Color {
        switch phase {
        case .running: .green
        case .starting, .stopping: .yellow
        case .unhealthy: .orange
        case .crashed, .failed: .red
        case .stopped: Color(nsColor: .tertiaryLabelColor)
        }
    }
}

/** Quiet band shown above the footer when a newer release exists. A Homebrew
    install gets an Upgrade button that runs `brew upgrade` in Terminal (a
    GUI-launched app has no PATH to run brew itself, and a password prompt needs
    somewhere to go); any other install gets a link to the release page. */
struct UpdateFooterRow: View {
    let status: UpdateStatus

    private var owner: CLIOwner { SetupPlanner.cliOwner() }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle")
                .foregroundStyle(.secondary)
            Text("directa \(status.latestVersion) available")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if owner.isHomebrew {
                Button("Upgrade") {
                    TerminalRunner.run(
                        title: "directa upgrade", command: DirectaDistribution.brewUpgradeCommand)
                }
                .controlSize(.small)
                .help("Run brew upgrade in Terminal")
            } else {
                Button("Release notes") {
                    if let url = URL(string: DirectaDistribution.releasesLatestURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                .help("Open the latest release page")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/** Icon + title with a tight gap; Label's default titleAndIcon spacing is wide
    for this dense footer. */
struct FooterIconLabel: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.caption)
        .contentShape(Rectangle())
    }
}

/** Compact sort picker floating in the blank space left of the filter box.
    Same continuous-corner chip language so the two controls read as one band. */
struct SortOrderMenu: View {
    @Binding var selection: ProjectSortOrder

    var body: some View {
        Menu {
            ForEach(ProjectSortOrder.allCases) { order in
                Button {
                    selection = order
                } label: {
                    if order == selection {
                        Label(order.title, systemImage: "checkmark")
                    } else {
                        Text(order.title)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(
                            shape.strokeBorder(
                                Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5))
                }
        }
        .buttonStyle(.plain)
        .help("Sort projects: \(selection.title)")
        .accessibilityLabel(Text("Sort projects"))
    }
}

/** Slim fuzzy filter for the popover's top-right corner. Filters projects,
    servers, urls, and heads; match marks land via FuzzyMatcher.highlightedText.
    Continuous radius matches the MenuBarExtra panel chrome so the control
    sits in the same curve family as the popover corner. */
struct FilterBox: View {
    @Binding var text: String

    /** Same continuous corner language as the MenuBarExtra `.window` panel. */
    private static let cornerRadius: CGFloat = 12
    /** Distance from the panel top to the filter top edge. */
    static let topInset: CGFloat = 8
    /** Scroll content top pad: clears the filter at rest without a large gap
        (topInset + control ≈ 8+22, plus 2pt air). */
    static let restClearance: CGFloat = 32

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
                .font(.caption2)
                .frame(width: 88)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel(Text("Clear filter"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            shape
                .fill(.ultraThinMaterial)
                .overlay(
                    shape.strokeBorder(
                        Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5))
        }
        .accessibilityLabel(Text("Filter servers"))
    }
}

enum FuzzyMatcher {
    static func matches(_ text: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let target = text.lowercased()
        let pattern = trimmed.lowercased()
        if target.contains(pattern) { return true }
        var searchIndex = target.startIndex
        for char in pattern {
            guard let found = target[searchIndex...].firstIndex(of: char) else {
                return false
            }
            searchIndex = target.index(after: found)
        }
        return true
    }

    static func highlightedText(_ text: String, query: String) -> Text {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, matches(text, query: trimmed) else { return Text(text) }
        var attr = AttributedString(text)
        let target = text.lowercased()
        let pattern = trimmed.lowercased()
        let highlightBg = Color.yellow.opacity(0.35)

        if let range = target.range(of: pattern) {
            if let attrRange = Range(range, in: attr) {
                attr[attrRange].backgroundColor = highlightBg
            }
        } else {
            var searchIndex = target.startIndex
            for char in pattern {
                guard let found = target[searchIndex...].firstIndex(of: char),
                    let attrRange = Range(found...found, in: attr)
                else { break }
                attr[attrRange].backgroundColor = highlightBg
                searchIndex = target.index(after: found)
            }
        }
        return Text(attr)
    }
}


