import Foundation
import Testing
@testable import FwdCore

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Polls until `condition` holds or the timeout passes.
@MainActor
func eventually(_ what: String, timeout: Double = 15, _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw TestFailure("timed out waiting for: \(what)")
}

private func loopback(_ port: Int) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return addr
}

/// A TCP server on 127.0.0.1 that greets each client and hangs up.
final class TestListener: @unchecked Sendable {
    let port: Int
    let greeting: String
    private let fd: Int32
    private var stopped = false

    /// `port` 0 picks any free port.
    init(port: Int = 0, greeting: String = "hello") throws {
        self.greeting = greeting
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = loopback(port)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw TestFailure("couldn't listen on \(port): \(String(cString: strerror(errno)))")
        }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.port = Int(in_port_t(bigEndian: actual.sin_port))
        let serverFD = fd
        let bytes = Array(greeting.utf8)
        Thread.detachNewThread {
            while true {
                let client = accept(serverFD, nil, nil)
                if client < 0 { return }
                _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                close(client)
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    deinit { stop() }
}

/// Connects to 127.0.0.1:port and returns what the server says, or nil if
/// nothing answers.
func fetch(_ port: Int) -> String? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var addr = loopback(port)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: 256)
    let n = read(fd, &buffer, buffer.count)
    guard n > 0 else { return nil }
    return String(decoding: buffer[0..<n], as: UTF8.self)
}

/// A port nothing is using right now.
func freePort() throws -> Int {
    let listener = try TestListener()
    let port = listener.port
    listener.stop()
    return port
}

/// The start of a block of ten consecutive free ports whose shifted copy
/// (`+ shift`) is free too. Returned base is a multiple of ten.
func freeBlockOfTen(shift: Int) throws -> Int {
    for _ in 0..<200 {
        let base = Int.random(in: 2000..<5000) * 10
        let all = Array(base..<(base + 10)) + Array((base + shift)..<(base + shift + 10))
        if all.allSatisfy(PortAllocator.systemIsFree) { return base }
    }
    throw TestFailure("no free block of ports found")
}

final class FakePower: PowerEvents {
    var onEvent: ((PowerEvent) -> Void)?
    var lidClosed = false
    var networkUp = true
}

/// A scripted `Connection` for testing the session without ssh.
final class FakeConnection: Connection, @unchecked Sendable {
    var onExit: (() -> Void)?
    var masterPID: Int32? { alive ? 1 : nil }
    var alive = false
    var startError: ConnectionError?
    var listening: String = "#ss\n"
    var forwards: [Forward] = []
    /// Called inside addForward, before it returns; may throw.
    var onAddForward: ((FakeConnection, Int, Int) throws -> Void)?
    var stopCount = 0

    func start() async throws {
        if let startError { throw startError }
        alive = true
    }
    func isAlive() async -> Bool { alive }
    func stop() async {
        alive = false
        stopCount += 1
    }
    func addForward(local: Int, remote: Int) async throws {
        guard alive else { throw ConnectionError.failed("Not connected") }
        try onAddForward?(self, local, remote)
        forwards.append(Forward(remote: remote, local: local, entry: ""))
    }
    func cancelForward(local: Int, remote: Int) async throws {
        forwards.removeAll { $0.remote == remote && $0.local == local }
    }
    func run(_ command: String) async throws -> String {
        guard alive else { throw ConnectionError.failed("Not connected") }
        return listening
    }
    /// Simulates the link dropping by itself.
    func die() {
        alive = false
        onExit?()
    }
}

/// A throwaway OpenSSH server on 127.0.0.1, run as the current user with
/// generated keys. Only ever signals processes it started.
final class SSHTestServer {
    let dir: URL
    let port: Int
    let paths: Paths
    /// A laptop port named by a `LocalForward` line in the test config.
    let configLocalForward: Int
    /// A remote port named by a `RemoteForward` line in the test config.
    let configRemoteForward: Int
    private var process: Process?

    /// Hosts defined in the generated ssh config.
    static let goodHost = "testbox"
    static let secondHost = "testbox2"
    static let badKeyHost = "badkey"

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-sshd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        port = try freePort()
        configLocalForward = try freePort()
        configRemoteForward = try freePort()
        var env = ["FWD_HOME": dir.appendingPathComponent("home").path]
        env["FWD_SSH_CONFIG"] = dir.appendingPathComponent("ssh_config").path
        paths = Paths.fromEnvironment(env)

        for name in ["hostkey", "userkey", "wrongkey"] {
            try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", dir.appendingPathComponent(name).path])
        }
        let authorized = dir.appendingPathComponent("authorized_keys")
        try FileManager.default.copyItem(at: dir.appendingPathComponent("userkey.pub"), to: authorized)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorized.path)

        try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(dir.path)/hostkey
        PidFile \(dir.path)/sshd.pid
        AuthorizedKeysFile \(authorized.path)
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        AllowTcpForwarding yes
        MaxSessions 50
        MaxStartups 50

        """.write(to: dir.appendingPathComponent("sshd_config"), atomically: true, encoding: .utf8)

        func host(_ name: String, key: String, extra: String = "") -> String {
            """
            Host \(name)
              HostName 127.0.0.1
              Port \(port)
              User \(NSUserName())
              IdentityFile \(dir.path)/\(key)
              IdentitiesOnly yes
              IdentityAgent none
              UserKnownHostsFile \(dir.path)/known_hosts
              StrictHostKeyChecking accept-new
            \(extra)

            """
        }
        let forwards = "  LocalForward \(configLocalForward) 127.0.0.1:\(configLocalForward)\n  RemoteForward \(configRemoteForward) 127.0.0.1:\(configRemoteForward)"
        try (host(Self.goodHost, key: "userkey", extra: forwards) + host(Self.secondHost, key: "userkey")
            + host(Self.badKeyHost, key: "wrongkey") + "Host pattern-*\n  User nobody\n")
            .write(to: paths.sshConfig, atomically: true, encoding: .utf8)

        try start()
    }

    private static func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw TestFailure("\(exe) failed") }
    }

    func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        p.arguments = ["-D", "-f", dir.appendingPathComponent("sshd_config").path,
                       "-E", dir.appendingPathComponent("sshd.log").path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !PortAllocator.systemIsFree(port) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw TestFailure("sshd didn't start listening")
    }

    /// Stops the server and every session it spawned, like a host going away.
    func stop() {
        guard let p = process, p.isRunning else { return }
        let listener = p.processIdentifier
        // Sessions are children of our listener; collect them before it exits.
        let children = Self.childPIDs(of: listener)
        p.terminate()
        p.waitUntilExit()
        for child in children {
            for grandchild in Self.childPIDs(of: child) { kill(grandchild, SIGKILL) }
            kill(child, SIGKILL)
        }
        process = nil
    }

    private static func childPIDs(of parent: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(parent)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    func cleanup() {
        stop()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: paths.socketDir)
    }

    deinit { cleanup() }
}
