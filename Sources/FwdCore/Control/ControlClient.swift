import Darwin
import Foundation

/// The `fwd` command's side of the control socket.
public enum ControlClient {
    /// Nothing answered on the socket: the app isn't running (or is starting).
    public struct Unreachable: Error {}

    public static func send(_ request: ControlRequest, to path: String, timeout: TimeInterval) throws -> ControlReply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Unreachable() }
        defer { close(fd) }
        var addr = try UnixSocket.address(path)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Unreachable() }
        guard UnixSocket.peerIsMe(fd) else {
            throw ControlError(.unreachable, "the fwd control socket belongs to another user; not using it")
        }
        UnixSocket.setTimeout(fd, timeout)
        do {
            try UnixSocket.writeAll(fd, request.encodedLine())
        } catch {
            // The app can answer before reading everything (a request that's
            // too long); its reply says why, so read it before giving up.
            if let line = try? UnixSocket.readLine(fd, max: 16 << 20), let reply = try? ControlReply.decode(line) {
                return reply
            }
            throw error
        }
        guard let line = try UnixSocket.readLine(fd, max: 16 << 20) else {
            throw ControlError.timedOut("the fwd app didn't answer in time")
        }
        return try ControlReply.decode(line)
    }
}
