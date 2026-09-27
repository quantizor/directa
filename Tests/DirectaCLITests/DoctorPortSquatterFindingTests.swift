import DirectaKit
import Foundation
import Testing

@testable import directa

/** `Doctor.portSquatterFindings`: a down server whose declared port has a
    listener no managed server accounts for. The probe and the checkout check
    are injected, so every branch runs without binding a port. */
@Suite struct DoctorPortSquatterFindingTests {
    private func status(
        effective: Int? = nil, phase: ServerPhase, pid: Int? = nil, port: Int?,
        project: String = "/code/a", server: String
    ) -> ServerStatus {
        var status = ServerStatus(
            declaredPort: port,
            effectivePort: effective ?? port,
            logPath: "/tmp/\(server).log",
            phase: phase,
            project: project,
            server: server)
        status.pid = pid
        return status
    }

    private func lines(
        _ servers: [ServerStatus], listening: Set<Int>, missingProjects: Set<String> = []
    ) -> [String] {
        Doctor.portSquatterFindings(
            servers: servers, isListening: { listening.contains($0) },
            projectExists: { !missingProjects.contains($0) }
        ).map { "[\($0.severity.rawValue)] \($0.kind.rawValue): \($0.detail)" }
    }

    @Test func aStoppedServerWithAForeignListenerIsReported() {
        #expect(
            lines([status(phase: .stopped, port: 3000, server: "web")], listening: [3000]) == [
                "[warning] port-squatter: port 3000 has an unmanaged listener while web is down"
            ])
    }

    @Test(arguments: [ServerPhase.crashed, .failed, .stopped])
    func everyDownPhaseWithoutAProcessIsACandidate(phase: ServerPhase) {
        #expect(lines([status(phase: phase, port: 3000, server: "web")], listening: [3000]).count == 1)
    }

    @Test func aQuietPortIsNotReported() {
        #expect(lines([status(phase: .stopped, port: 3000, server: "web")], listening: [3001]).isEmpty)
    }

    /** The listener is the server's own run: running, starting, unhealthy,
        stopping, or a port-failed run whose process is still up. */
    @Test(arguments: [
        (ServerPhase.running, 42), (.starting, 42), (.unhealthy, 42), (.stopping, 42), (.failed, 42),
    ])
    func aServerWithALiveRunIsNeverItsOwnSquatter(phase: ServerPhase, pid: Int) {
        #expect(
            lines([status(phase: phase, pid: pid, port: 3000, server: "web")], listening: [3000])
                .isEmpty)
    }

    @Test func aServerWithoutADeclaredPortIsSkipped() {
        #expect(lines([status(phase: .stopped, port: nil, server: "worker")], listening: [3000]).isEmpty)
    }

    /** Another supervised server up on the port owns the listener; calling it
        unmanaged would be wrong. */
    @Test(arguments: [ServerPhase.running, .starting, .unhealthy])
    func aManagedOwnerInAHoldingPhaseSuppressesTheFinding(ownerPhase: ServerPhase) {
        let servers = [
            status(phase: .stopped, port: 3000, server: "web"),
            status(phase: ownerPhase, pid: 7, port: 3000, project: "/code/b", server: "rival"),
        ]
        #expect(lines(servers, listening: [3000]).isEmpty)
    }

    /** An owner matches on its effective port, so one rebound away from the
        shared declared port does not explain the listener. */
    @Test func anOwnerReboundElsewhereDoesNotExplainTheListener() {
        let servers = [
            status(phase: .stopped, port: 3000, server: "web"),
            status(effective: 3742, phase: .running, pid: 7, port: 3000, project: "/code/b", server: "sib"),
        ]
        #expect(
            lines(servers, listening: [3000]) == [
                "[warning] port-squatter: port 3000 has an unmanaged listener while web is down"
            ])
    }

    @Test func anOwnerThatIsStoppingDoesNotCount() {
        let servers = [
            status(phase: .stopped, port: 3000, server: "web"),
            status(phase: .stopping, pid: 7, port: 3000, project: "/code/b", server: "rival"),
        ]
        #expect(lines(servers, listening: [3000]).count == 1)
    }

    /** The same name in another project is a different server, so it can own
        the port; only the server itself is excluded from the owner search. */
    @Test func theSameServerNameInAnotherProjectCanOwnThePort() {
        let servers = [
            status(phase: .stopped, port: 3000, project: "/code/a", server: "web"),
            status(phase: .running, pid: 7, port: 3000, project: "/code/b", server: "web"),
        ]
        #expect(lines(servers, listening: [3000]).isEmpty)
    }

    @Test func aServerWhoseCheckoutIsGoneIsNotACandidate() {
        #expect(
            lines(
                [status(phase: .stopped, port: 3000, project: "/gone", server: "web")],
                listening: [3000], missingProjects: ["/gone"]
            ).isEmpty)
    }

    @Test func aLiveRunInAMissingCheckoutStillOwnsThePort() {
        let servers = [
            status(phase: .stopped, port: 3000, project: "/code/a", server: "web"),
            status(phase: .running, pid: 7, port: 3000, project: "/gone", server: "old"),
        ]
        #expect(lines(servers, listening: [3000], missingProjects: ["/gone"]).isEmpty)
    }

    /** The JSON a finding encodes to is the `--json` contract. */
    @Test func aFindingEncodesItsKindAndSeverityAsTheContractStrings() throws {
        let finding = Doctor.Finding(detail: "d", kind: .portSquatter, severity: .warning)
        #expect(
            String(decoding: try JSONCoding.encoder().encode(finding), as: UTF8.self)
                == #"{"detail":"d","kind":"port-squatter","severity":"warning"}"#)
    }

    @Test func noServersNoFindings() {
        #expect(lines([], listening: [3000]).isEmpty)
    }
}
