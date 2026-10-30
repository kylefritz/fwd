import Foundation
import Network
import Testing
@testable import FwdCore

/// Sends `request` to 127.0.0.1:port and returns everything until the server
/// hangs up.
func exchange(_ port: Int, _ request: String) -> String? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { return nil }
    let bytes = Array(request.utf8)
    _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    var received = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        received += buffer[0..<n]
    }
    return String(decoding: received, as: UTF8.self)
}

private func get(_ host: String, path: String = "/") -> String {
    "GET \(path) HTTP/1.1\r\nHost: \(host)\r\n\r\n"
}

private func post(_ host: String, path: String, origin: String?) -> String {
    let originLine = origin.map { "Origin: \($0)\r\n" } ?? ""
    return "POST \(path) HTTP/1.1\r\nHost: \(host)\r\n\(originLine)Content-Length: 0\r\n\r\n"
}

/// Answers every route with `route` and records what it's asked to do.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [NameAction] = []
    var route: NameRoute

    init(route: NameRoute) { self.route = route }

    var actions: [NameAction] { lock.withLock { recorded } }

    func handler() -> NameProxy.Handler {
        NameProxy.Handler(route: { _ in self.route }, perform: { action, _ in
            self.lock.withLock { self.recorded.append(action) }
        })
    }
}

private func logFile() -> Log {
    Log(file: FileManager.default.temporaryDirectory.appendingPathComponent("fwd-proxy-\(UUID().uuidString).log"))
}

private func address(_ status: ForwardAddress.Status) -> ForwardAddress {
    ForwardAddress(address: "web.localhost", name: "web", host: "devbox", text: "3000", remote: 3000, status: status)
}

@Suite struct HTTPHeadTests {
    @Test func readsARequest() throws {
        let head = try #require(HTTPHead.parse(Data("POST /x HTTP/1.1\r\nHost: web.localhost\r\norigin: http://web.localhost\r\n\r\nbody".utf8)))
        #expect(head.method == "POST")
        #expect(head.path == "/x")
        #expect(head.host == "web.localhost")
        #expect(head.origin == "http://web.localhost")
    }

    @Test func anUnfinishedHeadIsNotARequestYet() {
        #expect(HTTPHead.parse(Data("GET / HTTP/1.1\r\nHost: web".utf8)) == nil)
    }

    @Test func theOriginMustBeThePageItself() {
        #expect(HTTPHead.isSameOrigin(origin: "http://web.localhost", host: "web.localhost"))
        #expect(HTTPHead.isSameOrigin(origin: "http://WEB.localhost:8080", host: "web.localhost:8080"))
        #expect(!HTTPHead.isSameOrigin(origin: "https://evil.example", host: "web.localhost"))
        #expect(!HTTPHead.isSameOrigin(origin: "http://other.localhost", host: "web.localhost"))
        #expect(!HTTPHead.isSameOrigin(origin: "null", host: "web.localhost"))
        #expect(!HTTPHead.isSameOrigin(origin: nil, host: "web.localhost"))
    }
}

@Suite struct LoopbackTests {
    private func endpoint(_ text: String) -> NWEndpoint { .hostPort(host: NWEndpoint.Host(text), port: 50000) }

    @Test func onlyThisMacCounts() {
        #expect(NameProxy.isLoopback(endpoint("127.0.0.1")))
        #expect(NameProxy.isLoopback(endpoint("::1")))
        #expect(NameProxy.isLoopback(endpoint("::ffff:127.0.0.1")))
        #expect(!NameProxy.isLoopback(endpoint("192.168.1.5")))
        #expect(!NameProxy.isLoopback(endpoint("::ffff:192.168.1.5")))
        #expect(!NameProxy.isLoopback(endpoint("fe80::1")))
        #expect(!NameProxy.isLoopback(endpoint("2001:db8::1")))
    }
}

@Suite struct PortHolderTests {
    @Test func namesTheFirstCommand() {
        #expect(NameProxy.holder(lsofOutput: "p412\ncnginx\n") == "nginx")
        #expect(NameProxy.holder(lsofOutput: "") == nil)
    }
}

@MainActor
@Suite struct AppModelNamesTests {
    private func request(_ port: Int, _ text: String) async -> String? {
        await Task.detached { exchange(port, text) }.value
    }

    @Test func turningOnServesNamesAndSticks() async throws {
        let port = try freePort()
        let rig = try AppModelTests.Rig(namesPort: port)
        await rig.model.start(runTimer: false)
        await rig.model.setOpenByName(true)
        #expect(rig.model.namesState == .on)
        #expect(rig.model.store.loadOpenByName())

        let answer = await request(port, "GET / HTTP/1.1\r\nHost: nope.localhost\r\n\r\n")
        #expect(answer?.hasPrefix("HTTP/1.1 404") == true)

        await rig.model.setOpenByName(false)
        #expect(rig.model.namesState == .off)
        #expect(!rig.model.store.loadOpenByName())
        #expect(await request(port, "GET / HTTP/1.1\r\nHost: nope.localhost\r\n\r\n") == nil)
    }

    @Test func aSavedSettingStartsAtLaunch() async throws {
        let port = try freePort()
        let rig = try AppModelTests.Rig(namesPort: port)
        rig.model.store.saveOpenByName(true)
        await rig.model.start(runTimer: false)
        #expect(rig.model.namesState == .on)
        await rig.model.setOpenByName(false)
    }

    @Test func aBusyPortStaysOffAndIsNotSaved() async throws {
        let port = try freePort()
        let taken = NameProxy(port: UInt16(port), log: logFile(), handler: Recorder(route: .page(.unknown("x"))).handler())
        try await taken.start()
        defer { taken.stop() }
        let rig = try AppModelTests.Rig(namesPort: port)
        await rig.model.start(runTimer: false)
        await rig.model.setOpenByName(true)
        guard case .failed(let message) = rig.model.namesState else {
            Issue.record("should have failed")
            return
        }
        #expect(message.contains("Port \(port) is in use"))
        #expect(!rig.model.store.loadOpenByName())
    }

    @Test func aBusyPortAtLaunchKeepsTheSetting() async throws {
        let port = try freePort()
        let taken = NameProxy(port: UInt16(port), log: logFile(), handler: Recorder(route: .page(.unknown("x"))).handler())
        try await taken.start()
        defer { taken.stop() }
        let rig = try AppModelTests.Rig(namesPort: port)
        rig.model.store.saveOpenByName(true)
        await rig.model.start(runTimer: false)
        guard case .failed = rig.model.namesState else {
            Issue.record("should have failed")
            return
        }
        #expect(rig.model.store.loadOpenByName())
    }

    @Test func connectFromThePageConnectsAndAGetDoesNot() async throws {
        let port = try freePort()
        let rig = try AppModelTests.Rig(namesPort: port)
        await rig.model.start(runTimer: false)
        await rig.model.setOpenByName(true)
        defer { Task { await rig.model.setOpenByName(false) } }
        // Added to the file by hand, so nothing clicks to connect it.
        try "hosts:\n  devbox:\n    - port: 3000\n      name: web\n"
            .write(to: rig.model.paths.portsFile, atomically: true, encoding: .utf8)
        await rig.model.tick()
        try await eventually("the address") {
            rig.model.addressBook.addresses.first?.status == .notConnected
        }

        let host = "web.localhost:\(port)"
        let page = await request(port, "GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n")
        #expect(page?.contains("web isn&#39;t connected") == true)
        #expect(rig.box.made["devbox"] == nil, "looking at the page doesn't connect")

        let refused = "POST /__fwd/connect HTTP/1.1\r\nHost: \(host)\r\nOrigin: https://evil.example\r\n\r\n"
        #expect(await request(port, refused)?.hasPrefix("HTTP/1.1 403") == true)
        #expect(rig.box.made["devbox"] == nil, "another site can't connect")

        let click = "POST /__fwd/connect HTTP/1.1\r\nHost: \(host)\r\nOrigin: http://\(host)\r\n\r\n"
        #expect(await request(port, click)?.hasPrefix("HTTP/1.1 303") == true)
        try await eventually("connected") { rig.box.made["devbox"]?.isEmpty == false }
    }

    @Test func turnOnFromThePageTurnsTheEntryOn() async throws {
        let port = try freePort()
        let rig = try AppModelTests.Rig(namesPort: port)
        await rig.model.start(runTimer: false)
        await rig.model.setOpenByName(true)
        defer { Task { await rig.model.setOpenByName(false) } }
        try await rig.model.add(host: "devbox", text: "3000 web")
        try await rig.model.toggle(host: "devbox", text: "3000")
        try await eventually("off") { rig.pill("devbox", "3000")?.on == false }

        let host = "web.localhost:\(port)"
        let click = "POST /__fwd/on HTTP/1.1\r\nHost: \(host)\r\nOrigin: http://\(host)\r\n\r\n"
        #expect(await request(port, click)?.hasPrefix("HTTP/1.1 303") == true)
        try await eventually("on") { rig.pill("devbox", "3000")?.on == true }
    }
}

@Suite(.serialized) struct NameProxyTests {
    @Test func passesARequestThroughToTheForward() async throws {
        let app = try TestListener(greeting: "from the app")
        let recorder = Recorder(route: .forward(address(.ready(local: app.port)), port: app.port))
        let port = try freePort()
        let proxy = NameProxy(port: UInt16(port), log: logFile(), handler: recorder.handler())
        try await proxy.start()
        defer { proxy.stop() }

        let answer = exchange(port, get("web.localhost"))
        #expect(answer == "from the app")
    }

    @Test func aDownForwardGetsAPage() async throws {
        let recorder = Recorder(route: .page(.down(address(.notConnected))))
        let port = try freePort()
        let proxy = NameProxy(port: UInt16(port), log: logFile(), handler: recorder.handler())
        try await proxy.start()
        defer { proxy.stop() }

        let answer = try #require(exchange(port, get("web.localhost")))
        #expect(answer.hasPrefix("HTTP/1.1 503"))
        #expect(answer.contains("web isn&#39;t connected"))
    }

    @Test func anUnknownNameIsNotFound() async throws {
        let recorder = Recorder(route: .page(.unknown("nope.localhost")))
        let port = try freePort()
        let proxy = NameProxy(port: UInt16(port), log: logFile(), handler: recorder.handler())
        try await proxy.start()
        defer { proxy.stop() }

        let answer = try #require(exchange(port, get("nope.localhost")))
        #expect(answer.hasPrefix("HTTP/1.1 404"))
    }

    @Test func aRefusedForwardSaysItCouldNotReachTheApp() async throws {
        let closed = try freePort()
        let recorder = Recorder(route: .forward(address(.ready(local: closed)), port: closed))
        let port = try freePort()
        let proxy = NameProxy(port: UInt16(port), log: logFile(), handler: recorder.handler())
        try await proxy.start()
        defer { proxy.stop() }

        let answer = try #require(exchange(port, get("web.localhost")))
        #expect(answer.hasPrefix("HTTP/1.1 502"))
    }

    @Test func connectFromTheForwardsOwnPageRunsAndRedirects() async throws {
        let recorder = Recorder(route: .page(.down(address(.notConnected))))
        let port = try freePort()
        let proxy = NameProxy(port: UInt16(port), log: logFile(), handler: recorder.handler())
        try await proxy.start()
        defer { proxy.stop() }

        let host = "web.localhost:\(port)"
        let answer = try #require(exchange(port, post(host, path: "/__fwd/connect", origin: "http://\(host)")))
        #expect(answer.hasPrefix("HTTP/1.1 303"))
        #expect(answer.contains("Location: /"))
        #expect(recorder.actions == [.connect])
    }

    @Test func turnOnFromTheForwardsOwnPageRuns() async throws {
        let recorder = Recorder(route: .page(.down(address(.off))))
        let port = try freePort()
        let proxy = NameProxy(port: UInt16(port), log: logFile(), handler: recorder.handler())
        try await proxy.start()
        defer { proxy.stop() }

        let host = "web.localhost:\(port)"
        _ = exchange(port, post(host, path: "/__fwd/on", origin: "http://\(host)"))
        #expect(recorder.actions == [.turnOn])
    }

    @Test func anotherSiteCannotConnectOrTurnOn() async throws {
        let recorder = Recorder(route: .page(.down(address(.notConnected))))
        let port = try freePort()
        let proxy = NameProxy(port: UInt16(port), log: logFile(), handler: recorder.handler())
        try await proxy.start()
        defer { proxy.stop() }

        let host = "web.localhost:\(port)"
        for origin in ["https://evil.example", "http://other.localhost", "null", nil] as [String?] {
            let answer = try #require(exchange(port, post(host, path: "/__fwd/connect", origin: origin)))
            #expect(answer.hasPrefix("HTTP/1.1 403"), "origin \(origin ?? "none")")
        }
        #expect(recorder.actions.isEmpty)
    }

    @Test func aGetNeverConnects() async throws {
        let recorder = Recorder(route: .page(.down(address(.notConnected))))
        let port = try freePort()
        let proxy = NameProxy(port: UInt16(port), log: logFile(), handler: recorder.handler())
        try await proxy.start()
        defer { proxy.stop() }

        let host = "web.localhost:\(port)"
        _ = exchange(port, get(host, path: "/__fwd/connect"))
        #expect(recorder.actions.isEmpty)
    }

    @Test func aBusyPortFailsToStart() async throws {
        let recorder = Recorder(route: .page(.unknown("x")))
        let port = try freePort()
        let first = NameProxy(port: UInt16(port), log: logFile(), handler: recorder.handler())
        try await first.start()
        defer { first.stop() }

        let second = NameProxy(port: UInt16(port), log: logFile(), handler: recorder.handler())
        await #expect(throws: NameProxy.StartError.self) { try await second.start() }
    }

    @Test func stoppingFreesThePort() async throws {
        let recorder = Recorder(route: .page(.unknown("x")))
        let port = try freePort()
        let first = NameProxy(port: UInt16(port), log: logFile(), handler: recorder.handler())
        try await first.start()
        first.stop()

        let second = NameProxy(port: UInt16(port), log: logFile(), handler: recorder.handler())
        try await eventually("the port to come free") {
            (try? await second.start()) != nil
        }
        second.stop()
    }
}
