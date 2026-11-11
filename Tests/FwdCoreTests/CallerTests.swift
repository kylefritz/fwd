import Foundation
import Testing
@testable import FwdCore

@MainActor
@Suite struct CallerTests {
    @Test func aProcessIsFoundWithItsAncestorsUpToLaunchd() {
        let me = Caller.of(pid: getpid())
        #expect(me.chain.first?.pid == getpid())
        #expect(me.chain.count >= 2, "the test runner was started by something")
        #expect(me.chain.last?.pid == 1, "the chain ends at launchd")
        #expect(me.chain.last?.name == "launchd")
        #expect(me.chain.dropFirst().first?.pid == getppid())
        #expect(me.chain.first?.arguments.isEmpty == false)
        #expect(Set(me.chain.map(\.pid)).count == me.chain.count)
    }

    @Test func theSummaryNamesWhatRanTheCommandAndNeverItsArguments() {
        let caller = Caller(chain: [
            .init(pid: 30, name: "fwd", arguments: ["fwd", "devbox", "7440"]),
            .init(pid: 20, name: "sh", arguments: ["sh", "-c", "TOKEN=hunter2 fwd devbox 7440"]),
            .init(pid: 10, name: "node", arguments: ["node", "watcher.js"]),
            .init(pid: 1, name: "launchd"),
        ])
        #expect(caller.summary == "sh ← node ← launchd")
        #expect(!caller.summary.contains("hunter2"))
        #expect(Caller(chain: []).summary == "unknown")
        // A parent that couldn't be read leaves a visible gap, not a short chain.
        let cut = Caller(chain: [.init(pid: 30, name: "fwd"), .init(pid: 20, name: "sh")])
        #expect(!cut.complete)
        #expect(cut.summary == "sh ← ?")
    }

    @Test func theServerSeesWhoConnected() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-c-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("c.sock").path
        var seen: Caller?
        let server = ControlServer(path: path, handleFrom: { _, caller in
            seen = caller
            return .success(hosts: [])
        })
        try server.start()
        defer { server.stop() }
        let reply = try await Task.detached {
            try ControlClient.send(ControlRequest(cmd: "status"), to: path, timeout: 5)
        }.value
        #expect(reply.ok)
        #expect(seen?.chain.first?.pid == getpid(), "this test is the command here")
    }

    @Test func repeatedCommandsFromOneCallerAreOneRowWithACount() {
        let log = CommandLog()
        let script = Caller(chain: [.init(pid: 3, name: "fwd"), .init(pid: 2, name: "node"), .init(pid: 1, name: "launchd")])
        let shell = Caller(chain: [.init(pid: 9, name: "fwd"), .init(pid: 8, name: "zsh"), .init(pid: 1, name: "launchd")])
        let start = Date()
        for i in 0..<12 { log.record(command: "forward devbox 7440", caller: script, at: start.addingTimeInterval(Double(i))) }
        log.record(command: "forward devbox 7440", caller: shell, at: start.addingTimeInterval(20))
        log.record(command: "status", caller: nil, at: start.addingTimeInterval(30))
        #expect(log.entries.map(\.command) == ["status", "forward devbox 7440", "forward devbox 7440"], "newest first")
        #expect(log.entries.map(\.count) == [1, 1, 12])
        #expect(log.entries.last?.caller?.summary == "node ← launchd")
        #expect(log.entries.last?.last == start.addingTimeInterval(11))

        for i in 0..<(CommandLog.limit + 5) { log.record(command: "status \(i)", caller: nil) }
        #expect(log.entries.count == CommandLog.limit)
    }

    @Test func theLogNamesTheCallerAndFlagsALoop() async throws {
        let rig = try AppModelTests.Rig()
        await rig.model.start(runTimer: false)
        let handler = ControlHandler(model: rig.model, open: { _ in }, pollInterval: 0.02)
        let caller = Caller(chain: [
            .init(pid: 3, name: "fwd"),
            .init(pid: 2, name: "node", arguments: ["node", "--token=hunter2"]),
            .init(pid: 1, name: "launchd"),
        ])
        for _ in 0..<CommandLog.loopAt { _ = await handler.handle(ControlRequest(cmd: "status"), caller: caller) }
        // Options are part of what ran; a lookup that failed says so.
        let cut = Caller(chain: [.init(pid: 3, name: "fwd"), .init(pid: 2, name: "sh")])
        _ = await handler.handle(ControlRequest(cmd: "status", all: true), caller: cut)
        _ = await handler.handle(ControlRequest(cmd: "status", all: true))
        #expect(rig.model.commands.entries.map(\.command).contains("status --all"))
        rig.model.log.flush()
        let text = try String(contentsOf: rig.model.paths.logFile, encoding: .utf8)
        #expect(text.contains("cli: status --all (from sh ← ?)"))
        #expect(text.contains("couldn't read what started sh (pid 2)"))
        #expect(text.contains("cli: status --all (caller unknown: the socket didn't give the command's process)"))
        #expect(text.contains("cli: status (from node ← launchd)"))
        #expect(text.contains("that's \(CommandLog.loopAt) runs of \"status\""))
        #expect(!text.contains("hunter2"), "arguments never reach the log")
        #expect(rig.model.commands.entries.last?.count == CommandLog.loopAt)
        await rig.model.shutdown()
    }
}
