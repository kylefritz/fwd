import Foundation
import Network

/// What a click on one of fwd's own pages asks for.
public enum NameAction: Equatable, Sendable {
    case connect
    case turnOn

    var path: String {
        switch self {
        case .connect: return "/__fwd/connect"
        case .turnOn: return "/__fwd/on"
        }
    }

    init?(path: String) {
        switch path {
        case Self.connect.path: self = .connect
        case Self.turnOn.path: self = .turnOn
        default: return nil
        }
    }
}

/// The part of an HTTP request the proxy reads before passing the bytes on.
struct HTTPHead: Equatable {
    let method: String
    let path: String
    let host: String?
    let origin: String?

    /// nil until `data` holds the whole head.
    static func parse(_ data: Data) -> HTTPHead? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return HTTPHead(method: String(start[0]), path: String(start[1]), host: headers["host"], origin: headers["origin"])
    }

    /// Whether a request came from a page on `host` itself. Any site can make
    /// a browser post to these addresses, and browsers won't let it fake this.
    static func isSameOrigin(origin: String?, host: String) -> Bool {
        origin?.lowercased() == "http://\(host.lowercased())"
    }
}

/// The listener behind `name.localhost`. Without root, macOS only lets a
/// process bind port 80 on all interfaces, so forwards would be open to the
/// network if this didn't close everything that isn't from this Mac.
public final class NameProxy: @unchecked Sendable {
    public struct Handler: Sendable {
        public let route: @Sendable (String) async -> NameRoute
        public let perform: @Sendable (NameAction, NameRoute) async -> Void

        public init(route: @escaping @Sendable (String) async -> NameRoute,
                    perform: @escaping @Sendable (NameAction, NameRoute) async -> Void) {
            self.route = route
            self.perform = perform
        }
    }

    public enum StartError: Error, CustomStringConvertible {
        case portInUse
        case failed(String)

        public var description: String {
            switch self {
            case .portInUse: return "the port is in use"
            case .failed(let message): return message
            }
        }
    }

    /// Most a request's head can be before it's turned away.
    private static let headLimit = 64 * 1024
    /// How long a connection has to say what it wants.
    private static let headTimeout: TimeInterval = 15

    private let port: UInt16
    private let log: Log
    private let handler: Handler
    private let queue = DispatchQueue(label: "fwd.names")
    private var listener: NWListener?
    private var open: [ObjectIdentifier: NWConnection] = [:]
    /// The last route logged for each address, since fwd's pages reload
    /// themselves every few seconds.
    private var logged: [String: String] = [:]

    /// Called if the listener dies after it started, with why.
    public var onFailure: (@Sendable (String) -> Void)?

    public init(port: UInt16, log: Log, handler: Handler) {
        self.port = port
        self.log = log
        self.handler = handler
    }

    /// Returns once the port is held, or throws why it can't be.
    public func start() async throws {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { throw StartError.failed("Port \(port) isn't valid") }
        let parameters = NWParameters.tcp
        // Pages hang up first, which leaves connections in TIME_WAIT that
        // would otherwise block binding again right after a restart.
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: endpoint)
        } catch {
            throw StartError.failed("\(error)")
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<Void, Error>) in
            var settled = false
            func settle(_ result: Result<Void, Error>) {
                guard !settled else { return }
                settled = true
                waiting.resume(with: result)
            }
            func failure(_ error: NWError) -> StartError {
                if case .posix(.EADDRINUSE) = error { return .portInUse }
                return .failed("\(error)")
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.listener = listener
                    settle(.success(()))
                case .waiting(let error), .failed(let error):
                    listener.cancel()
                    if settled { self?.onFailure?("\(error)") }
                    settle(.failure(failure(error)))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in open.values { connection.cancel() }
            open = [:]
        }
    }

    /// Whether a connection comes from this Mac. A v4 client on the dual-stack
    /// listener can appear as `::ffff:127.0.0.1`.
    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || address.asIPv4?.isLoopback == true
        default: return false
        }
    }

    /// What's holding the port, from `lsof -Fc`. Only sees this user's
    /// processes, so a server run as root comes back nil.
    static func holder(lsofOutput: String) -> String? {
        lsofOutput.split(whereSeparator: \.isNewline).first { $0.hasPrefix("c") }.map { String($0.dropFirst()) }
    }

    /// Where a request went, for the log.
    static func describe(_ route: NameRoute) -> String {
        switch route {
        case .forward(let forward, let port): return "passing to localhost:\(port) on \(forward.host)"
        case .page(.down(let forward)): return "\(forward.status), port \(forward.remote) on \(forward.host)"
        case .page(.unreachable(let forward)): return "unreachable, port \(forward.remote) on \(forward.host)"
        case .page(.several(_, let found)): return "on \(found.count) hosts"
        case .page(.unknown): return "nothing has this name"
        }
    }

    /// Text from a request, made safe for one line of the log.
    static func clean(_ text: String) -> String {
        String(text.filter { character in
            !character.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }.prefix(100))
    }

    /// Logs where `host` went, if that's changed since last time.
    private func note(_ route: NameRoute, for host: String) {
        let host = Self.clean(host)
        let description = Self.describe(route)
        queue.async {
            guard self.logged[host] != description else { return }
            if self.logged.count > 200 { self.logged = [:] }
            self.logged[host] = description
            self.log.write("names: \(host): \(description)")
        }
    }

    public static func holder(ofPort port: UInt16) async -> String? {
        holder(lsofOutput: await Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fc"], timeout: 5).stdout)
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        // Before anything is read: this is the only thing between forwards
        // and the network.
        guard Self.isLoopback(connection.endpoint) else {
            log.write("names: refused a connection from \(connection.endpoint)")
            connection.cancel()
            return
        }
        track(connection)
        connection.start(queue: queue)
        var decided = false
        queue.asyncAfter(deadline: .now() + Self.headTimeout) {
            if !decided { connection.cancel() }
        }
        readHead(connection, Data()) { decided = true }
    }

    /// Remembers a connection until it ends, so `stop` can close it.
    private func track(_ connection: NWConnection, onChange: ((NWConnection.State) -> Void)? = nil) {
        open[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            onChange?(state)
            switch state {
            case .failed:
                connection?.cancel()
            case .cancelled:
                if let connection { self?.open[ObjectIdentifier(connection)] = nil }
            default:
                break
            }
        }
    }

    private func readHead(_ connection: NWConnection, _ buffer: Data, decided: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.headLimit) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            if let head = HTTPHead.parse(buffer) {
                decided()
                Task { await self.answer(head, buffer: buffer, on: connection) }
            } else if buffer.count > Self.headLimit {
                decided()
                self.reply(connection, 431, "Request Header Fields Too Large", "")
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.readHead(connection, buffer, decided: decided)
            }
        }
    }

    private func answer(_ head: HTTPHead, buffer: Data, on connection: NWConnection) async {
        guard let host = head.host else {
            reply(connection, 400, "Bad Request", "")
            return
        }
        let route = await handler.route(host)
        if head.method == "POST", let action = NameAction(path: head.path) {
            guard HTTPHead.isSameOrigin(origin: head.origin, host: host) else {
                log.write("names: refused \(action) for \(Self.clean(host)) from \(Self.clean(head.origin ?? "no origin"))")
                reply(connection, 403, "Forbidden", "")
                return
            }
            log.write("names: \(action) clicked on \(Self.clean(host))")
            await handler.perform(action, route)
            reply(connection, 303, "See Other", "", headers: "Location: /\r\n")
            return
        }
        note(route, for: host)
        switch route {
        case .forward(let forward, let port):
            queue.async { self.pass(buffer, of: connection, to: forward, port: port) }
        case .page(let page):
            send(page, on: connection)
        }
    }

    private func send(_ page: NamePage, on connection: NWConnection) {
        let status = NamePages.status(for: page)
        reply(connection, status.code, status.reason, NamePages.html(for: page))
    }

    private func reply(_ connection: NWConnection, _ code: Int, _ reason: String, _ body: String, headers: String = "") {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\(headers)\r\n"
        connection.send(content: Data(head.utf8) + bytes, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: Passing bytes through

    private func pass(_ buffer: Data, of client: NWConnection, to forward: ForwardAddress, port: Int) {
        guard let target = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        let upstream = NWConnection(host: .ipv4(.loopback), port: target, using: .tcp)
        var settled = false
        track(upstream) { [weak self] state in
            guard let self, !settled else { return }
            switch state {
            case .ready:
                settled = true
                let tunnel = Tunnel(client, upstream)
                upstream.send(content: buffer, completion: .contentProcessed { _ in })
                self.pump(from: client, to: upstream, tunnel)
                self.pump(from: upstream, to: client, tunnel)
            case .waiting(let error), .failed(let error):
                settled = true
                self.log.write("names: localhost:\(port) refused \(forward.address): \(error)", host: forward.host)
                upstream.cancel()
                self.send(.unreachable(forward), on: client)
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    /// Both directions of one request's connection. Each side's end is passed
    /// on, so half-closing works, and the pair closes when both have ended.
    private final class Tunnel {
        private let ends: [NWConnection]
        private var finished = 0

        init(_ a: NWConnection, _ b: NWConnection) { ends = [a, b] }

        func finishOne() {
            finished += 1
            if finished == 2 { close() }
        }

        func close() {
            for end in ends { end.cancel() }
        }
    }

    private func pump(from source: NWConnection, to destination: NWConnection, _ tunnel: Tunnel) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil else {
                tunnel.close()
                return
            }
            func next() {
                guard isComplete else {
                    self.pump(from: source, to: destination, tunnel)
                    return
                }
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                 completion: .contentProcessed { _ in tunnel.finishOne() })
            }
            guard let data, !data.isEmpty else {
                next()
                return
            }
            destination.send(content: data, completion: .contentProcessed { problem in
                if problem == nil { next() } else { tunnel.close() }
            })
        }
    }
}
