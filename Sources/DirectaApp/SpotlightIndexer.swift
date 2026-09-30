import AppKit
@preconcurrency import CoreSpotlight
import DirectaKit
import Foundation

/** Spotlight integration: every server and every head becomes a searchable item
    ("myproj · operator" opens the surface). Titles lead with the project/head;
    `directa` lives in the subtitle. Ranking above filesystem Top Hits is not
    something Core Spotlight can force; within our own items we preserve
    last-used engagement across syncs, update in place instead of wipe-rebuild,
    and tier `rankingHint` by live/pinned. Raycast/Alfred + `directa://` is the
    fast path. */
enum SpotlightIndexer {
    /** nonisolated: read inside the (nonisolated) index completion callback. */
    nonisolated static let domain = "directa-servers"
    /** Donated on open so Spotlight can re-surface the item; continue accepts
        both CSSearchableItemActionType and this type. */
    static let activityType = "dev.quantizor.directa.open-surface"
    private static let entriesKey = "spotlight entries"
    private static let signatureKey = "spotlight signature"
    /** nonisolated: written inside the (nonisolated) index completion callback. */
    nonisolated private static let statusKey = "spotlight last sync"

    /** Persisted in UserDefaults; new fields stay optional so older payloads keep
        decoding (defensive-load rule). */
    struct SpotlightEntry: Codable, Sendable {
        var alternateNames: [String]?
        var firstSeen: Date?
        let icon: String?
        let keywords: [String]
        var lastUsed: Date?
        let rankingHint: Int
        let title: String
        let url: String
    }

    /** Named index so Spotlight can batch; default() forbids batching. */
    nonisolated private static let index = CSSearchableIndex(name: "directa-servers")

    /** periphery:ignore - an NSUserActivity must stay strongly referenced after becomeCurrent() or it is invalidated and the Spotlight donation disappears */
    private static var currentActivity: NSUserActivity?

    static func sync(projects: [DaemonModel.ProjectGroup]) {
        guard CSSearchableIndex.isIndexingAvailable() else {
            UserDefaults.standard.set("unavailable", forKey: statusKey)
            return
        }
        HeadPins.shared.reconcile(projects: projects)
        let pins = HeadPins.shared
        let previous = loadEntries()
        let now = Date()
        var entriesByIdentifier: [String: SpotlightEntry] = [:]
        var payload: [(identifier: String, entry: SpotlightEntry, existed: Bool)] = []
        for project in projects {
            for server in project.servers {
                if let url = server.url {
                    let identifier = "\(project.path)::\(server.server)"
                    let prior = previous[identifier]
                    let names = SpotlightLabel.alternateNames(
                        project: project.name, server: server.server, head: nil, url: url,
                        family: server.mainProject)
                    let entry = SpotlightEntry(
                        alternateNames: names,
                        firstSeen: prior?.firstSeen ?? now,
                        icon: server.icon,
                        keywords: SpotlightLabel.keywords(
                            project: project.name, server: server.server, head: nil, url: url,
                            family: server.mainProject),
                        lastUsed: prior?.lastUsed,
                        rankingHint: SpotlightLabel.rankingHint(phase: server.phase, pinned: false),
                        title: SpotlightLabel.title(
                            project: project.name, server: server.server, head: nil),
                        url: url)
                    entriesByIdentifier[identifier] = entry
                    payload.append((identifier, entry, prior != nil))
                }
                for (head, url) in server.heads ?? [:] {
                    let identifier = "\(project.path)::\(server.server)::\(head)"
                    let prior = previous[identifier]
                    let pinned = pins.isPinned(project: project.path, server: server.server, head: head)
                    let names = SpotlightLabel.alternateNames(
                        project: project.name, server: server.server, head: head, url: url,
                        family: server.mainProject)
                    let entry = SpotlightEntry(
                        alternateNames: names,
                        firstSeen: prior?.firstSeen ?? now,
                        icon: server.icon,
                        keywords: SpotlightLabel.keywords(
                            project: project.name, server: server.server, head: head, url: url,
                            family: server.mainProject),
                        lastUsed: prior?.lastUsed,
                        rankingHint: SpotlightLabel.rankingHint(phase: server.phase, pinned: pinned),
                        title: SpotlightLabel.title(
                            project: project.name, server: server.server, head: head),
                        url: url)
                    entriesByIdentifier[identifier] = entry
                    payload.append((identifier, entry, prior != nil))
                }
            }
        }
        let signature = "v7-cs-incremental|" + payload.map {
            "\($0.identifier)#\($0.entry.title)#\($0.entry.url)#\($0.entry.icon ?? "")#\($0.entry.rankingHint)#\($0.entry.keywords.joined(separator: ","))#\(($0.entry.alternateNames ?? []).joined(separator: ","))"
        }.sorted().joined(separator: "|")
        guard signature != UserDefaults.standard.string(forKey: signatureKey) else { return }
        if let data = try? JSONCoding.encoder().encode(entriesByIdentifier) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
        UserDefaults.standard.set(signature, forKey: signatureKey)

        let removed = Set(previous.keys).subtracting(entriesByIdentifier.keys)
        let built = payload.map { element -> CSSearchableItem in
            let item = CSSearchableItem(
                uniqueIdentifier: element.identifier,
                domainIdentifier: domain,
                attributeSet: attributeSet(for: element.entry))
            item.expirationDate = .distantFuture
            item.isUpdate = element.existed
            return item
        }
        let count = built.count
        let finish: @Sendable (Error?) -> Void = { error in
            UserDefaults.standard.set(
                error.map { "error: \($0.localizedDescription)" }
                    ?? "ok \(count) items \(JSONCoding.formatISO8601(Date()))",
                forKey: statusKey)
        }
        if removed.isEmpty {
            index.indexSearchableItems(built, completionHandler: finish)
        } else {
            let toIndex = built
            index.deleteSearchableItems(withIdentifiers: Array(removed)) {
                deleteError in
                if let deleteError {
                    finish(deleteError)
                    return
                }
                index.indexSearchableItems(toIndex, completionHandler: finish)
            }
        }
    }

    /** Drop every donated item and the local engagement cache. Full uninstall
        calls this so Spotlight does not keep serving removed servers. */
    static func deleteAll() {
        index.deleteAllSearchableItems { _ in }
        UserDefaults.standard.removeObject(forKey: entriesKey)
        UserDefaults.standard.removeObject(forKey: signatureKey)
        UserDefaults.standard.removeObject(forKey: statusKey)
    }

    static func noteOpened(identifier: String) {
        var map = loadEntries()
        guard var entry = map[identifier] else { return }
        let now = Date()
        entry.lastUsed = now
        if entry.firstSeen == nil { entry.firstSeen = now }
        map[identifier] = entry
        if let data = try? JSONCoding.encoder().encode(map) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
        let item = CSSearchableItem(
            uniqueIdentifier: identifier,
            domainIdentifier: domain,
            attributeSet: attributeSet(for: entry, lastUsed: now))
        item.isUpdate = true
        item.expirationDate = .distantFuture
        index.indexSearchableItems([item]) { _ in }
        donateActivity(identifier: identifier, entry: entry)
    }

    nonisolated private static func attributeSet(
        for entry: SpotlightEntry, lastUsed: Date? = nil
    ) -> CSSearchableItemAttributeSet {
        /** `.text` surfaces on macOS; `.url` often indexes "ok" but never appears. */
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        let created = entry.firstSeen ?? Date()
        let used = lastUsed ?? entry.lastUsed
        if let names = entry.alternateNames, !names.isEmpty {
            attributes.alternateNames = names
        }
        attributes.containerDisplayName = "directa"
        attributes.contentCreationDate = created
        attributes.contentDescription = SpotlightLabel.subtitle(url: entry.url)
        attributes.contentModificationDate = used ?? created
        attributes.displayName = entry.title
        attributes.keywords = entry.keywords
        attributes.kind = "Dev Server"
        if let used { attributes.lastUsedDate = used }
        attributes.metadataModificationDate = Date()
        attributes.organizations = ["directa"]
        attributes.rankingHint = NSNumber(value: entry.rankingHint)
        attributes.subject = entry.title
        attributes.textContent = "\(entry.title)\n\(SpotlightLabel.subtitle(url: entry.url))"
        attributes.thumbnailData = entry.icon.flatMap(Self.thumbnailPNG)
        attributes.title = entry.title
        attributes.url = URL(string: entry.url)
        return attributes
    }

    private static func donateActivity(identifier: String, entry: SpotlightEntry) {
        let activity = NSUserActivity(activityType: activityType)
        activity.title = entry.title
        activity.keywords = Set(entry.keywords)
        activity.userInfo = [CSSearchableItemActivityIdentifier: identifier]
        activity.isEligibleForHandoff = false
        activity.isEligibleForSearch = true
        activity.persistentIdentifier = identifier
        activity.targetContentIdentifier = identifier
        activity.expirationDate = .distantFuture
        if let url = URL(string: entry.url) { activity.webpageURL = url }
        let attributes = attributeSet(for: entry, lastUsed: Date())
        attributes.relatedUniqueIdentifier = identifier
        activity.contentAttributeSet = attributes
        activity.becomeCurrent()
        currentActivity = activity
    }

    private static func loadEntries() -> [String: SpotlightEntry] {
        guard let data = UserDefaults.standard.data(forKey: entriesKey),
            let map = try? JSONCoding.decoder().decode([String: SpotlightEntry].self, from: data)
        else { return [:] }
        return map
    }

    nonisolated static func thumbnailPNG(path: String) -> Data? {
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        let side: CGFloat = 128
        let target = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        guard let tiff = target.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func url(forIdentifier identifier: String) -> URL? {
        loadEntries()[identifier].flatMap { URL(string: $0.url) }
    }
}
