import Testing
@testable import FwdCore

@Suite struct PortAllocatorTests {
    @Test func wantedPortWhenFree() {
        let a = PortAllocator(isFree: { _ in true })
        #expect(a.allocate(wanted: 3000, key: "h|3000|3000") == 3000)
        #expect(a.sticky.isEmpty)
    }

    @Test func bumpsPastPortsHeldByAnotherHost() {
        let a = PortAllocator(isFree: { _ in true })
        #expect(a.allocate(wanted: 3000, key: "host1|3000|3000") == 3000)
        #expect(a.allocate(wanted: 3000, key: "host2|3000|3000") == 3001)
        #expect(a.sticky == ["host2|3000|3000": 3001])
    }

    @Test func bumpsPastPortsUsedByOtherPrograms() {
        let a = PortAllocator(isFree: { ![3000, 3001].contains($0) })
        #expect(a.allocate(wanted: 3000, key: "k") == 3002)
    }

    @Test func stickyChoiceSurvivesTheOriginalFreeingUp() {
        var taken: Set<Int> = [3000]
        let a = PortAllocator(isFree: { !taken.contains($0) })
        #expect(a.allocate(wanted: 3000, key: "k") == 3001)
        a.release(3001)
        taken = []
        #expect(a.allocate(wanted: 3000, key: "k") == 3001)
    }

    @Test func stickyChoiceIsRepickedWhenItIsTakenLater() {
        var taken: Set<Int> = [3000]
        let a = PortAllocator(isFree: { !taken.contains($0) })
        #expect(a.allocate(wanted: 3000, key: "k") == 3001)
        a.release(3001)
        taken = [3001]
        #expect(a.allocate(wanted: 3000, key: "k") == 3000)
        #expect(a.sticky.isEmpty)
    }

    @Test func forgetResetsToTheWantedPort() {
        var taken: Set<Int> = [3000]
        let a = PortAllocator(isFree: { !taken.contains($0) })
        #expect(a.allocate(wanted: 3000, key: "h|3000|3000") == 3001)
        a.release(3001)
        taken = []
        a.forget(keyPrefix: "h|3000|")
        #expect(a.allocate(wanted: 3000, key: "h|3000|3000") == 3000)
    }

    @Test func givesUpAfterFiftyPorts() {
        let a = PortAllocator(isFree: { $0 >= 3050 })
        #expect(a.allocate(wanted: 3000, key: "k") == nil)
        let b = PortAllocator(isFree: { $0 >= 3049 })
        #expect(b.allocate(wanted: 3000, key: "k") == 3049)
    }

    @Test func neverHandsOutPrivilegedOrImpossiblePorts() {
        let a = PortAllocator(isFree: { _ in true })
        #expect(a.allocate(wanted: 1000, key: "k") == 1024)
        #expect(a.allocate(wanted: 65535, key: "a") == 65535)
        #expect(a.allocate(wanted: 65535, key: "b") == nil)
    }

    @Test func manyPortsAtOnceAllGetDistinctPorts() {
        // Every third port is used by something else on the laptop.
        let a = PortAllocator(isFree: { $0 % 3 != 0 })
        var seen = Set<Int>()
        for remote in 3000..<3060 {
            let port = a.allocate(wanted: remote, key: "h|3***|\(remote)")
            #expect(port != nil)
            if let port {
                #expect(port % 3 != 0)
                #expect(seen.insert(port).inserted, "port \(port) handed out twice")
            }
        }
        #expect(seen.count == 60)
    }

    @Test func systemCheckSeesARealListener() throws {
        let listener = try TestListener()
        #expect(!PortAllocator.systemIsFree(listener.port))
        let port = listener.port
        listener.stop()
        #expect(PortAllocator.systemIsFree(port))
    }
}
