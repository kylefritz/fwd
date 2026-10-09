import Foundation
import Testing
@testable import FwdCore

@MainActor
@Suite struct AppModelTests {
    @MainActor final class Rig {
        let paths = tempPaths()
        let model: AppModel

        init(sshConfig: String = "Host devbox\nHost homelab\nHost staging\n") throws {
            var paths = self.paths
            let config = paths.configDir.deletingLastPathComponent().appendingPathComponent("ssh_config")
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sshConfig.write(to: config, atomically: true, encoding: .utf8)
            paths.sshConfigOverride = config
            let box = Box()
            model = AppModel(paths: paths, power: FakePower(),
                             timing: Timing(retrySchedule: [0.05], steadyRetry: 0.1, scanInterval: 0.05, settle: 0.01),
                             makeConnection: { host in
                                 let c = FakeConnection()
                                 box.made[host, default: []].append(c)
                                 return c
                             })
            self.box = box
        }

        final class Box { var made: [String: [FakeConnection]] = [:] }
        let box: Box

        func card(_ name: String) -> HostCard? { model.cards.first { $0.name == name } }
        func pill(_ host: String, _ text: String) -> Pill? { card(host)?.pills.first { $0.text == text } }
        var portsText: String { (try? String(contentsOf: model.paths.portsFile, encoding: .utf8)) ?? "" }
    }

    @Test func listsConfigHostsAndStartsIdle() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        try await eventually("cards built") { rig.model.cards.count == 3 }
        #expect(rig.model.cards.map(\.name) == ["devbox", "homelab", "staging"])
        #expect(rig.model.overall == .idle)
        #expect(rig.box.made.isEmpty)
        #expect(!rig.model.sshConfigMissing)
    }

    @Test func addingAPortForwardsItAndSavesIt() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        try await rig.model.add(host: "homelab", text: " 3000 ")
        try await eventually("pill is up") { rig.pill("homelab", "3000")?.local == 3000 }
        #expect(rig.model.overall == .forwarding)
        #expect(rig.model.cards.first?.name == "homelab", "hosts in use sort first")
        #expect(try Store(paths: rig.model.paths).loadPorts().hosts == ["homelab": [Entry(port: "3000")]])
        await rig.model.shutdown()
    }

    @Test func badInputIsRejectedAndNothingIsStored() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        await #expect(throws: PortPattern.ParseError.self) { try await rig.model.add(host: "devbox", text: "nope") }
        #expect(!FileManager.default.fileExists(atPath: rig.model.paths.portsFile.path))
    }

    @Test func enteringAnExistingEntryTurnsItOnInsteadOfDuplicating() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        try await rig.model.add(host: "devbox", text: "3000 -> 4000")
        try await rig.model.toggle(host: "devbox", text: "3000 -> 4000")
        #expect(rig.pill("devbox", "3000 -> 4000")?.on == false || rig.card("devbox")?.state == .idle)
        try await rig.model.add(host: "devbox", text: "3000->4000")
        try await eventually("back on, once") {
            rig.card("devbox")?.pills.count == 1 && rig.pill("devbox", "3000 -> 4000")?.local == 4000
        }
        await rig.model.shutdown()
    }

    @Test func turningTheLastEntryOffDisconnects() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        try await rig.model.add(host: "devbox", text: "3000")
        try await eventually("up") { rig.pill("devbox", "3000")?.local == 3000 }
        try await rig.model.toggle(host: "devbox", text: "3000")
        try await eventually("idle") { rig.card("devbox")?.state == .idle && rig.pill("devbox", "3000")?.state == .off }
        #expect(rig.box.made["devbox"]?.first?.stopCount == 1)
        #expect(rig.model.overall == .idle)
    }

    @Test func secondHostOnTheSamePortIsMovedAndShowsIt() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        try await rig.model.add(host: "devbox", text: "3000")
        try await eventually("first up") { rig.pill("devbox", "3000")?.local == 3000 }
        try await rig.model.add(host: "homelab", text: "3000")
        try await eventually("second up") { rig.pill("homelab", "3000")?.local != nil }
        let pill = try #require(rig.pill("homelab", "3000"))
        #expect(pill.local == 3001)
        #expect(pill.moved)
        #expect(pill.label == "3000 → 3001")
        #expect(Store(paths: rig.model.paths).loadSticky() == ["homelab|3000|3000": 3001])

        // Toggling off forgets the sticky choice.
        try await rig.model.toggle(host: "homelab", text: "3000")
        #expect(Store(paths: rig.model.paths).loadSticky().isEmpty)
        await rig.model.shutdown()
    }

    @Test func handEditsApplyOnTheNextTick() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        try FileManager.default.createDirectory(at: rig.model.paths.configDir, withIntermediateDirectories: true)
        try "hosts:\n  staging:\n    - port: 5173\n".write(to: rig.model.paths.portsFile, atomically: true, encoding: .utf8)
        await rig.model.tick()
        try await eventually("picked up") { rig.pill("staging", "5173")?.local == 5173 }
        await rig.model.shutdown()
    }

    @Test func aBrokenFileKeepsRunningStateAndIsNeverOverwritten() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        try await rig.model.add(host: "devbox", text: "3000")
        try await eventually("up") { rig.pill("devbox", "3000")?.local == 3000 }

        let broken = "hosts:\n  devbox: [oops\n"
        try broken.write(to: rig.model.paths.portsFile, atomically: true, encoding: .utf8)
        await rig.model.tick()
        #expect(rig.model.fileError != nil)
        #expect(rig.pill("devbox", "3000")?.local == 3000, "still forwarding on the last good state")
        #expect(rig.model.overall == .attention)

        await #expect(throws: AppModelError.self) { try await rig.model.add(host: "devbox", text: "4000") }
        await #expect(throws: AppModelError.self) { try await rig.model.turnAllOff() }
        #expect(rig.portsText == broken, "the user's file must be left alone")

        try "hosts:\n  devbox:\n    - port: 3000\n    - port: 4000\n".write(to: rig.model.paths.portsFile, atomically: true, encoding: .utf8)
        await rig.model.tick()
        #expect(rig.model.fileError == nil)
        try await eventually("fixed file applied") { rig.pill("devbox", "4000")?.local == 4000 }
        await rig.model.shutdown()
    }

    @Test func removeClearAllAndTurnAllOff() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        try await rig.model.add(host: "devbox", text: "3000")
        try await rig.model.add(host: "devbox", text: "31**")
        try await rig.model.add(host: "homelab", text: "8080")
        try await rig.model.remove(host: "devbox", text: "3000")
        #expect(try Store(paths: rig.model.paths).loadPorts().hosts["devbox"] == [Entry(port: "31**")])

        try await rig.model.turnAllOff()
        let saved = try Store(paths: rig.model.paths).loadPorts()
        let allOff = saved.hosts.values.allSatisfy { $0.allSatisfy { !$0.on } }
        #expect(allOff)
        try await eventually("everything idle") { rig.model.overall == .idle }

        try await rig.model.clearAll(host: "devbox")
        #expect(try Store(paths: rig.model.paths).loadPorts().hosts.keys.sorted() == ["homelab"])
        try await eventually("card has no pills") { rig.card("devbox")?.pills.isEmpty == true }
    }

    @Test func aHostMissingFromTheConfigKeepsItsCardMarked() async throws {
        let rig = try Rig()
        try FileManager.default.createDirectory(at: rig.model.paths.configDir, withIntermediateDirectories: true)
        try "hosts:\n  retired:\n    - port: 3000\n      on: false\n".write(to: rig.model.paths.portsFile, atomically: true, encoding: .utf8)
        await rig.model.start(runTimer: false)
        try await eventually("card present") { rig.card("retired") != nil }
        #expect(rig.card("retired")?.inConfig == false)
        #expect(rig.card("devbox")?.inConfig == true)
    }

    @Test func missingSSHConfigIsReported() async throws {
        let paths = tempPaths()
        var p = paths
        p.sshConfigOverride = paths.configDir.appendingPathComponent("no-such-config")
        let model = AppModel(paths: p, power: FakePower(), makeConnection: { _ in FakeConnection() })
        await model.start(runTimer: false)
        #expect(model.sshConfigMissing)
        #expect(model.cards.isEmpty)
    }

    @Test func statusParsers() {
        #expect(ConfigForwards.interpret(lsofFields: "", fwdMasters: []) == .notForwarded)
        #expect(ConfigForwards.interpret(lsofFields: "p412\ncssh\nf5\n", fwdMasters: []) == .on)
        #expect(ConfigForwards.interpret(lsofFields: "p412\ncssh\n", fwdMasters: [412]) == .taken("fwd"))
        #expect(ConfigForwards.interpret(lsofFields: "p77\ncnode\n", fwdMasters: [412]) == .taken("node"))

        let nettop = """
        ,bytes_in,bytes_out,
        ssh.92152,12174,5802,
        tcp4 127.0.0.1:18556<->*:*,,,
        tcp6 ::1.18000<->*.*,,,
        tcp4 127.0.0.1:50075<->203.0.113.9:22,12174,5802,
        tcp4 127.0.0.1:3000<->127.0.0.1:61022,120,340,
        """
        #expect(TrafficSampler.parse(nettop) == [50075, 3000])
    }
}

/// Config-forward status against real processes.
@MainActor
@Suite(.serialized) struct ConfigForwardIntegrationTests {
    @Test func readsForwardsThroughSSHAndReportsLocalStatus() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let forwards = await ConfigForwards.load(host: SSHTestServer.goodHost, paths: server.paths)
        #expect(forwards.map(\.kind) == [.local, .remote])
        #expect(forwards.map(\.listenPort) == [server.configLocalForward, server.configRemoteForward])
        #expect(await ConfigForwards.load(host: SSHTestServer.secondHost, paths: server.paths).isEmpty)

        let port = server.configLocalForward
        #expect(await ConfigForwards.localStatus(port: port, fwdMasters: []) == .notForwarded)

        // Some other program takes the port.
        let squatter = try TestListener(port: port)
        guard case .taken = await ConfigForwards.localStatus(port: port, fwdMasters: []) else {
            Issue.record("expected the port to be reported as taken")
            return
        }
        squatter.stop()

        // The user's own ssh session opens the config's forwards.
        let own = Process()
        own.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        own.arguments = ["-F", server.paths.sshConfig.path, "-N", "-o", "BatchMode=yes", SSHTestServer.goodHost]
        own.standardInput = FileHandle.nullDevice
        own.standardOutput = FileHandle.nullDevice
        own.standardError = FileHandle.nullDevice
        try own.run()
        defer { own.terminate() }
        try await eventually("the user's ssh has the port") {
            await ConfigForwards.localStatus(port: port, fwdMasters: []) == .on
        }
        #expect(await ConfigForwards.localStatus(port: port, fwdMasters: [own.processIdentifier]) == .taken("fwd"))
    }
}
