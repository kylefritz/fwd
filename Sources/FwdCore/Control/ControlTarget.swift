import Foundation

/// The host and ports a command acts on, worked out from its arguments.
public struct ControlTarget: Equatable {
    public let host: String
    /// Port texts as they'd be typed in the panel, with any name:
    /// `3000`, `5173 web`, `3000 -> 4000`.
    public let ports: [String]

    public init(host: String, ports: [String]) {
        self.host = host
        self.ports = ports
    }

    /// Reads `[host] <port> [name] <port> [name]...`. The host is the first
    /// argument when it's a known host; otherwise it's left out and taken
    /// from `defaultHosts` when there's exactly one.
    public static func resolve(_ args: [String], hosts: [String], defaultHosts: [String],
                               noun: String) throws -> ControlTarget {
        var rest = args[...]
        let host: String
        if let first = rest.first, hosts.contains(first) {
            host = first
            rest = rest.dropFirst()
        } else if let first = rest.first, canonical(first) == nil {
            throw ControlError.usage("\"\(first)\" isn't a command, a host or a port (try fwd --help)")
        } else if defaultHosts.count == 1 {
            host = defaultHosts[0]
        } else if defaultHosts.isEmpty {
            throw ControlError.usage("no host is \(noun); say which, like: fwd devbox 3000")
        } else {
            throw ControlError.usage("\(defaultHosts.count) hosts are \(noun) "
                + "(\(defaultHosts.joined(separator: ", "))); say which, like: fwd \(defaultHosts[0]) 3000")
        }

        var ports: [String] = []
        var named = true  // a name needs a port before it that doesn't have one yet
        for arg in rest {
            if canonical(arg) != nil {
                ports.append(arg)
                named = EntryName.split(arg).name != nil
            } else if !named, let letter = arg.first, letter.isLetter, !arg.contains(" ") {
                ports[ports.count - 1] += " \(arg)"
                named = true
            } else {
                throw ControlError.usage("\"\(arg)\" isn't a port or a name for one (try fwd --help)")
            }
        }
        return ControlTarget(host: host, ports: ports)
    }

    /// The entry a port argument stands for, as ports.yaml stores it.
    public static func canonical(_ port: String) -> String? {
        try? PortPattern.parse(EntryName.split(port).port).text
    }
}
