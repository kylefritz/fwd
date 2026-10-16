import Testing
@testable import FwdCore

@Suite struct ControlTargetTests {
    let hosts = ["devbox", "gpu-box", "8080"]

    func resolve(_ args: [String], connected: [String] = []) throws -> ControlTarget {
        try ControlTarget.resolve(args, hosts: hosts, defaultHosts: connected, noun: "connected")
    }

    @Test func aKnownHostComesFirst() throws {
        #expect(try resolve(["devbox", "3000"]) == ControlTarget(host: "devbox", ports: ["3000"]))
        // A host named like a port is still the host, since it's known.
        #expect(try resolve(["8080", "3000"]) == ControlTarget(host: "8080", ports: ["3000"]))
    }

    @Test func namesFollowTheirPortAndQuotedPortsStayWhole() throws {
        #expect(try resolve(["devbox", "5173", "web", "8000", "api"]).ports == ["5173 web", "8000 api"])
        #expect(try resolve(["devbox", "5173 web", "3000 -> 4000"]).ports == ["5173 web", "3000 -> 4000"])
        #expect(try resolve(["devbox", "3000->4000", "31**"]).ports == ["3000->4000", "31**"])
    }

    @Test func theHostCanBeLeftOutWithExactlyOneConnected() throws {
        #expect(try resolve(["3000"], connected: ["devbox"]) == ControlTarget(host: "devbox", ports: ["3000"]))
        #expect(throws: ControlError.usage("no host is connected; say which, like: fwd devbox 3000")) {
            try resolve(["3000"])
        }
        #expect(throws: ControlError.usage("2 hosts are connected (devbox, gpu-box); say which, like: fwd devbox 3000")) {
            try resolve(["3000"], connected: ["devbox", "gpu-box"])
        }
    }

    @Test func aTypoIsNotAForward() {
        #expect(throws: ControlError.usage("\"stauts\" isn't a command, a host or a port (try fwd --help)")) {
            try resolve(["stauts"], connected: ["devbox"])
        }
        #expect(throws: ControlError.self) { try resolve(["devbox", "3000", "web", "extra"]) }
        #expect(throws: ControlError.self) { try resolve(["devbox", "web"]) }
    }

    @Test func noPortsIsFineHereForCommandsThatTakeNone() throws {
        #expect(try resolve(["devbox"]) == ControlTarget(host: "devbox", ports: []))
        #expect(try resolve([], connected: ["devbox"]) == ControlTarget(host: "devbox", ports: []))
    }

    @Test func canonicalTextMatchesHowEntriesAreStored() {
        #expect(ControlTarget.canonical("3000->4000 web") == "3000 -> 4000")
        #expect(ControlTarget.canonical("03000") == "3000")
        #expect(ControlTarget.canonical("banana") == nil)
    }
}
