import Foundation
import Testing
@testable import FwdCore

@Suite struct ControlProtocolTests {
    @Test func requestsAndRepliesRoundTripAsOneLine() throws {
        let request = ControlRequest(cmd: "forward", args: ["devbox", "3000"], keep: true, timeout: 12)
        let line = request.encodedLine()
        #expect(line.last == UInt8(ascii: "\n"))
        #expect(!line.dropLast().contains(UInt8(ascii: "\n")))
        #expect(try ControlRequest.decode(line) == request)
        #expect(request.v == ControlRequest.version)

        let reply = ControlReply.failure(.usage("say which host"))
        #expect(try ControlReply.decode(reply.encodedLine()) == reply)
        #expect(reply.exitCode == .usage)
        #expect(ControlReply.success(hosts: []).exitCode == .ok)
    }

    @Test func aPortShowsItsStateURLAndNulls() throws {
        let pill = Pill(text: "5173 -> 15173", on: true, state: .live, isWildcard: false, local: 15173,
                        label: "5173 → 15173", moved: false, ports: [], remote: 5173, name: "web", keep: true)
        let info = PortInfo(pill: pill)
        #expect(info == PortInfo(port: "5173 -> 15173", name: "web", on: true, keep: true, state: "live",
                                 reason: nil, local: 15173, url: "http://localhost:15173", forwards: []))
        // Every field is present, null or not, so agents can rely on the shape.
        let json = String(decoding: try JSONEncoder().encode(PortInfo(pill: Pill(
            text: "9229", on: false, state: .off, isWildcard: false, local: nil, label: "9229",
            moved: false, ports: [], remote: 9229, name: nil, keep: false))), as: UTF8.self)
        for key in ["\"name\":null", "\"reason\":null", "\"local\":null", "\"url\":null"] {
            #expect(json.contains(key), "\(key) in \(json)")
        }
    }

    @Test func statesHaveStableNames() {
        func port(_ state: PillState) -> PortInfo {
            PortInfo(pill: Pill(text: "1", on: true, state: state, isWildcard: false, local: nil, label: "1",
                                moved: false, ports: [], remote: 1, name: nil, keep: false))
        }
        #expect(port(.pending).state == "pending")
        #expect(port(.waiting).state == "waiting")
        #expect(port(.active).state == "active")
        #expect(port(.blocked("taken")).state == "blocked")
        #expect(port(.blocked("taken")).reason == "taken")
        #expect(HostInfo.stateName(.needsAttention("x")) == "needs-attention")
        #expect(HostInfo.stateName(.paused("asleep")) == "paused")
        #expect(HostInfo.stateName(.standby) == "standby")
    }

    @Test func aHostCanShowOnlyTheNamedPorts() {
        let pills = ["3000", "8000"].map {
            Pill(text: $0, on: true, state: .waiting, isWildcard: false, local: Int($0), label: $0,
                 moved: false, ports: [], remote: Int($0), name: nil, keep: false)
        }
        let card = HostCard(name: "devbox", state: .connected, statusLine: "Connected · 2 forwarded",
                            pills: pills, configPills: [], lastError: nil, inConfig: true)
        #expect(HostInfo(card: card).ports.count == 2)
        #expect(HostInfo(card: card, only: ["8000"]).ports.map(\.port) == ["8000"])
        #expect(HostInfo(card: card).inSSHConfig)
    }

    @Test func theControlSocketLivesInTheSocketFolder() {
        let paths = tempPaths()
        #expect(paths.controlSocket.deletingLastPathComponent().path == paths.socketDir.path)
        #expect(paths.controlSocket.lastPathComponent == "control.sock")
    }
}
