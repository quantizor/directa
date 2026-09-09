import AppKit
import DirectaKit
import SwiftUI

/** The dashboard: sidebar of servers grouped by project; detail tabs for logs
    (live tail with stream/grep filters and jump-to-marker), the event timeline
    (phase lanes per server), and the config editor (optimistic concurrency via
    project.writeConfig, so an IDE save is never clobbered). */
struct DashboardView: View {
    var model: DaemonModel
    @State private var selection: ServerSelection?

    struct ServerSelection: Hashable {
        let name: String
        let project: String
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(model.projects) { project in
                    Section((project.path as NSString).lastPathComponent) {
                        ForEach(project.servers, id: \.server) { server in
                            HStack(spacing: 8) {
                                TallyDot(phase: server.phase)
                                Text(server.server)
                                Spacer()
                                Text(server.phase.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(ServerSelection(name: server.server, project: server.project))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let selection,
                let server = model.projects.first(where: { $0.path == selection.project })?
                    .servers.first(where: { $0.server == selection.name }) {
                ServerDetail(model: model, server: server)
            } else {
                ContentUnavailableView(
                    "Pick a server", systemImage: "server.rack",
                    description: Text("Logs, timeline, and configuration live here."))
            }
        }
        .onAppear { AppFocus.promote() }
    }
}

struct ServerDetail: View {
    var model: DaemonModel
    let server: ServerStatus
    @State private var tab: Tab = .logs

    enum Tab: String, CaseIterable {
        case config = "Config"
        case logs = "Logs"
        case timeline = "Timeline"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    TallyDot(phase: server.phase)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.server).font(.headline)
                        Text(statusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    ServerLifecycleControls(
                        model: model, reserveSlot: false, server: server, size: 16)
                    if let url = server.url {
                        Button {
                            SpotlightIndexer.noteOpened(identifier: "\(server.project)::\(server.server)")
                            openURL(url)
                        } label: {
                            Image(systemName: "safari")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)
                        .help(url)
                        .accessibilityLabel(Text("Open URL"))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy URL")
                        .accessibilityLabel(Text("Copy URL"))
                    }
                    if let heads = server.heads, !heads.isEmpty {
                        Menu {
                            ForEach(heads.sorted(by: { $0.key < $1.key }), id: \.key) { name, url in
                                Button("\(name) · \(url)") {
                                    SpotlightIndexer.noteOpened(
                                        identifier: "\(server.project)::\(server.server)::\(name)")
                                    openURL(url)
                                }
                            }
                        } label: {
                            Image(systemName: "rectangle.stack")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 16, height: 16)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 22)
                        .help("Open head")
                        .accessibilityLabel(Text("Open head"))
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: server.logPath)])
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal log file")
                    .accessibilityLabel(Text("Reveal log file"))
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .accessibilityLabel(Text("Detail view"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            switch tab {
            case .config:
                ConfigEditor(project: server.project)
            case .logs:
                LogsPane(server: server)
            case .timeline:
                TimelinePane(project: server.project)
            }
        }
    }

    private var statusLine: String {
        var parts: [String] = [server.phase.rawValue]
        if let pid = server.pid {
            parts.append("pid \(pid)")
        }
        if let port = server.displayPort {
            parts.append("port \(port)")
        }
        if let uptime = server.uptimeSec, server.phase == .running || server.phase == .unhealthy {
            parts.append(Self.formatUptime(uptime))
        }
        if server.specStale == true {
            parts.append("spec stale")
        }
        if let err = server.spawnError {
            parts.append(err.message)
        }
        return parts.joined(separator: " · ")
    }

    private func openURL(_ string: String?) {
        guard let string, let parsed = URL(string: string) else { return }
        NSWorkspace.shared.open(parsed)
    }

    private static func formatUptime(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s up" }
        if seconds < 3600 { return "\(seconds / 60)m up" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(hours)h up" : "\(hours)h \(minutes)m up"
    }
}

/** Live log tail: polls logs.query (restart-safe), filters by stream/regex,
    jumps to a recent marker by turning it into a since-bound. */
struct LogsPane: View {
    let server: ServerStatus

    @State private var grep = ""
    @State private var marks: [LogRecord] = []
    @State private var records: [LogRecord] = []
    @State private var sinceMark: String?
    @State private var stream: String = "all"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Stream", selection: $stream) {
                    Text("all").tag("all")
                    ForEach(["out", "err", "sys", "mark"], id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 130)
                TextField("filter (regex)", text: $grep)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Menu(sinceMark.map { "since \($0)" } ?? "since: all") {
                    Button("all") { sinceMark = nil }
                    ForEach(marks, id: \.at) { mark in
                        let id = mark.text.split(separator: "\t").first.map(String.init) ?? mark.text
                        Button("\(id) · \(JSONCoding.formatISO8601(mark.at))") { sinceMark = id }
                    }
                }
                .frame(maxWidth: 240)
                Spacer()
                Text("\(records.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                            HStack(alignment: .top, spacing: 6) {
                                Text(JSONCoding.formatISO8601(record.at).suffix(13).dropLast())
                                    .foregroundStyle(.tertiary)
                                Text(record.stream.rawValue)
                                    .foregroundStyle(streamColor(record.stream))
                                    .frame(width: 32, alignment: .leading)
                                Text(record.text)
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .id(index)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: records.count) {
                    proxy.scrollTo(records.count - 1, anchor: .bottom)
                }
            }
        }
        /** The project is part of the identity: two projects can each register a
            server of the same name, and without it selecting the second one left
            this task running against the first, tailing the wrong logs under the
            right header. */
        .task(id: "\(server.project)|\(server.server)|\(stream)|\(grep)|\(sinceMark ?? "")") {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func streamColor(_ stream: LogStream) -> Color {
        switch stream {
        case .err: .orange
        case .mark: .blue
        case .out: .secondary
        case .sys: .purple
        }
    }

    private func refresh() async {
        let client = AppDaemon.client
        let streams: [LogStream]? = stream == "all" ? nil : LogStream(rawValue: stream).map { [$0] }
        let params = LogsQueryParams(
            grep: grep.isEmpty ? nil : grep,
            name: server.server,
            project: server.project,
            sinceMark: sinceMark,
            streams: streams,
            tail: 400)
        if let result = try? await client.request(.logsQuery, params: params, expecting: LogsQueryResult.self) {
            records = result.lines
        }
        let markParams = LogsQueryParams(
            name: server.server, project: server.project, streams: [.mark], tail: 15)
        if let found = try? await client.request(.logsQuery, params: markParams, expecting: LogsQueryResult.self) {
            marks = found.lines.reversed()
        }
    }
}

/** Event timeline: one lane per server, phase spans over the last window with
    mark pins; the event list below carries the exact records. */
struct TimelinePane: View {
    let project: String

    @State private var events: [EventRecord] = []
    private let window: TimeInterval = 30 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let lanes = Dictionary(grouping: events, by: \.server).sorted { $0.key < $1.key }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lanes, id: \.key) { name, laneEvents in
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.caption)
                            .frame(width: 90, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        LaneView(events: laneEvents, window: window)
                            .frame(height: 14)
                    }
                }
                HStack {
                    Text("last \(Int(window / 60)) minutes")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 98)
                    Spacer()
                }
            }
            .padding(10)
            Divider()
            List(events.reversed(), id: \.at) { event in
                HStack(spacing: 8) {
                    Text(JSONCoding.formatISO8601(event.at))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(event.server).fontWeight(.medium)
                    Text(event.kind.rawValue)
                        .foregroundStyle(kindColor(event.kind))
                    if let detail = event.detail {
                        Text(detail).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
            }
        }
        .task(id: project) {
            while !Task.isCancelled {
                let client = AppDaemon.client
                if let result = try? await client.request(
                    .eventsQuery,
                    params: EventsQueryParams(project: project, since: Date().addingTimeInterval(-window)),
                    expecting: EventsQueryResult.self) {
                    events = result.events
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func kindColor(_ kind: EventKind) -> Color {
        switch kind {
        case .crashed, .failed: .red
        case .healthy, .started: .green
        case .marked: .blue
        case .registered, .unregistered: .secondary
        case .stopped: .secondary
        case .unhealthy: .orange
        }
    }
}

/** Phase spans reconstructed from event transitions inside the window. */
struct LaneView: View {
    let events: [EventRecord]
    let window: TimeInterval

    var body: some View {
        Canvas { context, size in
            let now = Date()
            let start = now.addingTimeInterval(-window)
            func x(_ date: Date) -> CGFloat {
                let fraction = date.timeIntervalSince(start) / window
                return CGFloat(min(max(fraction, 0), 1)) * size.width
            }
            var spanStart: (Date, Color)?
            func flush(to endDate: Date) {
                guard let (from, color) = spanStart else { return }
                let rect = CGRect(
                    x: x(from), y: 3, width: max(x(endDate) - x(from), 1.5), height: size.height - 6)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(0.75)))
            }
            for event in events.sorted(by: { $0.at < $1.at }) {
                switch event.kind {
                case .started, .healthy:
                    if spanStart == nil { spanStart = (event.at, .green) }
                case .unhealthy:
                    flush(to: event.at)
                    spanStart = (event.at, .orange)
                case .crashed, .failed, .stopped:
                    flush(to: event.at)
                    spanStart = nil
                    let color: Color = event.kind == .stopped ? .secondary : .red
                    let mark = CGRect(x: x(event.at) - 1, y: 1, width: 2, height: size.height - 2)
                    context.fill(Path(mark), with: .color(color))
                case .marked:
                    let pin = CGRect(x: x(event.at) - 0.75, y: 0, width: 1.5, height: size.height)
                    context.fill(Path(pin), with: .color(.blue.opacity(0.9)))
                case .registered, .unregistered:
                    break
                }
            }
            flush(to: now)
        }
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 3))
    }
}

/** devservers.json editor with optimistic concurrency: the daemon validates and
    rejects when the file changed under the editor. Syntax color is applied live
    by JSONSyntaxEditor (AppKit NSTextView); no third-party highlighter. */
struct ConfigEditor: View {
    let project: String

    @State private var baselineHash = ""
    @State private var content = ""
    @State private var feedback: String?
    @State private var feedbackIsError = false

    var body: some View {
        VStack(spacing: 0) {
            JSONSyntaxEditor(text: $content)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            Divider()
            HStack {
                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(feedbackIsError ? .red : .secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Reload") { load() }
                Button("Validate and Save") { save() }
                    .keyboardShortcut("s")
            }
            .padding(8)
        }
        .onAppear { load() }
    }

    private func load() {
        let url = ProjectConfigLoader.configURL(project: project)
        let data = (try? Data(contentsOf: url)) ?? Data()
        content = String(decoding: data, as: UTF8.self)
        baselineHash = data.isEmpty ? "" : DirectaPaths.hash8(content)
        feedback = "loaded \(url.lastPathComponent)"
        feedbackIsError = false
    }

    private func save() {
        Task {
            let client = AppDaemon.client
            do {
                let result = try await client.request(
                    .projectWriteConfig,
                    params: WriteConfigParams(baselineHash: baselineHash, content: content, project: project),
                    expecting: CheckResult.self)
                baselineHash = DirectaPaths.hash8(content)
                feedback = result.warnings.isEmpty
                    ? "saved (servers: \(result.servers.joined(separator: ", ")))"
                    : "saved with warnings: \(result.warnings.joined(separator: "; "))"
                feedbackIsError = false
            } catch let error as WireError {
                feedback = error.message
                feedbackIsError = true
            } catch {
                feedback = String(describing: error)
                feedbackIsError = true
            }
        }
    }
}
