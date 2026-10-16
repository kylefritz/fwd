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

    // MARK: When to connect

    @Test func portsOnButNothingAskingWaitsInStandby() async throws {
        let factory = Factory()
        let s = session(factory)
        await s.setEntries([Entry(port: "3000")])
        #expect(s.state == .standby)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(factory.made.isEmpty, "no ssh session, no click, nothing kept: don't connect")
    }

    @Test func aClickConnectsOnceAndADropDoesNotReconnect() async throws {
        let factory = Factory()
        let s = session(factory)
        await s.setEntries([Entry(port: "3000")])
        await s.connect()
        try await eventually("up") { s.active[3000] != nil }
        factory.made[0].die()
        try await eventually("back to standby") { s.state == .standby }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(factory.made.count == 1, "must not reconnect on its own")
        #expect(s.active.isEmpty)
    }

    @Test func aClickGivesUpAfterTheShortSchedule() async throws {
        let factory = Factory()
        factory.configure = { $0.startError = .unreachable("Operation timed out") }
        let s = session(factory)
        await s.setEntries([Entry(port: "3000")])
        await s.connect()
        try await eventually("gave up") { s.state == .standby }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(factory.made.count == fast.retrySchedule.count + 1)
        #expect(s.lastError == "Operation timed out", "the card can still say why")
    }

    @Test func yourSshSessionConnectsAndReconnectsUntilItEnds() async throws {
        let factory = Factory()
        let s = session(factory)
        await s.setEntries([Entry(port: "3000")])
        await s.setUserSession(true)
        try await eventually("up") { s.active[3000] != nil }
        factory.made[0].die()
        try await eventually("reconnected while your session is open") {
            factory.made.count == 2 && s.state == .connected
        }
        await s.setUserSession(false)
        #expect(s.state == .standby)
        #expect(s.active.isEmpty)
        #expect(factory.made[1].stopCount == 1)
    }

    @Test func aClickedConnectionOutlivesYourSshSession() async throws {
        let factory = Factory()
        let s = session(factory)
        await s.setEntries([Entry(port: "5900 -> 5901")])
        await s.setUserSession(true)
        try await eventually("up") { s.state == .connected }
        await s.connect()
        await s.setUserSession(false)
        #expect(s.state == .connected, "Screen Sharing keeps working after you exit ssh")
        #expect(factory.made.count == 1, "a click on a live connection doesn't reconnect")
    }

    @Test func wakeDoesNotReconnectAHostThatWasOnlyClicked() async throws {
        let factory = Factory()
        let s = session(factory)
        await s.setEntries([Entry(port: "3000")])
        await s.connect()
        try await eventually("up") { s.state == .connected }
        await s.handle(.willSleep)
        await s.handle(.didWake)
        await s.handle(.networkUp)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(s.state == .standby)
        #expect(factory.made.count == 1)
    }

    @Test func keepConnectedHoldsWithoutASessionUntilItIsTurnedOff() async throws {
        let factory = Factory()
        let s = session(factory)
        await s.setEntries([Entry(port: "8765", keep: true), Entry(port: "8080")])
        try await eventually("connects by itself") { s.active.count == 2 }
        factory.made[0].die()
        try await eventually("reconnected") { factory.made.count == 2 && s.active.count == 2 }

        await s.setEntries([Entry(port: "8765"), Entry(port: "8080")])
        #expect(s.state == .standby)
        // A kept entry that is turned off doesn't hold the host either.
        await s.setEntries([Entry(port: "8765", on: false, keep: true), Entry(port: "8080")])
        #expect(s.state == .standby)
        #expect(factory.made.count == 2)
    }

    @Test func aClickWhileOfflineDoesNotConnectLaterOnItsOwn() async throws {
        let factory = Factory()
        let power = FakePower()
        power.networkUp = false
        let s = session(factory, power: power)
        await s.setEntries([Entry(port: "3000"), Entry(port: "3001")])
        await s.connect()
        try await eventually("paused") { s.state == .paused("no network") }
        power.networkUp = true
        await s.handle(.networkUp)
        #expect(s.state == .standby)
        // Some unrelated edit later must not start a connection.
        await s.setEntries([Entry(port: "3000")])
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(factory.made.isEmpty)
        #expect(s.state == .standby)
    }

    @Test func holdingAConnectionInUseKeepsItThroughLosingKeep() async throws {
        let factory = Factory()
        let s = session(factory)
        await s.setEntries([Entry(port: "5432", keep: true), Entry(port: "3000")])
        try await eventually("up") { s.active.count == 2 }
        s.holdWhileConnected()
        await s.setEntries([Entry(port: "5432", on: false, keep: true), Entry(port: "3000")])
        #expect(s.state == .connected, "turning the kept port off must not drop 3000")
        #expect(factory.made.count == 1)
        #expect(factory.made[0].stopCount == 0)
    }

    @Test func connectsOnlyWhileSomethingIsEnabled() async throws {
        let factory = Factory()
        let s = session(factory)
        await s.setEntries([Entry(port: "3000", on: false)])
        #expect(s.state == .idle)
        #expect(factory.made.isEmpty)
        await s.connect()
        #expect(factory.made.isEmpty, "a click with nothing on does nothing")

        await s.setEntries([Entry(port: "3000", on: true)])
        await s.connect()
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
        await s.connect()
        try await eventually("valid entry forwarded") { s.active.keys.sorted() == [3000] }
    }

    @Test func wildcardFollowsTheScan() async throws {
        let factory = Factory()
        factory.configure = { $0.listening = "#fwd:ss\nLISTEN 0 1 127.0.0.1:3001 0.0.0.0:*\n" }
        let s = session(factory)
        await s.setEntries([Entry(port: "3*** -> 4***")])
        await s.connect()
        try await eventually("3001 forwarded") { s.active[3001]?.local == 4001 }
        factory.made[0].listening = "#fwd:ss\nLISTEN 0 1 127.0.0.1:3002 0.0.0.0:*\n"
        try await eventually("follows to 3002") { s.active.keys.sorted() == [3002] }
        #expect(factory.made[0].forwards.map(\.remote) == [3002])
    }

    @Test func unscannableRemoteStillForwardsSinglePorts() async throws {
        let factory = Factory()
        factory.configure = { $0.listening = "#fwd:none\n" }
        let s = session(factory)
        await s.setEntries([Entry(port: "3000"), Entry(port: "31**")])
        await s.connect()
        try await eventually("single port forwarded") { s.active[3000] != nil }
        #expect(s.scanUnavailable)
        #expect(s.active.count == 1)
    }

    @Test func manyWildcardPortsAtOnceGetDistinctLaptopPorts() async throws {
        let factory = Factory()
        let lines = (3000..<3040).map { "LISTEN 0 1 127.0.0.1:\($0) 0.0.0.0:*" }.joined(separator: "\n")
        factory.configure = { $0.listening = "#fwd:ss\n\(lines)\n" }
        // Odd laptop ports are taken by other programs.
        let s = session(factory, allocator: PortAllocator(isFree: { $0 % 2 == 0 }))
        await s.setEntries([Entry(port: "30**")])
        await s.connect()
        try await eventually("all forwarded") { s.active.count == 40 }
        let locals = s.active.values.map(\.local)
        #expect(Set(locals).count == 40)
        #expect(locals.allSatisfy { $0 % 2 == 0 })
    }

    @Test func blockedWhenNoLaptopPortIsFree() async throws {
        let factory = Factory()
        let s = session(factory, allocator: PortAllocator(isFree: { _ in false }))
        await s.setEntries([Entry(port: "3000")])
        await s.connect()
        try await eventually("reported blocked") { s.blocked[3000] != nil }
        #expect(s.active.isEmpty)
    }

    @Test func retriesOnAScheduleUntilItConnects() async throws {
        let factory = Factory()
        factory.configure = { [factory] c in
            if factory.made.count < 3 { c.startError = .unreachable("Connection refused") }
        }
        let s = session(factory)
        await s.setEntries([Entry(port: "3000", keep: true)])
        try await eventually("connected on the fourth try") { s.state == .connected }
        #expect(factory.made.count == 4)
    }

    @Test func authFailureStopsAndWaitsForAPerson() async throws {
        let factory = Factory()
        factory.configure = { $0.startError = .needsAttention("Permission denied (publickey).") }
        let s = session(factory)
        await s.setEntries([Entry(port: "3000")])
        await s.connect()
        try await eventually("needs attention") { s.state == .needsAttention("Permission denied (publickey).") }
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(factory.made.count == 1, "must not keep retrying")

        factory.configure = { _ in }
        await s.connect()
        try await eventually("connects after retry") { s.state == .connected }
    }

    @Test func reconnectsAndRestoresForwardsWhenTheLinkDies() async throws {
        let factory = Factory()
        let s = session(factory)
        await s.setEntries([Entry(port: "3000", keep: true), Entry(port: "3001")])
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
        await s.setEntries([Entry(port: "3000", keep: true)])
        try await eventually("recovered") { s.state == .connected && s.active[3000]?.local == 3000 }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(factory.made.count == 2, "one death should cause one reconnect")
        #expect(s.blocked.isEmpty)
    }

    @Test func sleepPausesAndWakeRestores() async throws {
        let factory = Factory()
        let s = session(factory)
        await s.setEntries([Entry(port: "3000", keep: true)])
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
        await s.setEntries([Entry(port: "3000", keep: true)])
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
        await s.connect()
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
        await s.setEntries([Entry(port: "3000", keep: true)])
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(factory.made.count == 1, "with the lid shut it should wait the long interval")
        await s.shutdown()
    }
}
