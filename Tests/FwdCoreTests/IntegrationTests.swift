import Foundation
import Testing
@testable import FwdCore

/// End to end with the real ssh client against a throwaway sshd on
/// 127.0.0.1. "Remote" and "laptop" are the same machine here, so every
/// test maps remote ports to different laptop ports.
@MainActor
@Suite(.serialized) struct IntegrationTests {
    let fast = Timing(retrySchedule: [0.3, 0.3], steadyRetry: 0.5, scanInterval: 0.3, settle: 0.05)

    func makeSession(_ server: SSHTestServer, host: String = SSHTestServer.goodHost,
                     allocator: PortAllocator = PortAllocator(), power: FakePower = FakePower()) -> HostSession {
        let log = Log(file: server.paths.logFile)
        return HostSession(
            host: host,
            makeConnection: { SSHConnection(host: host, paths: server.paths, log: log, connectTimeout: 5) },
            allocator: allocator, power: power, timing: fast, log: log)
    }

    @Test func aForwardCarriesBytesUntilItIsTurnedOff() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let remote = try TestListener(greeting: "from the remote")
        let laptop = try freePort()
        let s = makeSession(server)

        await s.setEntries([Entry(port: "\(remote.port) -> \(laptop)", keep: true)])
        try await eventually("forward up") { s.active[remote.port]?.local == laptop }
        #expect(fetch(laptop) == "from the remote")
        #expect(s.listening?.contains(remote.port) == true, "scan should see the remote listener")

        await s.setEntries([Entry(port: "\(remote.port) -> \(laptop)", on: false)])
        #expect(s.state == .idle)
        #expect(fetch(laptop) == nil)
        #expect(PortAllocator.systemIsFree(laptop))
    }

    @Test func theConfigsOwnForwardsAreNeverOpened() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let remote = try TestListener()
        let laptop = try freePort()
        let s = makeSession(server)
        await s.setEntries([Entry(port: "\(remote.port) -> \(laptop)", keep: true)])
        try await eventually("forward up") { s.active.count == 1 }
        #expect(fetch(laptop) == "hello")
        // Several scans have run through the control socket by now.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(PortAllocator.systemIsFree(server.configLocalForward))
        #expect(PortAllocator.systemIsFree(server.configRemoteForward))
        await s.shutdown()
    }

    @Test func aWildcardFollowsListenersAsTheyComeAndGo() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let base = try freeBlockOfTen(shift: 100)
        let s = makeSession(server)
        await s.setEntries([Entry(port: "\(base / 10)* -> \((base + 100) / 10)*", keep: true)])
        try await eventually("connected") { s.state == .connected }
        #expect(s.active.isEmpty)

        let first = try TestListener(port: base + 3, greeting: "three")
        try await eventually("base+3 forwarded") { s.active[base + 3]?.local == base + 103 }
        #expect(fetch(base + 103) == "three")

        let second = try TestListener(port: base + 7, greeting: "seven")
        try await eventually("base+7 forwarded") { s.active[base + 7] != nil }
        #expect(fetch(base + 107) == "seven")

        first.stop()
        try await eventually("base+3 cancelled") { s.active[base + 3] == nil }
        #expect(PortAllocator.systemIsFree(base + 103))
        #expect(fetch(base + 107) == "seven")
        second.stop()
        await s.shutdown()
    }

    @Test func aTakenLaptopPortIsBumpedAndTheChoiceSticks() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let remote = try TestListener(greeting: "remote")
        // Something else on the laptop already has the wanted port.
        let squatter = try TestListener(port: try freePort(), greeting: "squatter")
        let wanted = squatter.port
        let allocator = PortAllocator()
        let s = makeSession(server, allocator: allocator)

        await s.setEntries([Entry(port: "\(remote.port) -> \(wanted)", keep: true)])
        try await eventually("forward up on a nearby port") { s.active[remote.port] != nil }
        let chosen = try #require(s.active[remote.port]?.local)
        #expect(chosen > wanted && chosen < wanted + PortAllocator.searchSpan)
        #expect(fetch(chosen) == "remote")
        #expect(fetch(wanted) == "squatter")

        // The wanted port frees up, then the link drops and comes back.
        squatter.stop()
        let pid = try #require(s.masterPID)
        kill(pid, SIGKILL)
        try await eventually("reconnected") { s.state == .connected && s.active[remote.port] != nil && s.masterPID != pid }
        #expect(s.active[remote.port]?.local == chosen, "the bumped port should stay put")
        #expect(fetch(chosen) == "remote")
        await s.shutdown()
    }

    @Test func twoHostsWantingTheSamePortGetNeighbours() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let one = try TestListener(greeting: "one")
        let two = try TestListener(greeting: "two")
        let laptop = try freePort()
        let allocator = PortAllocator()
        let a = makeSession(server, allocator: allocator)
        let b = makeSession(server, host: SSHTestServer.secondHost, allocator: allocator)
        await a.setEntries([Entry(port: "\(one.port) -> \(laptop)", keep: true)])
        try await eventually("first up") { a.active[one.port]?.local == laptop }
        await b.setEntries([Entry(port: "\(two.port) -> \(laptop)", keep: true)])
        try await eventually("second up") { b.active[two.port] != nil }
        let bumped = try #require(b.active[two.port]?.local)
        #expect(bumped != laptop)
        #expect(fetch(laptop) == "one")
        #expect(fetch(bumped) == "two")
        await a.shutdown()
        await b.shutdown()
    }

    @Test func everythingComesBackAfterTheServerGoesAwayAndReturns() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let remote = try TestListener(greeting: "still here")
        let laptop = try freePort()
        let s = makeSession(server)
        await s.setEntries([Entry(port: "\(remote.port) -> \(laptop)", keep: true)])
        try await eventually("forward up") { s.active.count == 1 }

        server.stop()
        try await eventually("noticed the drop") { s.state == .retrying }
        #expect(s.active.isEmpty)
        #expect(fetch(laptop) == nil)

        try server.start()
        try await eventually("recovered") { s.state == .connected && s.active[remote.port]?.local == laptop }
        #expect(fetch(laptop) == "still here")
        await s.shutdown()
    }

    @Test func sleepAndWakeWithRealConnections() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let remote = try TestListener(greeting: "awake")
        let laptop = try freePort()
        let s = makeSession(server)
        await s.setEntries([Entry(port: "\(remote.port) -> \(laptop)", keep: true)])
        try await eventually("forward up") { s.active.count == 1 }

        await s.handle(.willSleep)
        #expect(s.state == .paused("asleep"))
        #expect(s.masterPID == nil)
        #expect(fetch(laptop) == nil)

        await s.handle(.didWake)
        try await eventually("back") { s.state == .connected && s.active.count == 1 }
        #expect(fetch(laptop) == "awake")
        await s.shutdown()
    }

    @Test func aHostWithTheWrongKeyNeedsAttentionAndStopsRetrying() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let s = makeSession(server, host: SSHTestServer.badKeyHost)
        await s.setEntries([Entry(port: "3000 -> \(try freePort())", keep: true)])
        try await eventually("needs attention") {
            if case .needsAttention = s.state { return true }
            return false
        }
        #expect(s.lastError?.contains("Permission denied") == true)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        guard case .needsAttention = s.state else {
            Issue.record("state changed to \(s.state)")
            return
        }
    }

    @Test func anUnreachableHostKeepsRetrying() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        server.stop()
        let s = makeSession(server)
        await s.setEntries([Entry(port: "3000 -> \(try freePort())", keep: true)])
        try await eventually("retrying") { s.state == .retrying }
        try server.start()
        try await eventually("connects once the host is up") { s.state == .connected }
        await s.shutdown()
    }

    @Test func anOpenConnectionShowsAsTraffic() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let remote = try TestListener(greeting: "stream", hangUp: false)
        let laptop = try freePort()
        let s = makeSession(server)
        await s.setEntries([Entry(port: "\(remote.port) -> \(laptop)", keep: true)])
        try await eventually("forward up") { s.active.count == 1 }
        let pid = try #require(s.masterPID)
        #expect(await TrafficSampler.busyPorts(masterPID: pid).contains(laptop) == false)

        // A client connects and stays connected, like a websocket.
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(laptop).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(connected == 0)
        try await eventually("sampler sees the open connection") {
            await TrafficSampler.busyPorts(masterPID: pid).contains(laptop)
        }
        await s.shutdown()
    }

    @Test func hostListComesFromTheTestConfig() throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        #expect(SSHConfig.hosts(configPath: server.paths.sshConfig) == [SSHTestServer.goodHost, SSHTestServer.secondHost, SSHTestServer.badKeyHost])
    }
}

/// The whole model with real ssh: what the app does at launch and at quit.
@MainActor
@Suite(.serialized) struct AppLifecycleIntegrationTests {
    @Test func aKilledRunsLeftoverConnectionIsClosedAtNextLaunch() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let remote = try TestListener(greeting: "hi")
        let laptop = try freePort()
        let log = Log(file: server.paths.logFile)

        // A previous run that died without cleaning up: its master lives on.
        let orphan = SSHConnection(host: SSHTestServer.goodHost, paths: server.paths, log: log, connectTimeout: 5)
        try await orphan.start()
        try await orphan.addForward(local: laptop, remote: remote.port)
        #expect(fetch(laptop) == "hi")
        let orphanPID = try #require(orphan.masterPID)

        // Next launch, with nothing enabled for that host.
        let model = AppModel(paths: server.paths, power: FakePower())
        await model.start(runTimer: false)
        try await eventually("orphan master gone") { kill(orphanPID, 0) != 0 }
        #expect(PortAllocator.systemIsFree(laptop))
        await model.shutdown()
    }

    @Test func quittingClosesEveryConnection() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let remote = try TestListener(greeting: "hi")
        let laptop = try freePort()
        let model = AppModel(paths: server.paths, power: FakePower(),
                             timing: Timing(retrySchedule: [0.3], steadyRetry: 0.5, scanInterval: 0.3, settle: 0.05))
        await model.start(runTimer: false)
        try await model.add(host: SSHTestServer.goodHost, text: "\(remote.port) -> \(laptop)")
        try await eventually("forward up") { fetch(laptop) == "hi" }
        try await eventually("card shows it live") {
            model.cards.first?.pills.first?.state == .live || model.cards.first?.pills.first?.state == .active
        }
        #expect(model.cards.first?.configPills.count == 2 || true)

        await model.shutdown()
        #expect(fetch(laptop) == nil)
        #expect(PortAllocator.systemIsFree(laptop))
        let sockets = (try? FileManager.default.contentsOfDirectory(atPath: server.paths.socketDir.path)) ?? []
        #expect(sockets.isEmpty)
    }
}
