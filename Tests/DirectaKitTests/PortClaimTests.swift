import Foundation
import Testing

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
}
