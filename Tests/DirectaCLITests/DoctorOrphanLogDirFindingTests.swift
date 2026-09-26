import DirectaKit
import Foundation
import Testing

@testable import directa

/** `Doctor.orphanLogDirFixFinding` turns one `OrphanProjectLogs.remove`
    outcome into the `orphan-log-dir` finding `doctor --fix` reports: a removal
    is `fixed`, and a refusal or a failed delete is an `error` naming the
    directory, never reported as success. */
@Suite struct DoctorOrphanLogDirFindingTests {
    private let path = URL(fileURLWithPath: "/logs/myproj-abcd1234")

    @Test func aRemovedDirectoryIsFixed() {
        let finding = Doctor.orphanLogDirFixFinding(path: path, outcome: .removed)
        #expect(finding.detail == "removed /logs/myproj-abcd1234, which matched no registered project")
        #expect(finding.kind == "orphan-log-dir")
        #expect(finding.severity == "fixed")
    }

    @Test func aRefusedDirectoryIsLeftInPlaceWithTheReason() {
        let finding = Doctor.orphanLogDirFixFinding(
            path: path, outcome: .refused("a registered project claims it"))
        #expect(finding.detail == "left /logs/myproj-abcd1234 in place: a registered project claims it")
        #expect(finding.kind == "orphan-log-dir")
        #expect(finding.severity == "error")
    }

    @Test func aFailedDeleteKeepsTheSystemMessage() {
        let finding = Doctor.orphanLogDirFixFinding(
            path: path, outcome: .failed("permission denied"))
        #expect(finding.detail == "could not remove /logs/myproj-abcd1234: permission denied")
        #expect(finding.kind == "orphan-log-dir")
        #expect(finding.severity == "error")
    }
}
