import Foundation

/// Reads what a host's herdr has open, for the VS Code button's menu: the
/// agents, as herdr's own sidebar lists them, and the folders and worktrees
/// they're in. Read-only: it asks herdr and Claude Code's files and changes
/// nothing.
public enum Herdr {
    /// What an agent's dot shows.
    public enum Status: Int, Comparable, Sendable {
        /// Waiting on you (herdr's `blocked`).
        case blocked
        /// Running, whatever it's doing.
        case agent

        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    /// One agent in a herdr pane.
    public struct Agent: Equatable, Identifiable, Sendable {
        public let id: String
        /// The pane's title, which Claude Code sets to the session's name.
        public let title: String
        /// Where it's working: for Claude Code, the folder its transcript was
        /// last in, since moving into a worktree doesn't move the pane.
        public let path: String
        public let display: String
        public let status: Status

        public var folderName: String { Herdr.name(display) }
    }

    /// A folder to open: a repo's checkout or worktree, or a folder a pane is in.
    public struct Directory: Equatable, Identifiable, Sendable {
        /// Absolute, on the remote.
        public let path: String
        /// The path with the remote's home shown as `~`.
        public let display: String
        /// Set for a linked worktree: its repo's main checkout.
        public var worktreeOf: String? = nil
        public var branch: String? = nil
        public var id: String { path }

        public var name: String { Herdr.name(display) }
    }

    public struct Found: Equatable, Sendable {
        public var agents: [Agent]
        public var folders: [Directory]
    }

    public enum Listing: Equatable, Sendable {
        case found(Found)
        case notInstalled
        case notRunning
        case failed(String)
    }

    /// One line with no single quotes, so it can be wrapped in `sh -c '...'`
    /// like the port scan. A non-interactive ssh command often lacks the
    /// login PATH, so the usual install folders are tried too. Each step's
    /// output follows a `#fwd:` marker:
    /// - every named herdr session's snapshot (each has its own server);
    /// - each pane's processes, to find the Claude Code in it;
    /// - Claude Code's session files, each with the last folder its
    ///   transcript recorded;
    /// - the git worktrees of each folder a pane is in.
    /// herdr's exit status is printed rather than returned, so a herdr error
    /// arrives as output instead of an ssh failure.
    public static let script = #"""
    echo "#fwd:home $HOME"; h=$(command -v herdr 2>/dev/null); for p in "$HOME/.local/bin/herdr" "$HOME/.cargo/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr; do [ -n "$h" ] && break; [ -x "$p" ] && h="$p"; done; if [ -z "$h" ]; then echo "#fwd:noherdr"; else echo "#fwd:herdr $h"; echo "#fwd:version $("$h" --version 2>/dev/null | head -n 1)"; n=$("$h" session list --json 2>/dev/null | tr "," "\n" | grep "\"name\":" | sed "s/.*\"name\":\"//; s/\".*//"); [ -z "$n" ] && n=default; f=""; for x in $n; do echo "#fwd:session $x"; o=$("$h" --session "$x" api snapshot); e=$?; printf "%s\n" "$o"; echo "#fwd:exit $e"; f=$(printf "%s\n%s" "$f" "$(printf "%s" "$o" | grep -o "\"foreground_cwd\":\"[^\"]*\"" | sed "s/^\"foreground_cwd\":\"//; s/\"$//")"); for i in $(printf "%s" "$o" | grep -o "\"pane_id\":\"[^\"]*\"" | sed "s/^\"pane_id\":\"//; s/\"$//" | sort -u); do echo "#fwd:process $x $i"; "$h" --session "$x" pane process-info --pane "$i" 2>&1; echo; echo "#fwd:end"; done; done; for c in "$HOME"/.claude/sessions/*.json; do [ -f "$c" ] || continue; echo "#fwd:claude"; cat "$c"; echo; d=$(grep -o "\"sessionId\": *\"[^\"]*\"" "$c" | sed "s/.*: *\"//; s/\"$//"); t=$(ls "$HOME"/.claude/projects/*/"$d".jsonl 2>/dev/null | head -n 1); [ -n "$d" ] && [ -n "$t" ] && tail -n 200 "$t" | grep -o "\"cwd\": *\"[^\"]*\"" | tail -n 1 | sed "s/.*: *\"/#fwd:lastcwd /; s/\"$//"; echo "#fwd:end"; done; printf "%s\n" "$f" | sort -u | while IFS= read -r d; do [ -n "$d" ] || continue; echo "#fwd:worktrees $d"; "$h" worktree list --cwd "$d" 2>&1; echo; echo "#fwd:end"; done; fi
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
        /// Each `#fwd:<marker>` block: its header's words and the lines up to
        /// the closing marker.
        func blocks(_ marker: String, until close: (String) -> Bool) -> [(header: String, body: [String], close: String?)] {
            var out: [(String, [String], String?)] = []
            var index = lines.startIndex
            while let start = lines[index...].firstIndex(where: { $0 == "#fwd:\(marker)" || $0.hasPrefix("#fwd:\(marker) ") }) {
                let end = lines[(start + 1)...].firstIndex(where: close) ?? lines.endIndex
                let header = String(lines[start].dropFirst("#fwd:\(marker)".count)).trimmingCharacters(in: .whitespaces)
                out.append((header, Array(lines[(start + 1)..<end]), end < lines.endIndex ? lines[end] : nil))
                index = min(end + 1, lines.endIndex)
            }
            return out
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

        // Snapshots, one per running session.
        var panes: [(session: String, pane: Pane)] = []
        var labels: [String: String] = [:]
        var running = 0
        var failure: String?
        for block in blocks("session", until: { $0.hasPrefix("#fwd:exit") }) {
            let name = block.header
            let json = block.body.joined(separator: "\n")
            let exit = block.close.map { String($0.dropFirst("#fwd:exit".count)).trimmingCharacters(in: .whitespaces) } ?? "?"
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
            let snapshot = reply.result?.snapshot
            let mine = snapshot?.panes ?? []
            running += 1
            panes += mine.map { (name, $0) }
            for ws in snapshot?.workspaces ?? [] { labels["\(name) \(ws.workspaceId)"] = ws.label }
            notes.append("session \(name): \(mine.count) panes, \(mine.filter { $0.agent != nil }.count) with an agent")
        }

        // Which Claude Code process is in each pane.
        var claudePID: [String: Int] = [:]
        for block in blocks("process", until: { $0 == "#fwd:end" }) {
            let info = try? JSONDecoder.snakeCase.decode(ProcessReply.self, from: Data(block.body.joined(separator: "\n").utf8))
            let processes = info?.result?.processInfo.foregroundProcesses ?? []
            // On macOS the process name is Claude Code's version, so go by argv0.
            if let claude = processes.first(where: { ($0.argv0.map { ($0 as NSString).lastPathComponent } ?? $0.name) == "claude" }) {
                claudePID[block.header] = claude.pid
            } else if info == nil {
                notes.append("pane \(block.header): no process info: \(block.body.joined().prefix(120))")
            }
        }

        // Claude Code's sessions, by process, with where each last worked.
        var claude: [Int: (name: String?, cwd: String?)] = [:]
        for block in blocks("claude", until: { $0 == "#fwd:end" }) {
            let json = block.body.filter { !$0.hasPrefix("#fwd:") }.joined(separator: "\n")
            guard let session = try? JSONDecoder().decode(ClaudeSession.self, from: Data(json.utf8)) else { continue }
            let last = block.body.first { $0.hasPrefix("#fwd:lastcwd ") }.map { String($0.dropFirst("#fwd:lastcwd ".count)) }
            claude[session.pid] = (session.name, last ?? session.cwd)
        }

        // The worktrees of each folder a pane is in.
        var repos: [String: [Worktree]] = [:]
        for block in blocks("worktrees", until: { $0 == "#fwd:end" }) {
            let folder = block.header
            let json = block.body.joined(separator: "\n")
            guard let reply = try? JSONDecoder.snakeCase.decode(WorktreeReply.self, from: Data(json.utf8)) else {
                notes.append("worktrees of \(folder): no answer: \(json.prefix(200))")
                continue
            }
            if let error = reply.error {
                notes.append("worktrees of \(folder): \(error.code ?? "error") \(error.message ?? "")")
                continue
            }
            let list = (reply.result?.worktrees ?? []).filter { $0.isBare != true && $0.path.hasPrefix("/") }
            guard let main = list.first(where: { $0.isLinkedWorktree != true })?.path ?? list.first?.path else { continue }
            repos[main] = list
            notes.append("worktrees of \(folder): \(list.count - 1) linked")
        }

        guard running > 0 else {
            let listing: Listing
            if let failure {
                listing = .failed(failure)
            } else if notes.contains(where: { $0.hasPrefix("session ") }) {
                listing = .notRunning
            } else {
                listing = .failed("herdr didn't list any sessions.")
            }
            return Answer(listing: listing, details: notes.joined(separator: "; "))
        }

        var agents: [Agent] = []
        for (session, pane) in panes {
            guard pane.agent != nil, let paneFolder = pane.folder else { continue }
            let key = "\(session) \(pane.paneId ?? "")"
            let found = claudePID[key].flatMap { claude[$0] }
            let folder = found?.cwd.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? paneFolder
            let title = [pane.terminalTitleStripped, found?.name, labels["\(session) \(pane.workspaceId ?? "")"], pane.agent]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "agent"
            agents.append(Agent(id: key, title: title, path: folder, display: tilde(folder, home: home),
                                status: pane.agentStatus == "blocked" ? .blocked : .agent))
            notes.append("agent \(title) [\(key)\(claudePID[key].map { ", claude pid \($0)" } ?? "")] in \(folder)"
                + (folder == paneFolder ? "" : " (pane in \(paneFolder))"))
        }

        let folders = folders(paneFolders: Set(panes.compactMap(\.pane.folder)), repos: repos, home: home)
        notes.append("\(agents.count) agents, \(folders.count) folders listed")
        return Answer(listing: .found(Found(agents: agents, folders: folders)), details: notes.joined(separator: "; "))
    }

    /// Each repo's main checkout followed by its worktrees, and every other
    /// folder a pane is in, by name.
    static func folders(paneFolders: Set<String>, repos: [String: [Worktree]], home: String?) -> [Directory] {
        var groups: [[Directory]] = []
        var covered = Set<String>()
        for (main, list) in repos {
            guard !covered.contains(main) else { continue }
            let linked = list.filter { $0.path != main && !covered.contains($0.path) }
                .map { Directory(path: $0.path, display: tilde($0.path, home: home), worktreeOf: main, branch: $0.branch) }
                .sorted { ($0.name.lowercased(), $0.display) < ($1.name.lowercased(), $1.display) }
            let branch = list.first { $0.path == main }?.branch
            groups.append([Directory(path: main, display: tilde(main, home: home), branch: branch)] + linked)
            covered.insert(main)
            for dir in linked { covered.insert(dir.path) }
        }
        for folder in paneFolders where !covered.contains(folder) {
            groups.append([Directory(path: folder, display: tilde(folder, home: home))])
        }
        return groups.sorted { ($0[0].name.lowercased(), $0[0].display) < ($1[0].name.lowercased(), $1[0].display) }
            .flatMap { $0 }
    }

    static func name(_ display: String) -> String {
        display == "~" || display == "/" ? display : (display as NSString).lastPathComponent
    }

    static func tilde(_ path: String, home: String?) -> String {
        guard let home, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    struct Reply: Decodable {
        struct Result: Decodable { let snapshot: Snapshot }
        struct Snapshot: Decodable {
            let panes: [Pane]
            let workspaces: [Workspace]?
        }
        struct Workspace: Decodable {
            let workspaceId: String
            let label: String?
        }
        struct Failure: Decodable { let code: String?; let message: String? }
        let result: Result?
        let error: Failure?
    }

    struct ProcessReply: Decodable {
        struct Result: Decodable { let processInfo: Info }
        struct Info: Decodable { let foregroundProcesses: [Process] }
        struct Process: Decodable {
            let pid: Int
            let name: String?
            let argv0: String?
        }
        let result: Result?
    }

    /// `~/.claude/sessions/<pid>.json`, written by each running Claude Code.
    struct ClaudeSession: Decodable {
        let pid: Int
        let name: String?
        let cwd: String?
    }

    struct WorktreeReply: Decodable {
        struct Result: Decodable { let worktrees: [Worktree] }
        let result: Result?
        let error: Reply.Failure?
    }

    struct Worktree: Decodable {
        let path: String
        let branch: String?
        let isLinkedWorktree: Bool?
        let isBare: Bool?
    }

    struct Pane: Decodable {
        let paneId: String?
        let workspaceId: String?
        let cwd: String?
        let foregroundCwd: String?
        let agent: String?
        let agentStatus: String?
        let terminalTitleStripped: String?

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
