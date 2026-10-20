import Foundation

/// A `LocalForward` or `RemoteForward` line from the user's ssh config.
public struct ConfigForward: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case local, remote }
    public let kind: Kind
    /// The listening port: on the laptop for local, on the remote for remote.
    public let listenPort: Int
    public let target: String

    public init(kind: Kind, listenPort: Int, target: String) {
        self.kind = kind
        self.listenPort = listenPort
        self.target = target
    }
}

public enum SSHConfig {
    /// Concrete host aliases from an ssh config, following `Include`.
    /// Pattern hosts (`*`, `?`, `!`) are skipped. Order of first appearance.
    public static func hosts(
        configPath: URL,
        sshDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        var visited = Set<String>()
        collect(configPath, sshDir: sshDir, depth: 0, visited: &visited) { name in
            if seen.insert(name).inserted { result.append(name) }
        }
        return result
    }

    /// Every file the host list depends on, for change detection.
    public static func files(
        configPath: URL,
        sshDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    ) -> [URL] {
        var visited = Set<String>()
        collect(configPath, sshDir: sshDir, depth: 0, visited: &visited) { _ in }
        return visited.sorted().map { URL(fileURLWithPath: $0) }
    }

    private static func collect(
        _ file: URL, sshDir: URL, depth: Int, visited: inout Set<String>, add: (String) -> Void
    ) {
        guard depth < 16, visited.insert(file.standardizedFileURL.path).inserted,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let tokens = tokenize(String(rawLine))
            guard let keyword = tokens.first?.lowercased() else { continue }
            let args = tokens.dropFirst()
            switch keyword {
            case "host":
                for name in args where !name.contains(where: { "*?!".contains($0) }) {
                    add(name)
                }
            case "include":
                for pattern in args {
                    for path in expand(pattern, sshDir: sshDir) {
                        collect(URL(fileURLWithPath: path), sshDir: sshDir, depth: depth + 1,
                                visited: &visited, add: add)
                    }
                }
            default:
                continue
            }
        }
    }

    /// Splits a config line into keyword and arguments: handles `key=value`,
    /// double quotes, and comments.
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var hadQuotes = false
        func flush() {
            if !current.isEmpty || hadQuotes { tokens.append(current) }
            current = ""
            hadQuotes = false
        }
        for ch in line {
            if inQuotes {
                if ch == "\"" { inQuotes = false } else { current.append(ch) }
            } else if ch == "\"" {
                inQuotes = true
                hadQuotes = true
            } else if ch == "#" && current.isEmpty && !hadQuotes {
                break
            } else if ch == " " || ch == "\t" || (ch == "=" && tokens.isEmpty) {
                flush()
            } else {
                current.append(ch)
            }
        }
        flush()
        return tokens
    }

    private static func expand(_ pattern: String, sshDir: URL) -> [String] {
        var path = pattern
        if path.hasPrefix("~/") {
            path = FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
        } else if !path.hasPrefix("/") {
            path = sshDir.appendingPathComponent(path).path
        }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(path, 0, nil, &g) == 0, let pathv = g.gl_pathv else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { pathv[$0].map { String(cString: $0) } }
    }

    /// Trailing `# comments` on `LocalForward`/`RemoteForward` lines, which
    /// `ssh -G` throws away: host alias -> (kind, listen port) -> comment.
    /// Forwards under a pattern `Host` (like `*`) are filed under `"*"`.
    public static func forwardNotes(
        configPath: URL,
        sshDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    ) -> [String: [ForwardKey: String]] {
        var notes: [String: [ForwardKey: String]] = [:]
        var visited = Set<String>()
        var hostNames: [String] = ["*"]
        func walk(_ file: URL, depth: Int) {
            guard depth < 16, visited.insert(file.standardizedFileURL.path).inserted,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = String(rawLine)
                let tokens = tokenize(line)
                guard let keyword = tokens.first?.lowercased() else { continue }
                switch keyword {
                case "host":
                    let names = tokens.dropFirst().map { name in
                        name.contains(where: { "*?!".contains($0) }) ? "*" : name
                    }
                    hostNames = names.isEmpty ? ["*"] : names
                case "include":
                    for pattern in tokens.dropFirst() {
                        for path in expand(pattern, sshDir: sshDir) {
                            walk(URL(fileURLWithPath: path), depth: depth + 1)
                        }
                    }
                case "localforward", "remoteforward":
                    guard tokens.count >= 2, let comment = trailingComment(line),
                          let port = Int(tokens[1].split(separator: ":").last ?? "") else { continue }
                    let key = ForwardKey(kind: keyword == "localforward" ? .local : .remote, listenPort: port)
                    for name in hostNames { notes[name, default: [:]][key] = comment }
                default:
                    continue
                }
            }
        }
        walk(configPath, depth: 0)
        return notes
    }

    public struct ForwardKey: Hashable, Sendable {
        public let kind: ConfigForward.Kind
        public let listenPort: Int
    }

    /// The text after the first unquoted `#` that starts a word, trimmed.
    static func trailingComment(_ line: String) -> String? {
        var inQuotes = false
        var previous: Character = " "
        for index in line.indices {
            let ch = line[index]
            if ch == "\"" { inQuotes.toggle() }
            else if ch == "#", !inQuotes, previous == " " || previous == "\t" {
                let text = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : text
            }
            previous = ch
        }
        return nil
    }

    /// Pulls forwards out of `ssh -G <host>` output, whose lines look like
    /// `localforward 8000 [127.0.0.1]:8000` and `remoteforward 9222 localhost:9222`.
    public static func parseForwards(sshG output: String) -> [ConfigForward] {
        var result: [ConfigForward] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let kind: ConfigForward.Kind
            switch parts[0].lowercased() {
            case "localforward": kind = .local
            case "remoteforward": kind = .remote
            default: continue
            }
            // The listen spec is `port`, `addr:port` or `[addr]:port`.
            let listen = String(parts[1])
            let portText = listen.split(separator: ":").last.map(String.init) ?? listen
            guard let port = Int(portText) else { continue }
            let target = parts.count >= 3 ? String(parts[2]) : ""
            let forward = ConfigForward(kind: kind, listenPort: port, target: target)
            if !result.contains(forward) { result.append(forward) }
        }
        return result
    }
}
