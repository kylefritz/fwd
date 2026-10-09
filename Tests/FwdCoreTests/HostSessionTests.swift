import Foundation
import Testing
@testable import FwdCore

/// The session's state machine, driven with a scripted connection.
@MainActor
@Suite struct HostSessionTests {
    let fast = Timing(retrySchedule: [0.05, 0.05], steadyRetry: 0.1, scanInterval: 0.05, settle: 0.01)

    final class Factory {
        var made: [FakeConnection] = []
        var configure: (FakeConnection) -> Void = { _ in }
        func make() -> Connection {
            let c = FakeConnection()
            configure(c)
            made.append(c)
            return c
        }
    }

    func session(_ factory: Factory, power: FakePower = FakePower(),
                 allocator: PortAllocator = PortAllocator(isFree: { _ in true })) -> HostSession {
        HostSession(host: "devbox", makeConnection: factory.make, allocator: allocator, power: power,
                    timing: fast, log: Log(file: tempPaths().logFile))
    }

    @Test func connectsOnlyWhileSomethingIsEnabled() async throws {
        let factory = Factory()
        let s = session(factory)
        await s.setEntries([Entry(port: "3000", on: false)])
        #expect(s.state == .idle)
        #expect(factory.made.isEmpty)

        await s.setEntries([Entry(port: "3000", on: true)])
        try await eventually("forward added") { s.active[3000]?.local == 3000 }
        #expect(s.state == .connected)

        await s.setEntries([Entry(port: "3000", on: false)])
        #expect(s.state == .idle)
        #expect(s.active.isEmpty)
        #expect(factory.made[0].stopCount == 1)
    }

    @Test func invalidEntriesAreIgnoredNotFatal() async throws {
        let factory = Factory()
        let s = session(factory)
        await s.setEntries([Entry(port: "banana"), Entry(port: "80")])
        #expect(s.state == .idle)
        await s.setEntries([Entry(port: "banana"), Entry(port: "3000")])
        try await eventually("valid entry forwarded") { s.active.keys.sorted() == [3000] }
    }

    @Test func wildcardFollowsTheScan() async throws {
        let factory = Factory()
        factory.configure = { $0.listening = "#ss\nLISTEN 0 1 127.0.0.1:3001 0.0.0.0:*\n" }
        let s = session(factory)
        await s.setEntries([Entry(port: "3*** -> 4***")])
        try await eventually("3001 forwarded") { s.active[3001]?.local == 4001 }
        factory.made[0].listening = "#ss\nLISTEN 0 1 127.0.0.1:3002 0.0.0.0:*\n"
        try await eventually("follows to 3002") { s.active.keys.sorted() == [3002] }
        #expect(factory.made[0].forwards.map(\.remote) == [3002])
    }

    @Test func unscannableRemoteStillForwardsSinglePorts() async throws {
        let factory = Factory()
        factory.configure = { $0.listening = "#none\n" }
        let s = session(factory)
        await s.setEntries([Entry(port: "3000"), Entry(port: "31**")])
        try await eventually("single port forwarded") { s.active[3000] != nil }
        #expect(s.scanUnavailable)
        #expect(s.active.count == 1)
    }

    @Test func manyWildcardPortsAtOnceGetDistinctLaptopPorts() async throws {
        let factory = Factory()
        let lines = (3000..<3040).map { "LISTEN 0 1 127.0.0.1:\($0) 0.0.0.0:*" }.joined(separator: "\n")
        factory.configure = { $0.listening = "#ss\n\(lines)\n" }
        // Odd laptop ports are taken by other programs.
        let s = session(factory, allocator: PortAllocator(isFree: { $0 % 2 == 0 }))
        await s.setEntries([Entry(port: "30**")])
        try await eventually("all forwarded") { s.active.count == 40 }
        let locals = s.active.values.map(\.local)
        #expect(Set(locals).count == 40)
        #expect(locals.allSatisfy { $0 % 2 == 0 })
    }

    @Test func blockedWhenNoLaptopPortIsFree() async throws {
        let factory = Factory()
        let s = session(factory, allocator: PortAllocator(isFree: { _ in false }))
        await s.setEntries([Entry(port: "3000")])
        try await eventually("reported blocked") { s.blocked[3000] != nil }
        #expect(s.active.isEmpty)
    }

    @Test func retriesOnAScheduleUntilItConnects() async throws {
        let factory = Factory()
        factory.configure = { [factory] c in
            if factory.made.count < 3 { c.startError = .unreachable("Connection refused") }
        }
        let s = session(factory)
        await s.setEntries([Entry(port: "3000")])
        try await eventually("connected on the fourth try") { s.state == .connected }
        #expect(factory.made.count == 4)
    }

    @Test func authFailureStopsAndWaitsForAPerson() async throws {
        let factory = Factory()
        factory.configure = { $0.startError = .needsAttention("Permission denied (publickey).") }
        let s = session(factory)
        await s.setEntries([Entry(port: "3000")])
        try await eventually("needs attention") { s.state == .needsAttention("Permission denied (publickey).") }
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(factory.made.count == 1, "must not keep retrying")

        factory.configure = { _ in }
        await s.retryNow()
        try await eventually("connects after retry") { s.state == .connected }
    }

    @Test func reconnectsAndRestoresForwardsWhenTheLinkDies() async throws {
        let factory = Factory()
        let s = session(factory)
        await s.setEntries([Entry(port: "3000"), Entry(port: "3001")])
        try await eventually("forwards up") { s.active.count == 2 }
        factory.made[0].die()
        try await eventually("second connection has both forwards") {
            factory.made.count == 2 && factory.made[1].forwards.count == 2 && s.state == .connected
        }
        #expect(s.active.count == 2)
    }

    @Test func linkDyingDuringAForwardCallReconnectsExactlyOnce() async throws {
        let factory = Factory()
        factory.configure = { [factory] c in
            if factory.made.isEmpty {
                c.onAddForward = { conn, _, _ in
                    conn.die()
                    throw ConnectionError.failed("mux_client_forward: master died")
                }
            }
        }
        let s = session(factory)
        await s.setEntries([Entry(port: "3000")])
        try await eventually("recovered") { s.state == .connected && s.active[3000]?.local == 3000 }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(factory.made.count == 2, "one death should cause one reconnect")
        #expect(s.blocked.isEmpty)
    }

    @Test func sleepPausesAndWakeRestores() async throws {
        let factory = Factory()
        let s = session(factory)
        await s.setEntries([Entry(port: "3000")])
        try await eventually("up") { s.active.count == 1 }

        await s.handle(.willSleep)
        #expect(s.state == .paused("asleep"))
        #expect(s.active.isEmpty)
        #expect(factory.made[0].stopCount == 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(factory.made.count == 1, "nothing may run while asleep")

        await s.handle(.didWake)
        try await eventually("back after wake") { s.state == .connected && s.active.count == 1 }
        #expect(factory.made.count == 2)
    }

    @Test func noPollingWithoutANetwork() async throws {
        let factory = Factory()
        let power = FakePower()
        let s = session(factory, power: power)
        await s.setEntries([Entry(port: "3000")])
        try await eventually("up") { s.active.count == 1 }

        power.networkUp = false
        await s.handle(.networkDown)
        #expect(s.state == .paused("no network"))
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(factory.made.count == 1, "must not try to connect with no network")

        power.networkUp = true
        await s.handle(.networkUp)
        try await eventually("back when network returns") { s.state == .connected && s.active.count == 1 }
    }

    @Test func networkChangeWithAHealthyLinkLeavesItAlone() async throws {
        let factory = Factory()
        let s = session(factory)
        await s.setEntries([Entry(port: "3000")])
        try await eventually("up") { s.active.count == 1 }
        await s.handle(.networkUp)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(factory.made.count == 1)
        #expect(s.state == .connected)
    }

    @Test func closedLidUsesTheSlowRetryInterval() async throws {
        let factory = Factory()
        factory.configure = { $0.startError = .unreachable("down") }
        let power = FakePower()
        power.lidClosed = true
        let slow = Timing(retrySchedule: [0.02, 0.02], steadyRetry: 5, scanInterval: 0.05, settle: 0.01)
        let s = HostSession(host: "devbox", makeConnection: factory.make, allocator: PortAllocator(isFree: { _ in true }),
                            power: power, timing: slow, log: Log(file: tempPaths().logFile))
        await s.setEntries([Entry(port: "3000")])
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(factory.made.count == 1, "with the lid shut it should wait the long interval")
        await s.shutdown()
    }
}
