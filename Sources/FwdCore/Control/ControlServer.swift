import Darwin
import Foundation

/// Answers the `fwd` command line on a Unix socket: one JSON request line in,
/// one reply line out, per connection. The socket lives in fwd's private
/// socket folder, and only the same user may talk to it.
public final class ControlServer: @unchecked Sendable {
    public let path: String
    private let handle: @MainActor (ControlRequest) async -> ControlReply
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    /// A slow client can take up to `readTimeout` to send its request, so
    /// requests are read off the queue that accepts connections.
    private let readers = DispatchQueue(label: "fwd.control.read", attributes: .concurrent)

    static let maxRequest = 64 * 1024
    static let readTimeout: TimeInterval = 5

    public init(path: String, handle: @escaping @MainActor (ControlRequest) async -> ControlReply) {
        self.path = path
        self.handle = handle
    }

    public func start() throws {
        // A socket file left by a crashed run would make bind fail.
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.failed("couldn't make the control socket") }
        var addr = try UnixSocket.address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw ControlError.failed("couldn't listen on \(path): \(reason)")
        }
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "fwd.control"))
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    private func acceptOne() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
            close(client)
            return
        }
        UnixSocket.setTimeout(client, Self.readTimeout)
        readers.async { [handle] in
            let request: Result<ControlRequest, ControlError>
            do {
                guard let line = try UnixSocket.readLine(client, max: Self.maxRequest) else {
                    close(client)
                    return
                }
                request = .success(try ControlRequest.decode(line))
            } catch let error as ControlError {
                request = .failure(error)
            } catch {
                request = .failure(.usage("couldn't read the request (try updating fwd)"))
            }
            Task { @MainActor in
                let reply: ControlReply
                switch request {
                case .success(let r): reply = await handle(r)
                case .failure(let e): reply = .failure(e)
                }
                try? UnixSocket.writeAll(client, reply.encodedLine())
                close(client)
            }
        }
    }
}
