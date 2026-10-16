import Foundation
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

    /// A dev server on all interfaces, or only on IPv6, still lets 127.0.0.1
    /// be bound. It must count as taken or a forward would shadow it.
    @Test func systemCheckSeesServersOnAllInterfacesAndOnIPv6() throws {
        let port = try freePort()
        #expect(PortAllocator.systemIsFree(port))

        // Real servers set SO_REUSEADDR; without it a just-probed port can
        // briefly refuse a wildcard bind.
        var yes: Int32 = 1
        func becomesFree() -> Bool {
            for _ in 0..<40 {
                if PortAllocator.systemIsFree(port) { return true }
                usleep(25_000)
            }
            return false
        }
        let any4 = socket(AF_INET, SOCK_STREAM, 0)
        setsockopt(any4, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var a4 = sockaddr_in()
        a4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a4.sin_family = sa_family_t(AF_INET)
        a4.sin_port = in_port_t(port).bigEndian
        a4.sin_addr.s_addr = INADDR_ANY
        let bound4 = withUnsafePointer(to: &a4) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(any4, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound4 == 0 && listen(any4, 4) == 0)
        #expect(!PortAllocator.systemIsFree(port), "server on 0.0.0.0 should make the port taken")
        close(any4)
        #expect(becomesFree(), "the port should be free again once the server is gone")

        let v6 = socket(AF_INET6, SOCK_STREAM, 0)
        setsockopt(v6, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var a6 = sockaddr_in6()
        a6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        a6.sin6_family = sa_family_t(AF_INET6)
        a6.sin6_port = in_port_t(port).bigEndian
        a6.sin6_addr = in6addr_loopback
        let bound6 = withUnsafePointer(to: &a6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(v6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        #expect(bound6 == 0 && listen(v6, 4) == 0)
        #expect(!PortAllocator.systemIsFree(port), "server on [::1] should make the port taken")
        close(v6)
    }

    @MainActor @Test func systemCheckSeesARealListener() async throws {
        // A port from outside the range the system hands out on its own, so
        // another test's connection can't take it once the listener stops.
        let listener = try TestListener(port: try freePort())
        #expect(!PortAllocator.systemIsFree(listener.port))
        let port = listener.port
        listener.stop()
        try await eventually("free again", timeout: 2) { PortAllocator.systemIsFree(port) }
    }
}
