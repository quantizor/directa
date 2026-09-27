import Foundation
import Testing
import os

@testable import DirectaKit

@Suite struct PortClaimTests {
    @Test func spanOnlyClaimsConsecutiveBlock() throws {
        let spec = ServerSpec(
            command: ["serve"], name: "web", port: 3000, portEnv: "PUBLIC_PORT", portSpan: 4)
        let resolved = PortClaim.resolve(spec: spec, effectivePort: 3100)
        let claim = try #require(resolved.claim)
        #expect(resolved.error == nil)
        #expect(claim.primary == 3100)
        #expect(claim.relative == [3100, 3101, 3102, 3103])
        #expect(claim.injections["PUBLIC_PORT"] == 3100)
        #expect(claim.named.isEmpty)
    }

    @Test func namedRelativeAndAbsolute() throws {
        let spec = ServerSpec(
            command: ["serve"],
            name: "web",
            port: 3000,
            portEnv: "PUBLIC_PORT",
            ports: [
                "cms": SecondaryPort(env: "CMS_PORT", offset: 1),
                "metrics": SecondaryPort(env: "METRICS_PORT", port: 9090),
            ])
        let claim = try #require(PortClaim.resolve(spec: spec, effectivePort: 4000).claim)
        #expect(claim.relative == [4000, 4001])
        #expect(claim.absolute == [9090])
        #expect(claim.named["cms"] == 4001)
        #expect(claim.named["metrics"] == 9090)
        #expect(claim.injections["CMS_PORT"] == 4001)
        #expect(claim.injections["METRICS_PORT"] == 9090)
        #expect(claim.allPorts == [4000, 4001, 9090])
    }

    @Test func spanAndNamedOffsetOverlapIsError() {
        let spec = ServerSpec(
            command: ["serve"],
            name: "web",
            port: 3000,
            ports: ["cms": SecondaryPort(offset: 1)],
            portSpan: 4)
        let resolved = PortClaim.resolve(spec: spec, effectivePort: 3000)
        #expect(resolved.claim == nil)
        #expect(resolved.error?.contains("overlaps portSpan") == true)
        #expect(PortClaim.configErrors(spec: spec).isEmpty == false)
    }

    @Test func materializerInjectsNamedEnvs() {
        let spec = ServerSpec(
            command: ["serve"],
            host: "app.localhost",
            name: "web",
            port: 3000,
            portEnv: "PUBLIC_PORT",
            ports: ["cms": SecondaryPort(env: "CMS_PORT", offset: 1)],
            url: "http://app.localhost:3000/")
        let next = PortMaterializer.materialize(spec: spec, effectivePort: 4100)
        #expect(next.env?["PUBLIC_PORT"] == "4100")
        #expect(next.env?["CMS_PORT"] == "4101")
        #expect(next.url == "http://app.localhost:4100/")
    }

    /** The instance the validator could not see. `offset` had a floor and no
        ceiling, so `directa config check` answered `"errors":[]` on this exact
        config and the daemon then died on the spawn path, reporting only that
        the daemon was unreachable. Measured before the fix: `directa ensure`
        against it took the daemon down with exit 133 (SIGTRAP). */
    @Test func anExtremeOffsetIsAConfigErrorRatherThanASpawnTrap() {
        let spec = ServerSpec(
            command: ["serve"],
            name: "web",
            port: 3000,
            ports: ["api": SecondaryPort(offset: Int.max)])
        let errors = PortClaim.configErrors(spec: spec)
        #expect(errors.contains { $0.contains("offset must be 0...65534") })
        /** `resolve` refuses rather than reaching `primary + offset`. */
        let resolved = PortClaim.resolve(spec: spec, effectivePort: 3000)
        #expect(resolved.claim == nil)
        #expect(resolved.error?.contains("offset must be 0...65534") == true)
    }

    /** Returning from this test at all is the assertion: every check in
        `configErrors` appends and falls through, so before the fix the sum was
        computed on a value the line above had already rejected and the process
        died on the spot. A trap cannot be caught in-process, so the red half of
        this was established out of process, by watching a real daemon exit 133
        when `directa status --all` read a config shaped like this one. */
    @Test func anExtremePortWithASpanReportsRatherThanTraps() {
        let spec = ServerSpec(command: ["serve"], name: "web", port: Int.max, portSpan: 2)
        let errors = PortClaim.configErrors(spec: spec)
        #expect(errors.contains { $0.contains("port must be 1...65535") })
        /** The combined message is suppressed precisely because its operands
            were rejected; reporting "runs past 65535" about Int.max would be
            noise on top of the real error. */
        #expect(errors.contains { $0.contains("runs past 65535") } == false)
    }

    @Test func anExtremeSpanIsRefusedByBothCheckers() {
        let spec = ServerSpec(command: ["serve"], name: "web", port: 3000, portSpan: Int.max)
        #expect(PortClaim.configErrors(spec: spec).contains { $0.contains("portSpan must be") })
        let resolved = PortClaim.resolve(spec: spec, effectivePort: 3000)
        #expect(resolved.claim == nil)
        #expect(resolved.error?.contains("portSpan must be 1...65535") == true)
    }

    /** The bounds are inclusive, so the edges must still be accepted. Without
        this, clamping too tightly would read as a fix and silently reject a
        legal config. */
    @Test func theEdgesOfEveryRangeStayLegal() throws {
        let spec = ServerSpec(
            command: ["serve"],
            name: "web",
            port: 65_535,
            ports: ["api": SecondaryPort(offset: 0), "fixed": SecondaryPort(port: 1)])
        #expect(PortClaim.configErrors(spec: spec).isEmpty)
        let claim = try #require(PortClaim.resolve(spec: spec, effectivePort: 65_535).claim)
        #expect(claim.named["api"] == 65_535)
        #expect(claim.named["fixed"] == 1)
    }

    @Test func aWideSpanResolvesEveryPortInTheBlock() throws {
        /** Config allows 1...65535; real apps use tens, not 4. Resolve has to
            emit the whole consecutive block without trapping or dropping the
            tail, and `allPorts` has to list each one once. */
        let spec = ServerSpec(command: ["serve"], name: "web", port: 45_000, portSpan: 64)
        #expect(PortClaim.configErrors(spec: spec).isEmpty)
        let claim = try #require(PortClaim.resolve(spec: spec, effectivePort: 45_000).claim)
        #expect(claim.relative.count == 64)
        #expect(claim.relative.first == 45_000)
        #expect(claim.relative.last == 45_063)
        #expect(claim.allPorts == Array(45_000...45_063))
    }

    private let spanSpec = ServerSpec(command: ["serve"], name: "web", port: 45_200, portSpan: 3)

    private func status(
        observedPort: Int? = nil, phase: ServerPhase, pid: Int? = nil, ports: [String: Int]? = nil
    ) -> ServerStatus {
        ServerStatus(
            declaredPort: 45_200, effectivePort: 45_200, logPath: "/dev/null",
            observedPort: observedPort, phase: phase, pid: pid, ports: ports, project: "/main",
            server: "web")
    }

    /** The overlap seen in a sibling-worktree run: main runs a span of three
        but listens only on its base, and a rebind search starting just past
        that base landed inside main's span. A running holder reserves its
        whole claim, so the block lands past it. */
    @Test func aSiblingRebindClearsARunningHoldersWholeSpan() async throws {
        let mainClaim = PortClaim.resolve(spec: spanSpec, effectivePort: 45_200).claim
        let reserved = status(observedPort: 45_200, phase: .running, pid: 7)
            .heldPorts(claim: mainClaim)
        #expect(reserved == [45_200, 45_201, 45_202])
        let rebound = await SiblingRebind.search(
            isListening: { $0 == 45_200 }, reserved: reserved, spec: spanSpec, start: 45_201)
        #expect(rebound == 45_203)
    }

    /** A listener anywhere in a candidate block rules the block out, whoever
        owns it. */
    @Test func aSiblingRebindSkipsEveryBlockWithAListener() async {
        let rebound = await SiblingRebind.search(
            isListening: { $0 == 45_205 }, reserved: [], spec: spanSpec, start: 45_203)
        #expect(rebound == 45_206)
    }

    /** The walk wraps from the top of the rebind range to its bottom. */
    @Test func aSiblingRebindWrapsAtTheTopOfItsRange() async {
        let spec = ServerSpec(command: ["serve"], name: "web", port: 3000)
        let top = SiblingRebind.range.upperBound
        let rebound = await SiblingRebind.search(
            isListening: { _ in false }, reserved: [top], spec: spec, start: top)
        #expect(rebound == SiblingRebind.range.lowerBound)
    }

    /** A start below the range (a low declared port) walks up from itself;
        only a walk past the top lands in the range's bottom. */
    @Test func aSiblingRebindBelowItsRangeWalksUpFromTheStart() async {
        let spec = ServerSpec(command: ["serve"], name: "web", port: 3000)
        let rebound = await SiblingRebind.search(
            isListening: { $0 == 3_001 }, reserved: [3_002], spec: spec, start: 3_001)
        #expect(rebound == 3_003)
    }

    /** Once every candidate it tries is taken, the search stops after
        `attempts` and hands back the next port, which then fails the ordinary
        port-held way. */
    @Test func aSiblingRebindGivesUpAfterItsAttempts() async {
        let spec = ServerSpec(command: ["serve"], name: "web", port: 3000)
        let probed = OSAllocatedUnfairLock(initialState: 0)
        let rebound = await SiblingRebind.search(
            isListening: { _ in probed.withLock { $0 += 1 }; return true }, reserved: [], spec: spec,
            start: 20_000)
        #expect(rebound == 20_000 + SiblingRebind.attempts)
        #expect(probed.withLock { $0 } == SiblingRebind.attempts)
    }

    /** The candidate never passes the top of the range the search walks. */
    @Test func aSiblingPortCandidateNeverStartsAboveTheRange() {
        #expect(
            CheckoutIdentity.siblingPortCandidate(declared: 65_500, project: "/tmp/proj-a")
                == SiblingRebind.range.upperBound)
        #expect(CheckoutIdentity.siblingPortCandidate(declared: 1, project: "/tmp/proj-a") >= 1024)
    }

    /** Which ports each phase holds, the question every port check asks.
        `stopping` holds nothing although it still counts as a live run. */
    @Test func heldPortsFollowThePhase() {
        let claim = PortClaim.resolve(spec: spanSpec, effectivePort: 45_200).claim
        let named = ["admin": 45_300]
        let whole: Set<Int> = [45_200, 45_201, 45_202, 45_300]
        var held: [ServerPhase: Set<Int>] = [:]
        for phase in ServerPhase.allCases {
            held[phase] = status(observedPort: 45_201, phase: phase, pid: 7, ports: named)
                .heldPorts(claim: claim)
        }
        #expect(
            held == [
                .crashed: [], .failed: [45_201], .running: whole, .starting: whole, .stopped: [],
                .stopping: [], .unhealthy: whole,
            ])
        #expect(status(observedPort: 45_201, phase: .failed).heldPorts(claim: claim) == [])
        #expect(status(phase: .failed, pid: 7).heldPorts(claim: claim) == [])
    }

    /** A port failure keeps its process, so it is the one terminal-looking
        phase that can still have a live run. */
    @Test func hasLiveRunCountsALivePortFailedRun() {
        var live: [ServerPhase: [Bool]] = [:]
        for phase in ServerPhase.allCases {
            live[phase] = [phase.hasLiveRun(pid: nil), phase.hasLiveRun(pid: 7)]
        }
        #expect(
            live == [
                .crashed: [false, false], .failed: [false, true], .running: [true, true],
                .starting: [true, true], .stopped: [false, false], .stopping: [true, true],
                .unhealthy: [true, true],
            ])
        #expect(status(phase: .failed, pid: 7).hasLiveRun)
        #expect(!status(phase: .failed).hasLiveRun)
    }
}
