import Darwin
import Foundation

/// The few socket calls the control server and client share.
enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ControlError.failed("socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    /// Reads up to a newline. Returns nil on end of file, a timeout or an
    /// error; throws if the line runs past `max` bytes.
    static func readLine(_ fd: Int32, max: Int) throws -> Data? {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            if let newline = chunk[0..<n].firstIndex(of: UInt8(ascii: "\n")) {
                line.append(contentsOf: chunk[0..<newline])
                return line
            }
            line.append(contentsOf: chunk[0..<n])
            if line.count > max { throw ControlError.usage("the request is too long") }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                guard n > 0 else { throw ControlError(.unreachable, "the connection closed") }
                sent += n
            }
        }
    }

    /// Read and write timeouts, and no SIGPIPE if the other end goes away.
    static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }
}
