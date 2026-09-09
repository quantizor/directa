import DirectaKit
import Foundation
import Testing

@testable import directa

/** The incident: a session wiped a local database directory to re-run migrations
    with the declaring server left running (the default). The lock serialized
    access, the still-running server held the old file open and flushed its cached
    pages back over the migrated one, and the migration reported success while the
    seeded rows were gone. Nothing in the output distinguished that from a clean
    run. */
@Suite struct LockIdentityTests {
    private let file = ResourceIdentity(
        bytes: 10, digest: "aaa", entryCount: 1, inode: "1:2", kind: .file)

    @Test func changedWithALiveServerIsAFault() throws {
        let after = ResourceIdentity(
            bytes: 10, digest: "aaa", entryCount: 1, inode: "1:9", kind: .file)
        let verdict = LockIdentityVerdict.of(
            after: after, before: file, live: ["db"], resource: "d1",
            statePath: "/p/state")
        guard case .fault(let error) = verdict else {
            Issue.record("expected a fault, got \(verdict)")
            return
        }
        #expect(error.code == .resourceMutated)
        #expect(
            error.message
                == "resource 'd1' state at /p/state changed (it was replaced) while db stayed running. That server holds the old state open and can write cached pages back over the change, so what is on disk is not what the command wrote."
        )
        #expect(error.hint == "directa lock d1 --pause -- <command>")
    }

    @Test func theFaultNamesEveryLiveServerSortedAndHintsPause() throws {
        let after = ResourceIdentity(
            bytes: 11, digest: "bbb", entryCount: 1, inode: "1:2", kind: .file)
        let verdict = LockIdentityVerdict.of(
            after: after, before: file, live: ["web", "db"], resource: "d1", statePath: "/p/s")
        guard case .fault(let error) = verdict else {
            Issue.record("expected a fault")
            return
        }
        #expect(error.hint == "directa lock d1 --pause -- <command>")
        /** Plural subject when more than one server stayed up, listed sorted. */
        #expect(error.message.contains("while db, web stayed running"))
        #expect(error.message.contains("Those servers hold the old state open"))
    }

    /** With the declarers stopped (`--pause`) a change is the entire point, so
        it is information rather than a fault. */
    @Test func changedWithNothingRunningIsANote() {
        let after = ResourceIdentity(
            bytes: 12, digest: "ccc", entryCount: 1, inode: "1:2", kind: .file)
        let verdict = LockIdentityVerdict.of(
            after: after, before: file, live: [], resource: "d1", statePath: "/p/state")
        #expect(
            verdict
                == .note(
                    "directa lock: note: 'd1' state at /p/state changed during this hold (its size changed). Nothing was running against it."
                ))
    }

    @Test func unchangedStateIsSilent() {
        #expect(
            LockIdentityVerdict.of(
                after: file, before: file, live: ["db"], resource: "d1", statePath: "/p/s")
                == .silent)
    }

    @Test func aRemovedResourceWithALiveServerReadsAsRemoved() throws {
        let gone = ResourceIdentity(kind: .missing)
        let verdict = LockIdentityVerdict.of(
            after: gone, before: file, live: ["db"], resource: "d1", statePath: "/p/s")
        guard case .fault(let error) = verdict else {
            Issue.record("expected a fault")
            return
        }
        #expect(error.message.contains("(it was removed)"))
    }

    @Test func aCreatedResourceWithALiveServerReadsAsCreated() throws {
        let verdict = LockIdentityVerdict.of(
            after: file, before: ResourceIdentity(kind: .missing), live: ["db"], resource: "d1",
            statePath: "/p/s")
        guard case .fault(let error) = verdict else {
            Issue.record("expected a fault")
            return
        }
        #expect(error.message.contains("(it was created)"))
    }
}
