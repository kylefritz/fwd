import Foundation

/// Reads which directories a host's herdr has panes open in, for the VS Code
/// button's menu. Read-only: it asks herdr for a snapshot and changes nothing.
public enum Herdr {
    /// What a directory's dot shows. Sorted in this order in the menu.
    public enum Status: Int, Comparable, Sendable {
        /// An agent there is waiting on you (herdr's `blocked`).
        case blocked
        /// An agent is running there, whatever it's doing.
        case agent
        /// A pane is open there with no agent in it.
        case none

        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Directory: Equatable, Identifiable, Sendable {
        /// Absolute, on the remote.
        public let path: String
        /// The path with the remote's home shown as `~`.
        public let display: String
        public let status: Status
        public var id: String { path }

        public var name: String {
            display == "~" || display == "/" ? display : (display as NSString).lastPathComponent
        }
    }

    public enum Listing: Equatable, Sendable {
        case directories([Directory])
        case notInstalled
        case notRunning
        case failed(String)
    }

    /// One line with no single quotes, so it can be wrapped in `sh -c '...'`
    /// like the port scan. A non-interactive ssh command often lacks the
    /// login PATH, so the usual install folders are tried too. herdr's exit
    /// status is reported on a line of its own rather than as the command's,
    /// so a herdr error arrives as output instead of an ssh failure.
    public static let script = #"""
    echo "#fwd:home $HOME"; h=$(command -v herdr 2>/dev/null); for p in "$HOME/.local/bin/herdr" "$HOME/.cargo/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr; do [ -n "$h" ] && break; [ -x "$p" ] && h="$p"; done; if [ -z "$h" ]; then echo "#fwd:noherdr"; else echo "#fwd:herdr"; "$h" api snapshot; s=$?; echo; echo "#fwd:exit $s"; fi
    """#

    public static var command: String {
        "sh -c '\(script.trimmingCharacters(in: .newlines))'"
    }

    /// Reads the script's output. Lines before the first marker (a login
    /// banner, an rc file's chatter) are skipped.
    public static func parse(_ output: String) -> Listing {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        func marker(_ name: String) -> Int? { lines.firstIndex { $0.contains("#fwd:\(name)") } }
        if marker("noherdr") != nil { return .notInstalled }
        guard let start = marker("herdr") else { return .failed("The host didn't answer as expected.") }
        let home = marker("home").flatMap { index -> String? in
            guard let range = lines[index].range(of: "#fwd:home ") else { return nil }
            let value = lines[index][range.upperBound...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("#fwd:exit") } ?? lines.endIndex
        let json = lines[(start + 1)..<end].joined(separator: "\n")

        guard let reply = try? JSONDecoder.snakeCase.decode(Reply.self, from: Data(json.utf8)) else {
            let exit = end < lines.endIndex ? lines[end].dropFirst("#fwd:exit".count).trimmingCharacters(in: .whitespaces) : "?"
            return .failed("herdr didn't give a snapshot (exit status \(exit)).")
        }
        if let error = reply.error {
            if error.code == "server_not_running" { return .notRunning }
            return .failed(error.message ?? error.code ?? "herdr reported an error.")
        }
        return .directories(directories(reply.result?.snapshot.panes ?? [], home: home))
    }

    /// One row per directory, however many panes are in it, showing the
    /// most pressing status among them.
    static func directories(_ panes: [Pane], home: String?) -> [Directory] {
        var status: [String: Status] = [:]
        for pane in panes {
            guard let path = pane.foregroundCwd ?? pane.cwd, path.hasPrefix("/") else { continue }
            let mine: Status = pane.agent == nil ? .none : pane.agentStatus == "blocked" ? .blocked : .agent
            status[path] = min(status[path] ?? .none, mine)
        }
        return status.map { Directory(path: $0.key, display: tilde($0.key, home: home), status: $0.value) }
            .sorted { ($0.status, $0.name.lowercased(), $0.display) < ($1.status, $1.name.lowercased(), $1.display) }
    }

    static func tilde(_ path: String, home: String?) -> String {
        guard let home, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    struct Reply: Decodable {
        struct Result: Decodable { let snapshot: Snapshot }
        struct Snapshot: Decodable { let panes: [Pane] }
        struct Failure: Decodable { let code: String?; let message: String? }
        let result: Result?
        let error: Failure?
    }

    struct Pane: Decodable {
        let cwd: String?
        let foregroundCwd: String?
        let agent: String?
        let agentStatus: String?
    }
}

extension JSONDecoder {
    static var snakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
