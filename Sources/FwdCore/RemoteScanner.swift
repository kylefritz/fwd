import Foundation

/// Finds which TCP ports are listening on the remote.
public enum RemoteScanner {
    /// Kept identical to `scripts/scan.sh`, which CI runs on Linux. It is one
    /// line with no single quotes, so it can be wrapped in `sh -c '...'` and
    /// survive any login shell, csh included. If `ss` exists but doesn't
    /// work, it falls through to the next tool.
    public static let script = #"""
    if command -v ss >/dev/null 2>&1 && ss -ltnH >/dev/null 2>&1; then echo "#fwd:ss"; ss -ltnH 2>/dev/null; elif command -v netstat >/dev/null 2>&1; then echo "#fwd:netstat"; netstat -an 2>/dev/null; elif command -v lsof >/dev/null 2>&1; then echo "#fwd:lsof"; lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null; else echo "#fwd:none"; fi

    """#

    /// The command sent to the remote. Wrapped in `sh` so it works whatever
    /// the user's login shell is.
    public static var command: String {
        "sh -c '\(script.trimmingCharacters(in: .newlines))'"
    }

    /// Listening ports, or nil when the remote has no tool we can use.
    public static func scan(_ connection: Connection) async throws -> Set<Int>? {
        parse(try await connection.run(command))
    }

    /// A `#fwd:<tool>` line names the tool; what follows is that tool's
    /// output. Anything before it (a login banner, an rc file's chatter) is
    /// skipped.
    public static func parse(_ output: String) -> Set<Int>? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        // The marker may follow rc chatter that ended without a newline
        // (a prompt file's `tput sgr0`), so look for it inside the line.
        guard let index = lines.firstIndex(where: { $0.contains("#fwd:") }),
              let marker = lines[index].range(of: "#fwd:") else {
            return nil
        }
        let rest = Array(lines[(index + 1)...])
        switch lines[index][marker.lowerBound...].trimmingCharacters(in: .whitespaces) {
        case "#fwd:ss": return parseSS(rest)
        case "#fwd:netstat": return parseNetstat(rest)
        case "#fwd:lsof": return parseLsof(rest)
        default: return nil
        }
    }

    private static func port(fromAddress address: Substring, separators: Set<Character>) -> Int? {
        guard let index = address.lastIndex(where: { separators.contains($0) }) else { return nil }
        guard let port = Int(address[address.index(after: index)...]), (1...65535).contains(port) else {
            return nil
        }
        return port
    }

    /// `LISTEN 0 128 0.0.0.0:22 0.0.0.0:*`
    static func parseSS(_ lines: [String]) -> Set<Int> {
        var ports = Set<Int>()
        for line in lines {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 4, cols[0] == "LISTEN" else { continue }
            if let p = port(fromAddress: cols[3], separators: [":"]) { ports.insert(p) }
        }
        return ports
    }

    /// macOS: `tcp4 0 0 127.0.0.1.3000 *.* LISTEN`. Linux: `tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN`.
    static func parseNetstat(_ lines: [String]) -> Set<Int> {
        var ports = Set<Int>()
        for line in lines {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 5, cols[0].hasPrefix("tcp"), cols.last == "LISTEN" else { continue }
            if let p = port(fromAddress: cols[3], separators: [":", "."]) { ports.insert(p) }
        }
        return ports
    }

    /// `node 123 me 22u IPv4 0x.. 0t0 TCP 127.0.0.1:3000 (LISTEN)`
    static func parseLsof(_ lines: [String]) -> Set<Int> {
        var ports = Set<Int>()
        for line in lines {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2, cols.last == "(LISTEN)" else { continue }
            if let p = port(fromAddress: cols[cols.count - 2], separators: [":"]) { ports.insert(p) }
        }
        return ports
    }
}
