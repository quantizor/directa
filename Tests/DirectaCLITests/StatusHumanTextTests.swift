import DirectaKit
import Testing

@testable import directa

/** `directa status` in human mode: an empty scoped answer names `--all` only
    when another project on the machine has servers. */
@Suite struct StatusHumanTextTests {
    private static let web = ServerStatus(
        logPath: "/logs/web/current.log", phase: .running, pid: 812, project: "/code/app", server: "web")

    @Test func emptyProjectOnAnEmptyMachineOffersRegister() {
        #expect(
            Status.humanText(ServerListResult(servers: []), machineHasServers: false)
                == "no servers registered for this project (hint: directa register --name myproj --cmd …)")
    }

    @Test func emptyProjectOnABusyMachineNamesStatusAll() {
        #expect(
            Status.humanText(ServerListResult(servers: []), machineHasServers: true)
                == "no servers registered for this project, but other projects on this machine have some (hint: directa status --all)")
    }

    @Test func aNonEmptyListIgnoresTheMachineFlag() {
        #expect(
            Status.humanText(ServerListResult(servers: [Self.web]), machineHasServers: true)
                == "web: running  ·  pid 812  ·  log /logs/web/current.log")
    }
}
