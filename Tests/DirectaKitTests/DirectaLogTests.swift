import Testing

@testable import DirectaKit

/** Serialized: every case swaps the process-global `DirectaLog.backend`, so
    parallel cases would clobber each other's recorder. */
@Suite(.serialized) struct DirectaLogTests {
    /** Installs a recorder for the duration of `body`, then restores the default
        backend so one suite's swap never leaks into another. */
    private func withRecorder(_ body: (RecordingBackend) -> Void) {
        let previous = DirectaLog.backend
        defer { DirectaLog.backend = previous }
        let recorder = RecordingBackend()
        DirectaLog.backend = recorder
        body(recorder)
    }

    @Test func categoryLoggerCapturesLevelAndCategory() {
        withRecorder { recorder in
            DirectaLog.deeplink.info("dispatched ensure")
            DirectaLog.deeplink.error("rejected slug")
            DirectaLog.daemon.debug("tick")
            #expect(
                recorder.entries == [
                    .init(category: .deeplink, level: .info, message: "dispatched ensure"),
                    .init(category: .deeplink, level: .error, message: "rejected slug"),
                    .init(category: .daemon, level: .debug, message: "tick"),
                ])
        }
    }

    @Test func resetClearsEntries() {
        withRecorder { recorder in
            DirectaLog.supervisor.info("first")
            recorder.reset()
            DirectaLog.supervisor.info("second")
            #expect(recorder.messages == ["second"])
        }
    }

    @Test func subsystemIsStable() {
        #expect(DirectaLog.subsystem == "dev.quantizor.directa")
    }

    /** The exact process name `swift test` runs every suite under (measured via
        `log show --process`), so a build reaching this default keeps its
        error/info calls out of the developer's real unified log. */
    @Test func defaultBackendIsARecorderUnderTheSwiftTestHost() {
        #expect(DirectaLog.defaultBackend(processName: "swiftpm-testing-helper") is RecordingBackend)
    }

    @Test func defaultBackendIsOSLogElsewhere() {
        #expect(DirectaLog.defaultBackend(processName: "ddirecta") is OSLogBackend)
    }

    /** End to end, not just the pure decision: the process actually running
        these tests must have picked up the recording default, since nothing in
        this file sets it before this test runs. */
    @Test func theRunningTestProcessDefaultsToARecorder() {
        #expect(DirectaLog.backend is RecordingBackend)
    }
}
