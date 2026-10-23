import Foundation

/// What the `fwd` command sends the app: one line of JSON per connection.
public struct ControlRequest: Codable, Equatable, Sendable {
    /// Bumped when a request or reply changes shape, so a command and an app
    /// from different versions fail clearly instead of misreading each other.
    public static let version = 1

    public var v: Int
    public var cmd: String
    /// Positional arguments exactly as typed; the app resolves host and ports.
    public var args: [String]
    public var keep: Bool
    public var wait: Bool
    public var off: Bool
    public var all: Bool
    public var timeout: Double?

    public init(cmd: String, args: [String] = [], keep: Bool = false, wait: Bool = false,
                off: Bool = false, all: Bool = false, timeout: Double? = nil) {
        self.v = Self.version
        self.cmd = cmd
        self.args = args
        self.keep = keep
        self.wait = wait
        self.off = off
        self.all = all
        self.timeout = timeout
    }

    public static func decode(_ line: Data) throws -> ControlRequest {
        try JSONDecoder().decode(ControlRequest.self, from: line)
    }

    public func encodedLine() -> Data { ControlCoding.line(self) }
}

/// The command's exit status, also carried in failed replies.
public enum ExitCode: Int, Codable, Sendable {
    case ok = 0, failed = 1, usage = 2, unreachable = 3, timedOut = 4
}

public struct ControlError: Error, Equatable, Sendable {
    public let code: ExitCode
    public let message: String

    public init(_ code: ExitCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public static func usage(_ message: String) -> ControlError { ControlError(.usage, message) }
    public static func failed(_ message: String) -> ControlError { ControlError(.failed, message) }
    public static func timedOut(_ message: String) -> ControlError { ControlError(.timedOut, message) }
    public static let versionMismatch = ControlError(
        .unreachable, "This fwd command and the fwd app are different versions; update fwd.")
}

/// One forwarded port of a range.
public struct ForwardInfo: Codable, Equatable, Sendable {
    public let remote: Int
    public let local: Int?
    public let url: String?
    public let state: String

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(remote, forKey: .remote)
        try c.encode(local, forKey: .local)
        try c.encode(url, forKey: .url)
        try c.encode(state, forKey: .state)
    }
}

/// A port as the command line reports it. Every key is always present,
/// null when it has no value, so agents can rely on the shape.
public struct PortInfo: Codable, Equatable, Sendable {
    public let port: String
    public let name: String?
    public let on: Bool
    public let keep: Bool
    public let state: String
    public let reason: String?
    public let local: Int?
    public let url: String?
    public let forwards: [ForwardInfo]

    public init(port: String, name: String?, on: Bool, keep: Bool, state: String, reason: String?,
                local: Int?, url: String?, forwards: [ForwardInfo]) {
        self.port = port
        self.name = name
        self.on = on
        self.keep = keep
        self.state = state
        self.reason = reason
        self.local = local
        self.url = url
        self.forwards = forwards
    }

    public init(pill: Pill) {
        self.init(port: pill.text, name: pill.name, on: pill.on, keep: pill.keep,
                  state: Self.stateName(pill.state), reason: Self.reason(pill.state),
                  local: pill.local, url: pill.openURL?.absoluteString,
                  forwards: pill.ports.map {
                      ForwardInfo(remote: $0.remote, local: $0.local, url: $0.openURL?.absoluteString,
                                  state: Self.stateName($0.state))
                  })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(port, forKey: .port)
        try c.encode(name, forKey: .name)
        try c.encode(on, forKey: .on)
        try c.encode(keep, forKey: .keep)
        try c.encode(state, forKey: .state)
        try c.encode(reason, forKey: .reason)
        try c.encode(local, forKey: .local)
        try c.encode(url, forKey: .url)
        try c.encode(forwards, forKey: .forwards)
    }

    static func stateName(_ state: PillState) -> String {
        switch state {
        case .off: return "off"
        case .pending: return "pending"
        case .waiting: return "waiting"
        case .live: return "live"
        case .active: return "active"
        case .blocked: return "blocked"
        case .invalid: return "invalid"
        }
    }

    static func reason(_ state: PillState) -> String? {
        switch state {
        case .blocked(let why), .invalid(let why): return why
        default: return nil
        }
    }

    /// Forwarded: a tunnel exists, whether or not a server answers yet.
    var isForwarded: Bool { ["waiting", "live", "active"].contains(state) }
    /// A server answers on the remote port (for a range, on at least one).
    var isLive: Bool {
        ["live", "active"].contains(state) || forwards.contains { ["live", "active"].contains($0.state) }
    }
}

public struct HostInfo: Codable, Equatable, Sendable {
    public let host: String
    public let state: String
    public let status: String
    public let inSSHConfig: Bool
    public let ports: [PortInfo]

    public init(host: String, state: String, status: String, inSSHConfig: Bool, ports: [PortInfo]) {
        self.host = host
        self.state = state
        self.status = status
        self.inSSHConfig = inSSHConfig
        self.ports = ports
    }

    /// `only` limits the ports to those entries (by canonical text).
    public init(card: HostCard, only: Set<String>? = nil) {
        self.init(host: card.name, state: Self.stateName(card.state), status: card.statusLine,
                  inSSHConfig: card.inConfig,
                  ports: card.pills.filter { only?.contains($0.text) ?? true }.map(PortInfo.init(pill:)))
    }

    static func stateName(_ state: HostState) -> String {
        switch state {
        case .idle: return "idle"
        case .standby: return "standby"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .retrying: return "retrying"
        case .paused: return "paused"
        case .needsAttention: return "needs-attention"
        }
    }
}

public struct ControlReply: Codable, Equatable, Sendable {
    public let ok: Bool
    public let code: Int?
    public let error: String?
    public let host: HostInfo?
    public let hosts: [HostInfo]?
    public let url: String?
    /// A sentence for commands that report no host, like `try`.
    public var message: String? = nil

    public static func success(host: HostInfo) -> ControlReply {
        ControlReply(ok: true, code: nil, error: nil, host: host, hosts: nil, url: nil)
    }

    public static func success(message: String) -> ControlReply {
        ControlReply(ok: true, code: nil, error: nil, host: nil, hosts: nil, url: nil, message: message)
    }

    public static func success(hosts: [HostInfo]) -> ControlReply {
        ControlReply(ok: true, code: nil, error: nil, host: nil, hosts: hosts, url: nil)
    }

    public static func success(host: HostInfo, url: String) -> ControlReply {
        ControlReply(ok: true, code: nil, error: nil, host: host, hosts: nil, url: url)
    }

    public static func failure(_ error: ControlError, host: HostInfo? = nil) -> ControlReply {
        ControlReply(ok: false, code: error.code.rawValue, error: error.message, host: host, hosts: nil, url: nil)
    }

    public var exitCode: ExitCode { ok ? .ok : (code.flatMap(ExitCode.init(rawValue:)) ?? .failed) }

    public static func decode(_ line: Data) throws -> ControlReply {
        try JSONDecoder().decode(ControlReply.self, from: line)
    }

    public func encodedLine() -> Data { ControlCoding.line(self) }
}

enum ControlCoding {
    /// Sorted keys and no pretty printing: one line, the same bytes every time.
    static func line<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
