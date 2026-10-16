import Foundation

/// How the `fwd` command prints replies.
public enum ControlFormat {
    public static func json(_ reply: ControlReply) -> String {
        String(decoding: reply.encodedLine().dropLast(), as: UTF8.self)
    }

    /// Text for stdout on success, or a `fwd: ...` line for stderr on failure.
    public static func human(_ reply: ControlReply, command: String) -> String {
        guard reply.ok else { return "fwd: \(reply.error ?? "something went wrong")" }
        if let url = reply.url { return url }
        if let hosts = reply.hosts {
            if hosts.isEmpty { return "No hosts with ports. Forward one with: fwd <host> <port>" }
            return hosts.map { host in
                (["\(host.host)  \(host.status.isEmpty ? host.state : host.status)"]
                    + table(host.ports.map(row)).map { "  " + $0 }).joined(separator: "\n")
            }.joined(separator: "\n")
        }
        guard let host = reply.host else { return "" }
        return table(host.ports.map { [host.host] + row($0) }).joined(separator: "\n")
    }

    /// A port's columns: label, URL, state, and a note.
    private static func row(_ port: PortInfo) -> [String] {
        let label = port.name.map { "\($0) \(port.port)" } ?? port.port
        var note = port.reason ?? ""
        if port.state == "waiting" { note = "nothing listening on the remote yet" }
        if port.state == "pending" { note = "waiting for the host" }
        if !port.forwards.isEmpty {
            note = port.forwards.map { "\($0.remote)→\($0.local.map(String.init) ?? "?")" }.joined(separator: " ")
        }
        if port.keep { note = note.isEmpty ? "kept" : "\(note), kept" }
        return [label, port.url ?? "", port.state, note]
    }

    /// Pads columns to line up, two spaces apart, without trailing spaces.
    private static func table(_ rows: [[String]]) -> [String] {
        guard let columns = rows.map(\.count).max() else { return [] }
        let widths = (0..<columns).map { col in rows.map { col < $0.count ? $0[col].count : 0 }.max() ?? 0 }
        return rows.map { row in
            let line = row.enumerated().map { col, cell in
                col == row.count - 1 ? cell : cell.padding(toLength: widths[col], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
            return line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
    }
}
