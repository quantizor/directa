import DirectaTestSupport
import Foundation
import Testing

@testable import DirectaKit

@Suite struct InstallShadowTests {
    @Test func onlyHomebrewCLIIsNotAShadow() {
        #expect(
            InstallShadow.detect(
                foreignApp: nil, homebrewCLI: "/opt/homebrew/bin/directa", localCLI: nil,
                localDaemon: nil, pathWinner: "/opt/homebrew/bin/directa"
            ).isEmpty)
    }

    @Test func onlyManualCLIIsNotAShadow() {
        #expect(
            InstallShadow.detect(
                foreignApp: nil, homebrewCLI: nil, localCLI: "/Users/x/.local/bin/directa",
                localDaemon: "/Users/x/.local/bin/ddirecta", pathWinner: "/Users/x/.local/bin/directa"
            ).isEmpty)
    }

    @Test func coexistingCLIsWarnAndNameTheCleanup() {
        let findings = InstallShadow.detect(
            foreignApp: nil, homebrewCLI: "/opt/homebrew/bin/directa",
            localCLI: "/Users/x/.local/bin/directa", localDaemon: "/Users/x/.local/bin/ddirecta",
            pathWinner: "/Users/x/.local/bin/directa")
        #expect(findings.count == 1)
        #expect(findings[0].detail.contains("two directa CLIs are installed"))
        #expect(findings[0].detail.contains("/opt/homebrew/bin/directa"))
        #expect(findings[0].detail.contains("a bare `directa` runs /Users/x/.local/bin/directa"))
        #expect(findings[0].remedy == "rm /Users/x/.local/bin/directa /Users/x/.local/bin/ddirecta")
    }

    @Test func coexistingCLIsWithNoResolvablePathWinnerStillWarn() {
        let findings = InstallShadow.detect(
            foreignApp: nil, homebrewCLI: "/opt/homebrew/bin/directa",
            localCLI: "/Users/x/.local/bin/directa", localDaemon: nil, pathWinner: nil)
        #expect(findings.count == 1)
        #expect(findings[0].detail.contains("PATH order decides which one runs"))
        #expect(findings[0].remedy == "rm /Users/x/.local/bin/directa")
    }

    @Test func foreignApplicationsAppWarnsWithReinstall() {
        let findings = InstallShadow.detect(
            foreignApp: "/Applications/directa.app", homebrewCLI: "/opt/homebrew/bin/directa",
            localCLI: nil, localDaemon: nil, pathWinner: nil)
        #expect(findings.count == 1)
        #expect(
            findings[0].detail.contains("/Applications/directa.app is not the Homebrew-installed app"))
        #expect(findings[0].remedy.hasPrefix("brew reinstall --cask"))
    }

    @Test func bothProblemsProduceTwoFindings() {
        let findings = InstallShadow.detect(
            foreignApp: "/Applications/directa.app", homebrewCLI: "/opt/homebrew/bin/directa",
            localCLI: "/Users/x/.local/bin/directa", localDaemon: "/Users/x/.local/bin/ddirecta",
            pathWinner: "/Users/x/.local/bin/directa")
        #expect(findings.count == 2)
    }

    @Test(.temporaryTree) func firstOnPathResolvesInPathOrder() throws {
        let dirA = try TemporaryTree.directory(named: "a")
        let dirB = try TemporaryTree.directory(named: "b")

        /** Binary only in the second dir: PATH order picks the second. */
        FileManager.default.createFile(atPath: dirB.appending(path: "directa").path, contents: nil)
        #expect(
            InstallShadow.firstOnPath(
                binary: "directa", pathEnv: "\(dirA.path):\(dirB.path)",
                fileManager: .default) == dirB.appending(path: "directa").path)

        /** Binary in both: the first dir wins, matching shell resolution. */
        FileManager.default.createFile(atPath: dirA.appending(path: "directa").path, contents: nil)
        #expect(
            InstallShadow.firstOnPath(
                binary: "directa", pathEnv: "\(dirA.path):\(dirB.path)",
                fileManager: .default) == dirA.appending(path: "directa").path)

        /** Absent everywhere: no winner. */
        #expect(
            InstallShadow.firstOnPath(binary: "nope", pathEnv: dirA.path, fileManager: .default)
                == nil)
    }
}
