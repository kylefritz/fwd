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
    /// login PATH, so the usual install folders are tried too. herdr can run
    /// several named sessions, each with its own server, and a snapshot only
    /// covers one, so every session is asked. Each herdr exit status is
    /// reported on a line of its own rather than as the command's, so a herdr
    /// error arrives as output instead of an ssh failure.
    public static let script = #"""
    echo "#fwd:home $HOME"; h=$(command -v herdr 2>/dev/null); for p in "$HOME/.local/bin/herdr" "$HOME/.cargo/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr; do [ -n "$h" ] && break; [ -x "$p" ] && h="$p"; done; if [ -z "$h" ]; then echo "#fwd:noherdr"; else echo "#fwd:herdr $h"; echo "#fwd:version $("$h" --version 2>/dev/null | head -n 1)"; n=$("$h" session list --json 2>/dev/null | tr "," "\n" | grep "\"name\":" | sed "s/.*\"name\":\"//; s/\".*//"); [ -z "$n" ] && n=default; for x in $n; do echo "#fwd:session $x"; "$h" --session "$x" api snapshot; e=$?; echo; echo "#fwd:exit $e"; done; fi
    """#

    public static var command: String {
        "sh -c '\(script.trimmingCharacters(in: .newlines))'"
    }

    /// What the menu shows, and a line for the log saying how it got there.
    public struct Answer: Equatable, Sendable {
        public let listing: Listing
        public let details: String
    }

    public static func parse(_ output: String) -> Listing { read(output).listing }

    /// Reads the script's output. Lines before the first marker (a login
    /// banner, an rc file's chatter) are skipped. Sessions that aren't running
    /// are left out; the listing is "not running" only when none is.
    public static func read(_ output: String) -> Answer {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        func value(_ name: String) -> String? {
            for line in lines {
                guard let range = line.range(of: "#fwd:\(name) ") else { continue }
                let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            return nil
        }
        if lines.contains(where: { $0.contains("#fwd:noherdr") }) {
            return Answer(listing: .notInstalled, details: "herdr not found on the PATH or in the usual folders")
        }
        guard let path = value("herdr") else {
            let shown = output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
            return Answer(listing: .failed("The host didn't answer as expected."),
                          details: "no herdr marker in the output: \(shown.isEmpty ? "(empty)" : String(shown))")
        }
        let home = value("home")
        var notes = ["\(value("version") ?? "herdr (unknown version)") at \(path)", "home \(home ?? "unknown")"]

        var panes: [Pane] = []
        var running = 0
        var failure: String?
        var index = lines.startIndex
        while let start = lines[index...].firstIndex(where: { $0.hasPrefix("#fwd:session ") }) {
            let name = String(lines[start].dropFirst("#fwd:session ".count))
            let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("#fwd:exit") } ?? lines.endIndex
            let json = lines[(start + 1)..<end].joined(separator: "\n")
            let exit = end < lines.endIndex ? String(lines[end].dropFirst("#fwd:exit".count)).trimmingCharacters(in: .whitespaces) : "?"
            index = min(end + 1, lines.endIndex)

            guard let reply = try? JSONDecoder.snakeCase.decode(Reply.self, from: Data(json.utf8)) else {
                failure = failure ?? "herdr didn't give a snapshot (exit status \(exit))."
                notes.append("session \(name): no snapshot, exit \(exit): \(json.prefix(200))")
                continue
            }
            if let error = reply.error {
                if error.code == "server_not_running" {
                    notes.append("session \(name): not running")
                } else {
                    failure = failure ?? error.message ?? error.code ?? "herdr reported an error."
                    notes.append("session \(name): error \(error.code ?? "?"): \(error.message ?? "")")
                }
                continue
            }
            let mine = reply.result?.snapshot.panes ?? []
            running += 1
            panes += mine
            let folders = Set(mine.compactMap(\.folder)).sorted()
            notes.append("session \(name): \(mine.count) panes in \(folders.joined(separator: ", "))")
        }

        let listing: Listing
        if running > 0 {
            let dirs = directories(panes, home: home)
            listing = .directories(dirs)
            notes.append("\(dirs.count) directories listed")
            let skipped = panes.filter { $0.folder == nil }.count
            if skipped > 0 { notes.append("\(skipped) panes without a folder skipped") }
        } else if let failure {
            listing = .failed(failure)
        } else if notes.contains(where: { $0.hasPrefix("session ") }) {
            listing = .notRunning
        } else {
            listing = .failed("herdr didn't list any sessions.")
        }
        return Answer(listing: listing, details: notes.joined(separator: "; "))
    }

    /// One row per directory, however many panes are in it, showing the
    /// most pressing status among them.
    static func directories(_ panes: [Pane], home: String?) -> [Directory] {
        var status: [String: Status] = [:]
        for pane in panes {
            guard let path = pane.folder else { continue }
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

        /// Where the pane's foreground program is, else the pane's own folder.
        var folder: String? {
            guard let path = foregroundCwd ?? cwd, path.hasPrefix("/") else { return nil }
            return path
        }
    }
}

extension JSONDecoder {
    static var snakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
