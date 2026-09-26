import Foundation
import Testing

@testable import DirectaKit

@Suite struct PortMaterializerTests {
    @Test func injectsPortAndRewritesURL() {
        let spec = ServerSpec(
            command: ["node", "server.js", "--port", "{port}"],
            host: "app.localhost",
            name: "web",
            port: 3000,
            url: "http://app.localhost:3000/"
        )
        let next = PortMaterializer.materialize(spec: spec, effectivePort: 3100)
        #expect(next.port == 3100)
        #expect(next.env?["PORT"] == "3100")
        #expect(next.command == ["node", "server.js", "--port", "3100"])
        #expect(next.url == "http://app.localhost:3100/")
    }

    @Test func substitutesHostTokenAndCustomPortEnv() {
        let spec = ServerSpec(
            command: ["echo", "{host}:{port}"],
            host: "old.localhost",
            name: "web",
            port: 3000,
            portEnv: "PUBLIC_PORT",
            url: "http://old.localhost:3000/"
        )
        let next = PortMaterializer.materialize(
            spec: spec, effectivePort: 4000, effectiveHost: "beta.app.localhost")
        #expect(next.env?["PUBLIC_PORT"] == "4000")
        #expect(next.env?["DIRECTA_HOST"] == "beta.app.localhost")
        #expect(next.command == ["echo", "beta.app.localhost:4000"])
        #expect(next.url == "http://beta.app.localhost:4000/")
        #expect(next.host == "beta.app.localhost")
    }

    @Test func rewritesHeadsAndHealthcheck() {
        let health = HealthCheckSpec(type: .http, url: "http://app.localhost:3000/healthz")
        let spec = ServerSpec(
            command: ["serve"],
            heads: ["admin": "http://admin.app.localhost:3000/"],
            healthcheck: health,
            host: "app.localhost",
            name: "web",
            port: 3000
        )
        let next = PortMaterializer.materialize(spec: spec, effectivePort: 3333)
        #expect(next.heads?["admin"] == "http://admin.app.localhost:3333/")
        #expect(next.healthcheck?.url == "http://app.localhost:3333/healthz")
    }

    @Test func rewritesTcpHealthcheckPort() {
        let health = HealthCheckSpec(port: 3000, type: .tcp)
        let spec = ServerSpec(
            command: ["serve", "{port}"], healthcheck: health, name: "web", port: 3000)
        let next = PortMaterializer.materialize(spec: spec, effectivePort: 4100)
        #expect(next.healthcheck?.port == 4100)
        #expect(next.command == ["serve", "4100"])
    }

    @Test func rewritesExactHostWhenPreferredChanges() {
        let spec = ServerSpec(
            command: ["serve"],
            host: "app.localhost",
            name: "web",
            port: 3000,
            url: "http://app.localhost:3000/"
        )
        let next = PortMaterializer.materialize(
            spec: spec, effectivePort: 3100, effectiveHost: "beta.app.localhost")
        #expect(next.url == "http://beta.app.localhost:3100/")
        #expect(next.host == "beta.app.localhost")
    }

    /** `spec.host` may already name a different subdomain than the committed
        URLs do; matchHost keeps those URL hosts eligible for rewrite. */
    @Test func matchHostRewritesAfterSpecHostAlreadyMoved() {
        let health = HealthCheckSpec(type: .http, url: "http://myproj.localhost:3000/api/health")
        let spec = ServerSpec(
            command: ["serve"],
            healthcheck: health,
            host: "beta.myproj.localhost",
            name: "myproj",
            port: 3000,
            url: "http://myproj.localhost:3000/"
        )
        let next = PortMaterializer.materialize(
            spec: spec, effectivePort: 3742, effectiveHost: spec.host,
            matchHost: "myproj.localhost")
        #expect(next.url == "http://beta.myproj.localhost:3742/")
        #expect(next.healthcheck?.url == "http://beta.myproj.localhost:3742/api/health")
    }

    @Test func relativeHeadResolvesAgainstTheServerBase() {
        let spec = ServerSpec(
            command: ["serve"],
            heads: ["admin": "/admin"],
            host: "app.localhost",
            name: "web",
            port: 33_334
        )
        let next = PortMaterializer.materialize(spec: spec, effectivePort: 33_334)
        #expect(next.heads?["admin"] == "http://app.localhost:33334/admin")
    }

    @Test func relativeHeadFollowsAReboundPortAndAnEffectiveHost() {
        let spec = ServerSpec(
            command: ["serve"],
            heads: ["admin": "/admin", "docs": "/docs/index.html"],
            host: "app.localhost",
            name: "web",
            port: 3000,
            url: "http://app.localhost:3000/"
        )
        let next = PortMaterializer.materialize(
            spec: spec, effectivePort: 3742, effectiveHost: "beta.app.localhost",
            matchHost: "app.localhost")
        #expect(next.heads?["admin"] == "http://beta.app.localhost:3742/admin")
        #expect(next.heads?["docs"] == "http://beta.app.localhost:3742/docs/index.html")
    }

    @Test func relativeHeadKeepsItsQueryAndFragment() {
        let spec = ServerSpec(
            command: ["serve"],
            heads: ["admin": "/admin?tab=1#top"],
            host: "app.localhost",
            name: "web",
            port: 3000
        )
        let next = PortMaterializer.materialize(spec: spec, effectivePort: 3000)
        #expect(next.heads?["admin"] == "http://app.localhost:3000/admin?tab=1#top")
    }

    @Test func relativeHealthcheckURLResolvesAgainstTheBase() {
        let health = HealthCheckSpec(type: .http, url: "/healthz")
        let spec = ServerSpec(
            command: ["serve"], healthcheck: health, host: "app.localhost", name: "web", port: 3000)
        let next = PortMaterializer.materialize(spec: spec, effectivePort: 3000)
        #expect(next.healthcheck?.url == "http://app.localhost:3000/healthz")
    }

    /** A path-only string parses as URLComponents with a nil host, and setting a
        port on a hostless component set serializes an empty authority
        (`//:3000/admin`). Returning nil is what hands the caller its
        relative-resolution and token-substitution fallbacks. */
    @Test func hostlessURLIsNeverStampedWithAPort() {
        #expect(PortMaterializer.rewriteURL("/admin", port: 3000, host: "app.localhost") == nil)
        #expect(PortMaterializer.rewriteURL("admin", port: 3000, host: nil) == nil)
    }

    @Test func relativeHeadWithNoBaseIsLeftAlone() {
        let spec = ServerSpec(command: ["serve"], heads: ["admin": "/admin"], name: "web")
        let next = PortMaterializer.materialize(spec: spec, effectivePort: nil)
        #expect(next.heads?["admin"] == "/admin")
    }
}

@Suite struct LocalOverlayTests {
    @Test func mergesPortAndEnv() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "directa-overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let overlay = LocalOverlayFile(
            servers: [
                "web": LocalOverlayServer(env: ["FOO": "bar"], port: 4100)
            ])
        let data = try JSONCoding.encoder().encode(overlay)
        try data.write(to: LocalOverlay.overlayURL(project: dir.path))
        let loaded = LocalOverlay.load(project: dir.path)
        #expect(loaded?.servers?["web"]?.port == 4100)
        let base = ServerSpec(
            command: ["serve"], env: ["FOO": "old", "KEEP": "1"], name: "web", port: 3000)
        let merged = LocalOverlay.apply(
            spec: base, overlay: loaded?.servers?["web"], project: dir.path)
        #expect(merged.port == 4100)
        #expect(merged.env?["FOO"] == "bar")
        #expect(merged.env?["KEEP"] == "1")
    }
}

@Suite struct CheckoutIdentityTests {
    @Test func sanitizeLabel() {
        #expect(CheckoutIdentity.sanitizeLabel("Fix Checkout Hosts") == "fix-checkout-hosts")
        #expect(CheckoutIdentity.sanitizeLabel("app_v2") == "app-v2")
    }

    @Test func siblingPortCandidateStaysInEphemeralRange() {
        let port = CheckoutIdentity.siblingPortCandidate(declared: 3000, project: "/tmp/proj-a")
        #expect(port >= 1024)
        #expect(port <= 65_000)
        #expect(port != 3000)
    }

    private func nonexistentProject() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "directa-checkout-identity-missing-\(UUID().uuidString)").path
    }

    /** Every fd this process has open right now, by listing `/dev/fd`. Used to
        detect the leak below: it must be read inside an `autoreleasepool`
        (both here and around each call under test), or Swift's own deferred
        release of the `Process`/`Pipe` objects themselves inflates the count
        independently of anything `git()` does, measured directly against a
        version of `git()` with no draining code at all. */
    private func openFileDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? -1
    }

    @Test func gitCommonDirAnswersNilForAMissingWorkingDirectory() {
        #expect(CheckoutIdentity.gitCommonDir(project: nonexistentProject()) == nil)
    }

    @Test func isLinkedWorktreeAnswersFalseForAMissingWorkingDirectory() {
        #expect(CheckoutIdentity.isLinkedWorktree(project: nonexistentProject()) == false)
    }

    @Test func worktreeDisplayAnswersNilForAMissingWorkingDirectory() {
        #expect(CheckoutIdentity.worktreeDisplay(project: nonexistentProject()) == nil)
    }

    @Test func shareCommonDirAnswersFalseWhenBothProjectsAreMissing() {
        #expect(!CheckoutIdentity.shareCommonDir(nonexistentProject(), nonexistentProject()))
    }

    /** The private `git()` helper used to start its two pipe-draining threads
        before `process.run()`, so a `run()` failure (an invalid working
        directory, here) left both threads blocked forever reading a pipe
        this process itself still held the write end of: nothing ever spawned
        to close it, and each draining closure kept its pipe's fds open by
        capturing the whole `Pipe` object for as long as the thread runs,
        which is forever. Every public caller answers `nil` quickly either
        way, so the regression is invisible at the call site; it shows up
        only as leaked threads and file descriptors that never come back,
        measured directly here (repeated real failures against a bare
        Process+Pipe pair with no draining at all confirm 0 fds leak on their
        own, isolating the count to the draining threads specifically). */
    @Test func gitFailureDoesNotLeakFileDescriptorsAcrossRepeatedFailures() {
        let before = autoreleasepool { openFileDescriptorCount() }
        for _ in 0..<60 {
            autoreleasepool {
                _ = CheckoutIdentity.gitCommonDir(project: nonexistentProject())
            }
        }
        /** The leaked threads (when the bug is present) are already blocked in
            a syscall by the time `run()` returns, so waiting longer never
            recovers them; the leak itself cannot flake either direction.
            The threshold is loose (measured: a real leak is 4 fds per
            failure, 240 across 60 here) because Swift Testing runs suites in
            parallel, and a sibling suite's own transient fds can nudge this
            process's count by a handful at the exact moment this reads it. */
        let after = autoreleasepool { openFileDescriptorCount() }
        #expect(after - before < 60, "leaked \(after - before) file descriptors across 60 failures")
    }
}
