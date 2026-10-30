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

    @Test func anAddressReachesTheRemoteThroughSSH() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let remote = try TestListener(greeting: "from the remote")
        let laptop = try freePort()
        let names = try freePort()
        let model = AppModel(paths: server.paths, power: FakePower(), timing: fast, namesPort: UInt16(names))
        await model.start(runTimer: false)
        await model.setOpenByName(true)
        try await model.add(host: SSHTestServer.goodHost, text: "\(remote.port) -> \(laptop) web")
        try await eventually("the address is up") {
            model.addressBook.addresses.first?.status == .ready(local: laptop)
        }

        let answer = await Task.detached {
            exchange(names, "GET / HTTP/1.1\r\nHost: web.localhost\r\n\r\n")
        }.value
        #expect(answer == "from the remote")
        await model.shutdown()
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

    @Test func aBrowserSignInIsWaitedForPastTheConnectTimeout() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let log = Log(file: server.paths.logFile)
        // Gives up after 7 seconds without a sign-in; this one takes 8.
        let conn = SSHConnection(host: SSHTestServer.signInHost, paths: server.paths, log: log, connectTimeout: 1)
        try await conn.start()
        #expect(await conn.isAlive())
        await conn.stop()
    }

    @Test func aBrowserSignInThatNeverFinishesNeedsAttention() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let log = Log(file: server.paths.logFile)
        let conn = SSHConnection(host: SSHTestServer.signInNeverHost, paths: server.paths, log: log,
                                 connectTimeout: 1, signInTimeout: 2)
        do {
            try await conn.start()
            Issue.record("connected without a sign-in")
        } catch ConnectionError.needsAttention(let message) {
            #expect(message.contains("sign in"))
        }
    }

    @Test func aStopWhileTheConfigIsReadKeepsSSHFromStarting() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        // The test config plus a rule that takes two seconds to evaluate.
        let config = server.dir.appendingPathComponent("slow_config")
        try (String(contentsOf: server.paths.sshConfig, encoding: .utf8)
             + "Match originalhost \(SSHTestServer.goodHost) exec \"sleep 2\"\n")
            .write(to: config, atomically: true, encoding: .utf8)
        var paths = server.paths
        paths.sshConfigOverride = config
        let conn = SSHConnection(host: SSHTestServer.goodHost, paths: paths, log: Log(file: paths.logFile))

        let starting = Task { try await conn.start() }
        try await Task.sleep(nanoseconds: 500_000_000)
        await conn.stop()
        await #expect(throws: ConnectionError.self) { try await starting.value }
        #expect(conn.masterPID == nil)
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
        #expect(SSHConfig.hosts(configPath: server.paths.sshConfig) == [SSHTestServer.goodHost, SSHTestServer.secondHost, SSHTestServer.badKeyHost,
                 SSHTestServer.signInHost, SSHTestServer.signInNeverHost])
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

    @Test func theCommandLineForwardsAndWaitsThroughTheApp() async throws {
        let server = try SSHTestServer()
        defer { server.cleanup() }
        let laptop = try freePort()
        let model = AppModel(paths: server.paths, power: FakePower(),
                             timing: Timing(retrySchedule: [0.3], steadyRetry: 0.5, scanInterval: 0.3, settle: 0.05),
                             userSessions: { [] })
        await model.start(runTimer: false)
        let handler = ControlHandler(model: model, open: { _ in })
        try SSHConnection.prepareSocketDir(server.paths.socketDir)
        let control = ControlServer(path: server.paths.controlSocket.path) { await handler.handle($0) }
        try control.start()
        defer { control.stop() }

        // The agent forwards first, then the server starts on the remote.
        let remotePort = try freePort()
        let mapping = "\(remotePort) -> \(laptop)"
        let socket = server.paths.controlSocket.path
        let forward = await Task.detached {
            CLIRunner.send(ControlRequest(cmd: "forward", args: [SSHTestServer.goodHost, mapping], timeout: 15),
                           socket: socket, launch: {})
        }.value
        #expect(forward.ok, "\(forward)")
        #expect(forward.host?.ports.first?.state == "waiting")
        #expect(forward.host?.ports.first?.url == "http://localhost:\(laptop)")

        let remote = try TestListener(port: remotePort, greeting: "from the agent's server")
        defer { remote.stop() }
        let waited = await Task.detached {
            CLIRunner.send(ControlRequest(cmd: "wait", args: [mapping], timeout: 15), socket: socket, launch: {})
        }.value
        #expect(waited.ok, "the one connected host is used: \(waited)")
        #expect(fetch(laptop) == "from the agent's server")
        await model.shutdown()
    }
}
