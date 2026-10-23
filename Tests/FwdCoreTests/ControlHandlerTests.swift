import Foundation
import Testing
@testable import FwdCore

@MainActor
@Suite struct ControlHandlerTests {
    typealias Rig = AppModelTests.Rig

    func handler(_ rig: Rig, opened: @escaping (URL) -> Void = { _ in }) -> ControlHandler {
        ControlHandler(model: rig.model, open: opened, pollInterval: 0.02)
    }

    @Test func forwardAddsConnectsAndReportsTheURL() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        let reply = await handler(rig).handle(ControlRequest(cmd: "forward", args: ["devbox", "3000", "5173", "web"], timeout: 5))
        #expect(reply.ok, "\(reply)")
        let ports = try #require(reply.host?.ports)
        #expect(ports.map(\.port) == ["3000", "5173"])
        #expect(ports.first?.url == "http://localhost:3000")
        #expect(ports.allSatisfy { $0.state == "waiting" }, "nothing listens in the fake remote")
        #expect(ports.last?.name == "web")
        #expect(rig.card("devbox")?.state == .connected)
        await rig.model.shutdown()
    }

    @Test func forwardWaitWaitsForAServerAndTimesOutWithoutOne() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        let h = handler(rig)
        let quiet = await h.handle(ControlRequest(cmd: "forward", args: ["devbox", "3000"], wait: true, timeout: 0.5))
        #expect(quiet.exitCode == .timedOut)

        rig.box.listening = "#fwd:ss\nLISTEN 0 1 127.0.0.1:3001 0.0.0.0:*\n"
        rig.box.made["devbox"]?.last?.listening = rig.box.listening
        let live = await h.handle(ControlRequest(cmd: "forward", args: ["devbox", "3001"], wait: true, timeout: 5))
        #expect(live.ok, "\(live)")
        #expect(live.host?.ports.first?.state == "live")
        await rig.model.shutdown()
    }

    @Test func theHostCanBeLeftOutOnceOneIsConnected() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        let h = handler(rig)
        #expect(await h.handle(ControlRequest(cmd: "forward", args: ["3000"])).exitCode == .usage)
        _ = await h.handle(ControlRequest(cmd: "forward", args: ["devbox", "3000"], timeout: 5))
        let reply = await h.handle(ControlRequest(cmd: "forward", args: ["4000"], timeout: 5))
        #expect(reply.host?.host == "devbox")
        await rig.model.shutdown()
    }

    @Test func waitNeedsThePortOnAndTimesOut() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        let h = handler(rig)
        let off = await h.handle(ControlRequest(cmd: "wait", args: ["devbox", "3000"], timeout: 0.3))
        #expect(off.exitCode == .failed)
        #expect(off.error == "3000 isn't on for devbox; run: fwd devbox 3000")
        _ = await h.handle(ControlRequest(cmd: "forward", args: ["devbox", "3000"], timeout: 5))
        #expect(await h.handle(ControlRequest(cmd: "wait", args: ["devbox", "3000"], timeout: 0.3)).exitCode == .timedOut)
        await rig.model.shutdown()
    }

    @Test func aPortThatIsntListedIsAnErrorNotASuccess() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        let h = handler(rig)
        _ = await h.handle(ControlRequest(cmd: "forward", args: ["devbox", "3000"], timeout: 5))
        for cmd in ["off", "remove", "keep"] {
            let reply = await h.handle(ControlRequest(cmd: cmd, args: ["devbox", "3001"]))
            #expect(reply.exitCode == .failed, "\(cmd)")
            #expect(reply.error == "3001 isn't in devbox's list", "\(cmd)")
        }
        await rig.model.shutdown()
    }

    @Test func offRemoveAndKeep() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        let h = handler(rig)
        _ = await h.handle(ControlRequest(cmd: "forward", args: ["devbox", "3000", "4000"], keep: true, timeout: 5))
        #expect(rig.pill("devbox", "3000")?.keep == true)
        #expect(await h.handle(ControlRequest(cmd: "keep", args: ["devbox", "3000"], off: true)).ok)
        #expect(rig.pill("devbox", "3000")?.keep == false)
        #expect(rig.card("devbox")?.state == .connected, "unkeeping a connected host doesn't drop it")
        let off = await h.handle(ControlRequest(cmd: "off", args: ["devbox", "3000"]))
        #expect(off.host?.ports.first?.state == "off")
        #expect(await h.handle(ControlRequest(cmd: "remove", args: ["devbox", "4000"])).ok)
        #expect(rig.pill("devbox", "4000") == nil)
        await rig.model.shutdown()
    }

    @Test func needsAttentionIsAFailureWithTheReason() async throws {
        let rig = try Rig()
        rig.box.startError = .needsAttention("Permission denied (publickey).")
        await rig.model.start(runTimer: false)
        let reply = await handler(rig).handle(ControlRequest(cmd: "forward", args: ["devbox", "3000"], timeout: 5))
        #expect(reply.exitCode == .failed)
        #expect(reply.error == "devbox needs you: Permission denied (publickey). Run: fwd connect devbox after fixing it")
        await rig.model.shutdown()
    }

    @Test func aClickedHostIsNotReportedAsStandbyBeforeItStarts() async throws {
        // Cards rebuild a run-loop turn after a click; the reply must not
        // read the card from before the session started connecting.
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        let reply = await handler(rig).handle(ControlRequest(cmd: "forward", args: ["devbox", "3000"], timeout: 5))
        #expect(reply.ok, "\(reply)")
        await rig.model.shutdown()
    }

    @Test func statusConnectAndScreen() async throws {
        let rig = try Rig()
        rig.box.listening = "#fwd:ss\nLISTEN 0 1 127.0.0.1:5900 0.0.0.0:*\n"
        await rig.model.start(runTimer: false)
        var opened: [URL] = []
        let h = handler(rig) { opened.append($0) }
        _ = await h.handle(ControlRequest(cmd: "forward", args: ["staging", "8080"], timeout: 5))
        let status = await h.handle(ControlRequest(cmd: "status"))
        #expect(status.hosts?.map(\.host) == ["staging"], "only hosts with ports or a connection")
        #expect(await h.handle(ControlRequest(cmd: "status", all: true)).hosts?.count == 3)

        let screen = await h.handle(ControlRequest(cmd: "screen", args: ["devbox"]))
        #expect(screen.url?.hasPrefix("vnc://") == true)
        #expect(opened.count == 1)

        #expect(await h.handle(ControlRequest(cmd: "connect", args: ["homelab"])).exitCode == .failed,
                "nothing on to forward")
        #expect(await h.handle(ControlRequest(cmd: "frobnicate")).exitCode == .usage)
        var old = ControlRequest(cmd: "status")
        old.v = 99
        #expect(await h.handle(old).exitCode == .unreachable)
        await rig.model.shutdown()
    }

    @Test func trySwitchesBuildsAndExplainsItself() async throws {
        let rig = try Rig()
        var asked: [SwitchTarget] = []
        let h = ControlHandler(model: rig.model, open: { _ in },
                               switchBuild: { target, _ in asked.append(target); return "0.2.1-beta.15" }, pollInterval: 0.02)
        let reply = await h.handle(ControlRequest(cmd: "try", args: ["42"]))
        #expect(reply.ok, "\(reply)")
        #expect(ControlFormat.human(reply, command: "try") == "fwd is restarting into PR #42's preview (0.2.1-beta.15).")
        #expect(await h.handle(ControlRequest(cmd: "try", args: ["beta"])).ok)
        #expect(asked == [.pullRequest(42), .beta])

        #expect(await h.handle(ControlRequest(cmd: "try", args: [])).exitCode == .usage)
        #expect(await h.handle(ControlRequest(cmd: "try", args: ["main"])).exitCode == .usage)
        #expect(asked.count == 2)
    }
}
