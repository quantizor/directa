import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaKit

@Suite("UpdateCheck", .temporaryTree)
struct UpdateCheckTests {
    private func scratchPaths() throws -> (DirectaPaths, URL) {
        let dir = try TemporaryTree.path(named: "update")
        return (DirectaPaths(dataDir: dir, logsDir: dir.appending(path: "logs")), dir)
    }

    @Test func normalizeStripsLeadingV() {
        #expect(UpdateCheck.normalize("v1.5.0") == "1.5.0")
        #expect(UpdateCheck.normalize("1.5.0") == "1.5.0")
        #expect(UpdateCheck.normalize(" v2.0.1 ") == "2.0.1")
    }

    @Test func statusFlagsAvailableOnlyWhenNewer() {
        let cache = UpdateCheck.Cache(checkedAt: Date(), etag: nil, latestVersion: "1.5.0")
        #expect(UpdateCheck.status(from: cache, currentVersion: "1.4.0").updateAvailable)
        #expect(!UpdateCheck.status(from: cache, currentVersion: "1.5.0").updateAvailable)
        #expect(!UpdateCheck.status(from: cache, currentVersion: "1.6.0").updateAvailable)
    }

    @Test func cachedStatusRoundTripsThroughDisk() throws {
        let (paths, dir) = try scratchPaths()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = UpdateCheck.Cache(checkedAt: Date(), etag: "abc", latestVersion: "2.0.0")
        try AtomicFile.write(
            JSONCoding.encoder().encode(cache), to: UpdateCheck.cacheURL(paths: paths))
        let status = UpdateCheck.cachedStatus(paths: paths, currentVersion: "1.0.0")
        #expect(status?.latestVersion == "2.0.0")
        #expect(status?.updateAvailable == true)
    }

    @Test func cachedStatusIsNilWithoutACache() throws {
        let (paths, _) = try scratchPaths()
        #expect(UpdateCheck.cachedStatus(paths: paths) == nil)
    }

    /** A cache younger than maxAge is returned as-is, never triggering a fetch,
        which is what keeps doctor and the app off the network on every call. */
    @Test func refreshIfStaleReturnsFreshCacheWithoutFetching() async throws {
        let (paths, dir) = try scratchPaths()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        let cache = UpdateCheck.Cache(checkedAt: now, etag: nil, latestVersion: "9.9.9")
        try AtomicFile.write(
            JSONCoding.encoder().encode(cache), to: UpdateCheck.cacheURL(paths: paths))
        let status = await UpdateCheck.refreshIfStale(
            paths: paths, maxAge: 3600, currentVersion: "1.0.0", now: now)
        #expect(status?.latestVersion == "9.9.9")
        #expect(status?.updateAvailable == true)
    }
}
