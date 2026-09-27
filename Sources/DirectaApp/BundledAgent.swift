import DirectaKit
import Foundation
import ServiceManagement

/** A LaunchAgent plist shipped in this app's `Contents/Library/LaunchAgents`
    and registered through `SMAppService.agent`. Service Management resolves
    the plist relative to `Bundle.main`, so this works only inside the app
    process. Nonisolated: Service Management is thread-safe for these calls,
    and each is a synchronous XPC round-trip no caller should make on main.

    `service` builds a fresh `SMAppService` per access (the class is not
    Sendable, so a shared instance cannot cross isolation); a caller making
    several calls in one decision holds the one it got. */
struct BundledAgent: Sendable {
    enum Failure: Error, LocalizedError, Sendable {
        case missingPlist(String)

        var errorDescription: String? {
            switch self {
            case .missingPlist(let name):
                "This copy of directa.app is missing \(name). Reinstall from the DMG or run make app."
            }
        }
    }

    let plistName: String

    nonisolated var service: SMAppService { SMAppService.agent(plistName: plistName) }

    nonisolated var status: AppAgentPolicy.RegistrationStatus { .init(service.status) }

    /** False for a copy built before this plist existed, or a debug build
        assembled without `make app`: registering then throws on a plist
        Service Management cannot find. */
    nonisolated var bundleHasPlist: Bool {
        let url = Bundle.main.bundleURL
            .appending(path: "Contents/Library/LaunchAgents")
            .appending(path: plistName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /** Register unless already enabled and answer the status registration
        ended in. Registering an already-registered job throws, and a
        registration that lands in `requiresApproval` can throw too, so a
        throw that leaves the job waiting on approval is not an error here:
        the caller decides what `requiresApproval` means for it. */
    nonisolated func registerTolerant() throws -> AppAgentPolicy.RegistrationStatus {
        guard bundleHasPlist else { throw Failure.missingPlist(plistName) }
        let service = service
        guard service.status != .enabled else { return .enabled }
        do {
            try service.register()
        } catch {
            let after = AppAgentPolicy.RegistrationStatus(service.status)
            guard after == .requiresApproval else { throw error }
            return after
        }
        return .init(service.status)
    }
}

extension AppAgentPolicy.RegistrationStatus {
    nonisolated init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .notFound: self = .notFound
        case .notRegistered: self = .notRegistered
        case .requiresApproval: self = .requiresApproval
        @unknown default: self = .unknown
        }
    }
}
