import Foundation
import Testing

@testable import DirectaKit

@Suite struct DaemonRestartDetailTests {
    @Test func matchesEveryShapeItWrites() {
        #expect(DaemonRestartDetail.matches(DaemonRestartDetail.crashed))
        #expect(DaemonRestartDetail.matches(DaemonRestartDetail.orphanBounced(pid: 42)))
        #expect(DaemonRestartDetail.matches(DaemonRestartDetail.adopted(pid: 42)))
    }

    @Test func rejectsADetailThatMerelyContainsTheMarker() {
        #expect(!DaemonRestartDetail.matches("watch change in configs/daemon-restart/app.json"))
        #expect(!DaemonRestartDetail.matches("watch suspended: daemon-restart-tool.json"))
        #expect(!DaemonRestartDetail.matches("requested by stop"))
        #expect(!DaemonRestartDetail.matches("code=1"))
    }

    /** A watched path can end in the adopt shape's suffix or start with the
        bounce shape's prefix; only the exact shapes with a numeric pid match. */
    @Test func rejectsADetailThatSharesOnlyTheShapesPrefixOrSuffix() {
        #expect(!DaemonRestartDetail.matches("watch change in /p/x across daemon-restart"))
        #expect(!DaemonRestartDetail.matches("daemon-restart: watch change in /p/x"))
        #expect(!DaemonRestartDetail.matches("adopted pid abc across daemon-restart"))
        #expect(!DaemonRestartDetail.matches("daemon-restart: orphan pid 12x bounced"))
        #expect(!DaemonRestartDetail.matches("daemon-restart: orphan pid  bounced"))
    }
}

@Suite struct ExternalSignalDetailTests {
    @Test func matchesEverySignalItFormats() {
        #expect(ExternalSignalDetail.matches(ExternalSignalDetail.format(signal: 15)))
        #expect(ExternalSignalDetail.matches(ExternalSignalDetail.format(signal: 2)))
    }

    @Test func rejectsADetailThatMerelyContainsTheMarker() {
        #expect(!ExternalSignalDetail.matches("watch change in configs/(external)/app.json"))
        #expect(!ExternalSignalDetail.matches("requested by stop"))
        #expect(!ExternalSignalDetail.matches("signal=abc (external)"))
        #expect(!ExternalSignalDetail.matches("code=1"))
    }
}
