import Darwin
import Foundation
import Testing
@testable import FwdCore

@MainActor
@Suite(.serialized) struct ControlSocketTests {
    /// Unix socket paths are short (104 bytes), so not the long temp folder.
    func socketPath() -> String { "/tmp/fwd-t-\(UUID().uuidString.prefix(8)).sock" }

    func server(_ path: String,
                _ handle: @escaping @MainActor (ControlRequest) async -> ControlReply) throws -> ControlServer {
        let s = ControlServer(path: path, handle: handle)
        try s.start()
        return s
    }

    @Test func oneRequestOneReply() async throws {
        let path = socketPath()
        let s = try server(path) {
            .success(hosts: [HostInfo(host: $0.cmd, state: "idle", status: "", inSSHConfig: true, ports: [])])
        }
        defer { s.stop() }
        let reply = try await Task.detached { try ControlClient.send(ControlRequest(cmd: "status"), to: path, timeout: 5) }.value
        #expect(reply.hosts?.first?.host == "status")
        var info = stat()
        #expect(stat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }

    @Test func nothingListeningIsUnreachable() {
        #expect(throws: ControlClient.Unreachable.self) {
            try ControlClient.send(ControlRequest(cmd: "status"), to: socketPath(), timeout: 1)
        }
    }

    @Test func aStaleSocketFileIsReplaced() async throws {
        let path = socketPath()
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let s = try server(path) { _ in .success(hosts: []) }
        defer { s.stop() }
        let reply = try await Task.detached { try ControlClient.send(ControlRequest(cmd: "status"), to: path, timeout: 5) }.value
        #expect(reply.ok)
    }

    @Test func garbageGetsAUsageReplyAndASilentClientDoesntBlockOthers() async throws {
        let path = socketPath()
        let s = try server(path) { _ in .success(hosts: []) }
        defer { s.stop() }

        // A client that connects and says nothing.
        let silent = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try UnixSocket.address(path)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(silent, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        defer { close(silent) }

        let reply = try await Task.detached { try ControlClient.send(ControlRequest(cmd: "status"), to: path, timeout: 5) }.value
        #expect(reply.ok, "a second client is answered while the first says nothing")

        let raw = try await Task.detached { () throws -> ControlReply in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var a = try UnixSocket.address(path)
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            try UnixSocket.writeAll(fd, Data("not json\n".utf8))
            return try ControlReply.decode(try #require(try UnixSocket.readLine(fd, max: 1 << 20)))
        }.value
        #expect(raw.exitCode == .usage)
    }

    @Test func aNewerProtocolGetsTheVersionMessageEvenIfItDoesntDecode() async throws {
        let path = socketPath()
        let s = try server(path) { _ in .success(hosts: []) }
        defer { s.stop() }
        let raw = try await Task.detached { () throws -> ControlReply in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var a = try UnixSocket.address(path)
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            try UnixSocket.writeAll(fd, Data("{\"v\":2,\"command\":{\"name\":\"forward\"}}\n".utf8))
            return try ControlReply.decode(try #require(try UnixSocket.readLine(fd, max: 1 << 20)))
        }.value
        #expect(raw.exitCode == .unreachable)
        #expect(raw.error == ControlError.versionMismatch.message)
    }

    @Test func theClientOnlyTalksToItsOwnUsersServer() async throws {
        let path = socketPath()
        let s = try server(path) { _ in .success(hosts: []) }
        defer { s.stop() }
        // Our own server passes the owner check; a server run by another
        // account (which tests can't create) would fail it.
        let ok = try await Task.detached { try ControlClient.send(ControlRequest(cmd: "status"), to: path, timeout: 5) }.value
        #expect(ok.ok)
        #expect(UnixSocket.peerIsMe(-1) == false, "no peer, no trust")
    }

    @Test func anOversizedRequestIsRefused() async throws {
        let path = socketPath()
        let s = try server(path) { _ in .success(hosts: []) }
        defer { s.stop() }
        let huge = ControlRequest(cmd: "forward", args: [String(repeating: "3", count: 100_000)])
        let reply = try await Task.detached { try ControlClient.send(huge, to: path, timeout: 5) }.value
        #expect(reply.exitCode == .usage)
        #expect(reply.error?.contains("too long") == true)
    }
}
