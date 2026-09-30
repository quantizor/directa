import ArgumentParser
import DirectaKit
import Foundation
import Testing

@testable import directa

/** `directa up <name>` and `directa down <name>` used to reject a server name
    outright ("Unexpected argument", exit 64) while every other single-server
    command (`ensure`, `restart`, `stop`, `wait`, …) took one. `<name>` is
    shorthand for `--only <name>` under `up`; `--only` and `<name>` name two
    conflicting subsets when both are given. */
@Suite struct GroupCommandParsingTests {
    @Test func upAcceptsAPositionalServerName() throws {
        let up = try Up.parse(["web"])
        #expect(up.name == "web")
        #expect(up.only == nil)
    }

    @Test func upWithNoArgumentsTargetsTheWholeProject() throws {
        let up = try Up.parse([])
        #expect(up.name == nil)
        #expect(up.only == nil)
    }

    @Test func upStillAcceptsOnlyAloneForACommaSeparatedSubset() throws {
        let up = try Up.parse(["--only", "web,api"])
        #expect(up.name == nil)
        #expect(up.only == "web,api")
    }

    @Test func upUsageErrorIsNilWithEitherAloneOrNeither() {
        #expect(Up.usageError(name: nil, only: nil) == nil)
        #expect(Up.usageError(name: "web", only: nil) == nil)
        #expect(Up.usageError(name: nil, only: "web") == nil)
    }

    @Test func upUsageErrorFiresWhenNameAndOnlyAreBothGiven() throws {
        let up = try Up.parse(["web", "--only", "api"])
        let error = try #require(Up.usageError(name: up.name, only: up.only))
        #expect(error.code == .usage)
        #expect(error.hint == "run: directa up web")
        #expect(error.message == "pass a server name or --only, not both")
    }

    @Test func downAcceptsAPositionalServerName() throws {
        let down = try Down.parse(["api"])
        #expect(down.name == "api")
    }

    @Test func downWithNoArgumentsTargetsTheWholeProject() throws {
        let down = try Down.parse([])
        #expect(down.name == nil)
    }

    /** `down <name>` never pulls in dependents (the opposite of `up`'s
        `--only`), so a named server goes straight to `server.stop`, which
        every daemon build understands, rather than `group.down`'s `only`
        (a proto addition an older daemon ignores, silently stopping the
        whole project instead of just the one server). */
    @Test func downWithANameBuildsAServerStopRequest() {
        let request = Down.request(name: "api", project: "/p")
        #expect(
            request
                == .server(ServerTargetParams(name: "api", project: "/p")))
    }

    @Test func downWithNoNameBuildsAnUnscopedGroupDownRequest() {
        let request = Down.request(name: nil, project: "/p")
        #expect(request == .group(GroupParams(project: "/p")))
    }
}
