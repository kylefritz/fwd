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

    /// The check run on the remote: `scripts/herdr.sh`, which explains each
    /// step. The app carries it in Contents/Resources (scripts/bundle.sh puts
    /// it there); a build run from the source tree, and the tests, read it
    /// from scripts/.
    public static func loadScript() throws -> String {
        let url = Bundle.main.url(forResource: "herdr", withExtension: "sh")
            ?? URL(fileURLWithPath: #filePath).appendingPathComponent("../../../scripts/herdr.sh").standardized
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Sends `script` as base64 piped into `sh`. The script has quotes and
    /// newlines that some login shells (csh) can't take inside `sh -c '...'`,
    /// while base64 has nothing any shell reads specially.
    public static func command(script: String) -> String {
        "echo \(Data(script.utf8).base64EncodedString()) | base64 -d | sh"
    }

    /// What the menu shows, and a line for the log saying how it got there.
    public struct Answer: Equatable, Sendable {
        public let listing: Listing
        public let details: String
    }

    public static func parse(_ output: String) -> Listing { read(output).listing }

    /// Decodes the script's JSON Lines in order. Lines that aren't JSON (a
    /// login banner, rc chatter) are skipped. Sessions that aren't running
    /// are left out; the listing is "not running" only when none is.
    public static func read(_ output: String) -> Answer {
        var lines: [Line] = []
        var undecoded: [Substring] = []
        for text in output.split(whereSeparator: \.isNewline) {
            if let line = try? JSONDecoder.snakeCase.decode(Line.self, from: Data(text.utf8)) {
                lines.append(line)
            } else if text.hasPrefix("{") {
                undecoded.append(text)
            }
        }
        guard lines.contains(where: { $0.home != nil }) else {
            let shown = output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            return Answer(listing: .failed("The host didn't answer as expected."),
                          details: "no JSON lines in the output: \(shown.isEmpty ? "(empty)" : String(shown))")
        }
        if lines.contains(where: { $0.noherdr == true }) {
            return Answer(listing: .notInstalled, details: "herdr not found on the PATH or in the usual folders")
        }
        let home = lines.lazy.compactMap(\.home).first
        let herdr = lines.first { $0.herdr != nil }
        var notes = ["\(herdr?.version ?? "herdr (unknown version)") at \(herdr?.herdr ?? "?")", "home \(home ?? "unknown")"]
        for text in undecoded { notes.append("couldn't read: \(text.prefix(200))") }

        var panes: [(session: String, pane: Pane)] = []
        var labels: [String: String] = [:]
        var claudePID: [String: Int] = [:]
        var claude: [Int: (name: String?, sessionId: String?, cwd: String?)] = [:]
        var lastCwd: [String: String] = [:]
        var repos: [String: [Worktree]] = [:]
        var sessionsSeen = 0
        var running = 0
        var failure: String?
        var session = "default"
        var folder = "?"

        for line in lines {
            if let name = line.session {
                session = name
                sessionsSeen += 1
            } else if let name = line.worktreesOf {
                folder = name
            } else if let failed = line.failed {
                // A herdr command that printed something other than JSON.
                notes.append("\(failed) failed, exit \(line.exit.map(String.init) ?? "?"): \(line.output?.prefix(200) ?? "")")
                if failed.contains(" api snapshot") { failure = failure ?? "herdr didn't give a snapshot." }
            } else if line.id == "cli:api:snapshot" {
                if let error = line.error {
                    if error.code == "server_not_running" {
                        notes.append("session \(session): not running")
                    } else {
                        failure = failure ?? error.message ?? error.code ?? "herdr reported an error."
                        notes.append("session \(session): error \(error.code ?? "?"): \(error.message ?? "")")
                    }
                } else if let snapshot = line.result?.snapshot {
                    running += 1
                    panes += snapshot.panes.map { (session, $0) }
                    for ws in snapshot.workspaces ?? [] { labels["\(session) \(ws.workspaceId)"] = ws.label }
                    notes.append("session \(session): \(snapshot.panes.count) panes, \(snapshot.panes.filter { $0.agent != nil }.count) with an agent")
                }
            } else if line.id == "cli:pane:process_info", let info = line.result?.processInfo {
                // On macOS the process name is Claude Code's version, so go by argv0.
                if let pane = info.paneId, let found = info.foregroundProcesses.first(where: {
                    ($0.argv0.map { ($0 as NSString).lastPathComponent } ?? $0.name) == "claude"
                }) {
                    claudePID["\(session) \(pane)"] = found.pid
                }
            } else if line.id == "cli:worktree:list" {
                if let error = line.error {
                    notes.append("worktrees of \(folder): \(error.code ?? "error") \(error.message ?? "")")
                } else {
                    let list = (line.result?.worktrees ?? []).filter { $0.isBare != true && $0.path.hasPrefix("/") }
                    if let main = list.first(where: { $0.isLinkedWorktree != true })?.path ?? list.first?.path {
                        repos[main] = list
                        notes.append("worktrees of \(folder): \(list.count - 1) linked")
                    }
                }
            } else if let pid = line.pid {
                // ~/.claude/sessions/<pid>.json
                claude[pid] = (line.name, line.sessionId, line.cwd)
            } else if let id = line.sessionId, let cwd = line.lastCwd {
                lastCwd[id] = cwd
            }
        }

        guard running > 0 else {
            let listing: Listing
            if let failure {
                listing = .failed(failure)
            } else if sessionsSeen > 0 {
                listing = .notRunning
            } else {
                listing = .failed("herdr didn't list any sessions.")
            }
            return Answer(listing: listing, details: notes.joined(separator: "; "))
        }

        let checkouts = Set(repos.values.flatMap { $0.map(\.path) })

        var agents: [Agent] = []
        for (session, pane) in panes {
            guard pane.agent != nil, let paneFolder = pane.folder else { continue }
            let key = "\(session) \(pane.paneId ?? "")"
            let found = claudePID[key].flatMap { claude[$0] }
            let cwd = found.flatMap { found in found.sessionId.flatMap { lastCwd[$0] } ?? found.cwd }
            let worked = cwd.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? paneFolder
            // A transcript can end in a subfolder (after a cd); open the
            // checkout or worktree that holds it.
            let folder = checkouts.filter { worked == $0 || worked.hasPrefix($0 + "/") }.max { $0.count < $1.count } ?? worked
            let title = [pane.terminalTitleStripped, found?.name, labels["\(session) \(pane.workspaceId ?? "")"], pane.agent]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "agent"
            agents.append(Agent(id: key, title: title, path: folder, display: tilde(folder, home: home),
                                status: pane.agentStatus == "blocked" ? .blocked : .agent))
            notes.append("agent \(title) [\(key)\(claudePID[key].map { ", claude pid \($0)" } ?? "")] in \(folder)"
                + (worked == folder ? "" : " (worked in \(worked))")
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

    /// One line of what scripts/herdr.sh prints: one of the script's own
    /// markers, a herdr reply, a Claude Code session file, or a failure.
    /// Every field is optional; which ones are set says which it is.
    struct Line: Decodable {
        // The script's own lines.
        let home: String?
        let noherdr: Bool?
        let herdr: String?
        let version: String?
        let session: String?
        let worktreesOf: String?
        let lastCwd: String?
        let failed: String?
        let exit: Int?
        let output: String?
        // herdr's replies.
        let id: String?
        let result: Result?
        let error: Reply.Failure?
        // ~/.claude/sessions/<pid>.json
        let pid: Int?
        let sessionId: String?
        let name: String?
        let cwd: String?

        struct Result: Decodable {
            let snapshot: Reply.Snapshot?
            let processInfo: ProcessInfo?
            let worktrees: [Worktree]?
        }
        struct ProcessInfo: Decodable {
            let paneId: String?
            let foregroundProcesses: [Process]
        }
        struct Process: Decodable {
            let pid: Int
            let name: String?
            let argv0: String?
        }
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
