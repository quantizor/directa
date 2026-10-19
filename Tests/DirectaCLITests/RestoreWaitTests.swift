import DirectaKit
import Foundation
import Testing

@testable import directa

/** The CLI waits out `daemon-starting` only while the daemon says it is
    restoring. The same code also refuses a request for one server whose
    surviving process is undecided, and that refusal fails at once with its own
    message and hint. */
@Suite struct RestoreWaitTests {
    private static let perServer = WireError(
        code: .daemonStarting, hint: "run: directa daemon restart",
        message: "'web' still has its process (pid 41) from before the daemon restarted")

    private static func info(restoring: Bool?) -> DaemonInfo {
        DaemonInfo(
            dataDir: "/data", daemonVersion: "0", logsDir: "/logs", pid: 1, proto: 1,
            restoring: restoring, socketPath: "/sock")
    }

    private final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int { lock.withLock { count } }

        func next() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }
    }

    @Test func aServingDaemonsRefusalIsPerServer() {
        #expect(CLIRunner.refusalIsPerServer(info: Self.info(restoring: nil)))
        #expect(CLIRunner.refusalIsPerServer(info: Self.info(restoring: false)))
    }

    @Test func aRestoringOrSilentDaemonIsWaitedOn() {
        #expect(!CLIRunner.refusalIsPerServer(info: Self.info(restoring: true)))
        #expect(!CLIRunner.refusalIsPerServer(info: nil))
    }

    /** Restore finishing between the refusal and the info read makes the same
        request succeed, so a not-restoring answer retries it once at once. */
    @Test func aRefusalThatRestoreFinishedBehindIsRetriedOnce() async throws {
        let attempts = Attempts()
        let result: String = try await CLIRunner.awaitingRestore(
            budget: .seconds(30), pollInterval: .milliseconds(1),
            readInfo: { Self.info(restoring: nil) }
        ) { _ in
            if attempts.next() == 1 { throw Self.perServer }
            return "served"
        }
        #expect(result == "served")
        #expect(attempts.value == 2)
    }

    /** The daemon's own message and hint reach the caller when the retry is
        refused again, with no wait. */
    @Test func aPerServerRefusalFailsAtOnceWithTheDaemonsMessage() async throws {
        let attempts = Attempts()
        do {
            let _: WireEmpty = try await CLIRunner.awaitingRestore(
                budget: .seconds(30), pollInterval: .milliseconds(1),
                readInfo: { Self.info(restoring: nil) }
            ) { _ in
                _ = attempts.next()
                throw Self.perServer
            }
            Issue.record("the refusal was swallowed")
        } catch let error as WireError {
            #expect(error == Self.perServer)
        }
        #expect(attempts.value == 2)
    }

    /** A daemon still restoring is retried until it serves, then the request
        goes through. */
    @Test func aRestoringDaemonIsWaitedOutUntilItServes() async throws {
        let attempts = Attempts()
        let result: String = try await CLIRunner.awaitingRestore(
            budget: .seconds(30), pollInterval: .milliseconds(1),
            readInfo: { Self.info(restoring: true) }
        ) { _ in
            if attempts.next() < 3 { throw WireError(code: .daemonStarting, message: "restoring") }
            return "served"
        }
        #expect(result == "served")
        #expect(attempts.value == 3)
    }

    /** A restore that never finishes still ends at the budget with the
        daemon's refusal. */
    @Test func aRestoreThatNeverFinishesFailsAtTheBudget() async throws {
        let attempts = Attempts()
        do {
            let _: WireEmpty = try await CLIRunner.awaitingRestore(
                budget: .milliseconds(30), pollInterval: .milliseconds(1),
                readInfo: { Self.info(restoring: true) }
            ) { _ in
                _ = attempts.next()
                throw WireError(code: .daemonStarting, message: "restoring")
            }
            Issue.record("the refusal was swallowed")
        } catch let error as WireError {
            #expect(error.code == .daemonStarting)
        }
        #expect(attempts.value > 1)
    }
}
