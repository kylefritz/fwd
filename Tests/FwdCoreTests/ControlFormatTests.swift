import Testing
@testable import FwdCore

@Suite struct ControlFormatTests {
    let web = PortInfo(port: "5173 -> 15173", name: "web", on: true, keep: true, state: "live", reason: nil,
                       local: 15173, url: "http://localhost:15173", forwards: [])
    let api = PortInfo(port: "8000", name: nil, on: true, keep: false, state: "waiting", reason: nil,
                       local: 8000, url: "http://localhost:8000", forwards: [])
    let off = PortInfo(port: "9229", name: "debug", on: false, keep: false, state: "off", reason: nil,
                       local: nil, url: nil, forwards: [])

    var devbox: HostInfo {
        HostInfo(host: "devbox", state: "connected", status: "Connected · 2 forwarded", inSSHConfig: true, ports: [web, api, off])
    }

    @Test func forwardListsEachPortWithItsURL() {
        let text = ControlFormat.human(.success(host: devbox), command: "forward")
        #expect(text == """
            devbox  web 5173 -> 15173  http://localhost:15173  live     kept
            devbox  8000               http://localhost:8000   waiting  nothing listening on the remote yet
            devbox  debug 9229                                 off
            """)
    }

    @Test func statusGroupsPortsUnderTheirHost() {
        let text = ControlFormat.human(.success(hosts: [devbox]), command: "status")
        #expect(text.hasPrefix("devbox  Connected · 2 forwarded\n  web 5173 -> 15173"))
        #expect(ControlFormat.human(.success(hosts: []), command: "status") == "No hosts with ports. Forward one with: fwd <host> <port>")
    }

    @Test func failuresAndScreen() {
        #expect(ControlFormat.human(.failure(.usage("say which")), command: "forward") == "fwd: say which")
        #expect(ControlFormat.human(.success(host: devbox, url: "vnc://kyle@localhost:5901"), command: "screen")
                == "vnc://kyle@localhost:5901")
    }

    @Test func jsonIsOneLine() {
        let json = ControlFormat.json(.success(host: devbox))
        #expect(!json.contains("\n"))
        #expect(json.hasPrefix("{\"host\":{"))
    }
}
