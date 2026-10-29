import Foundation
import Testing
@testable import FwdCore
import Yams

@Suite struct HerdrTests {
    struct P {
        var id = "w1:p1"
        var cwd: String
        var agent: String? = nil
        var status: String? = nil
        var title: String? = nil
        var workspace = "w1"
    }

    /// A snapshot as herdr 0.9 prints it, trimmed to the fields fwd reads.
    func snapshot(_ panes: [P], workspaces: [(String, String)] = []) -> String {
        func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
        let items = panes.map {
            #"{"pane_id":"\#($0.id)","workspace_id":"\#($0.workspace)","cwd":"\#($0.cwd)","foreground_cwd":"\#($0.cwd)","#
                + #""agent":\#(q($0.agent)),"agent_status":\#(q($0.status)),"terminal_title_stripped":\#(q($0.title))}"#
        }
        let ws = workspaces.map { #"{"workspace_id":"\#($0.0)","label":"\#($0.1)"}"# }
        return #"{"id":"cli:api:snapshot","result":{"type":"snapshot","snapshot":{"panes":["#
            + items.joined(separator: ",") + #"],"workspaces":["# + ws.joined(separator: ",") + "]}}}"
    }

    struct S {
        var name = "default"
        var exit = 0
        var snapshot: String
        var panes: [(pane: String, info: String)] = []
    }

    /// What scripts/herdr.sh prints, after a login banner: one JSON value
    /// per line. A snapshot that isn't JSON is reported as a failure, as the
    /// script does.
    func report(_ sessions: [S], claude: [(session: String, lastCwd: String)] = [],
                worktrees: [(folder: String, list: String)] = [], home: String = "/home/me") -> String {
        var lines = ["Welcome to devbox!", #"{"home":"\#(home)"}"#, #"{"herdr":"/usr/bin/herdr","version":"herdr 0.9.5"}"#]
        for session in sessions {
            lines.append(#"{"session":"\#(session.name)"}"#)
            lines.append(session.snapshot.hasPrefix("{") ? session.snapshot
                : #"{"failed":"herdr --session \#(session.name) api snapshot","exit":\#(session.exit),"output":"\#(session.snapshot)"}"#)
            lines += session.panes.map(\.info)
        }
        for entry in claude {
            lines.append(entry.session)
            let id = entry.session.range(of: #""sessionId":""#).map { String(entry.session[$0.upperBound...].prefix { $0 != "\"" }) }
            if let id, !entry.lastCwd.isEmpty { lines.append(#"{"sessionId":"\#(id)","lastCwd":"\#(entry.lastCwd)"}"#) }
        }
        for entry in worktrees {
            lines.append(#"{"worktreesOf":"\#(entry.folder)"}"#)
            lines.append(entry.list)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func output(_ json: String, home: String = "/home/me", exit: Int = 0) -> String {
        report([S(exit: exit, snapshot: json)], home: home)
    }

    func found(_ listing: Herdr.Listing) -> Herdr.Found? {
        if case .found(let found) = listing { return found }
        Issue.record("expected a listing, got \(listing)")
        return nil
    }

    let notRunning = #"{"id":"cli:api:snapshot","error":{"code":"server_not_running","message":"no herdr server is running"}}"#

    /// Like herdr's sidebar: one row per agent, titled as the pane is,
    /// in herdr's order, even when several share a folder.
    @Test func listsEveryAgentByItsTitle() throws {
        let json = snapshot([
            P(id: "w1:p1", cwd: "/home/me/av", agent: "claude", status: "idle", title: "Dash costs"),
            P(id: "w2:p1", cwd: "/home/me/av", agent: "claude", status: "blocked", title: "review apps", workspace: "w2"),
            P(id: "w3:p1", cwd: "/home/me/av", agent: "codex", status: "working", title: "", workspace: "w3"),
            P(id: "w4:p1", cwd: "/home/me/av"),
        ], workspaces: [("w3", "sort_")])
        let result = try #require(found(Herdr.parse(output(json))))
        #expect(result.agents.map(\.title) == ["Dash costs", "review apps", "sort_"])
        #expect(result.agents.map(\.status) == [.agent, .blocked, .agent])
        #expect(result.agents.map(\.display) == ["~/av", "~/av", "~/av"])
        #expect(result.folders.map(\.display) == ["~/av"])
    }

    /// An agent that moved into a worktree is listed there: its pane stays
    /// put, but Claude Code's transcript records where it went.
    @Test func placesClaudeWhereItsTranscriptLastWorked() throws {
        let snap = snapshot([
            P(id: "w1:p1", cwd: "/home/me/av", agent: "claude", status: "idle", title: "review apps"),
            P(id: "w2:p1", cwd: "/home/me/av", agent: "claude", status: "idle", title: "Dash costs", workspace: "w2"),
        ])
        let text = report([S(snapshot: snap, panes: [
            ("w1:p1", #"{"id":"cli:pane:process_info","result":{"process_info":{"pane_id":"w1:p1","foreground_processes":[{"pid":10,"name":"zsh","argv0":"-zsh"},{"pid":42,"name":"2.1.311","argv0":"claude"}]}}}"#),
            ("w2:p1", #"{"id":"cli:pane:process_info","result":{"process_info":{"pane_id":"w2:p1","foreground_processes":[{"pid":43,"name":"claude","argv0":"/usr/local/bin/claude"}]}}}"#),
        ])], claude: [
            (#"{"pid":42,"sessionId":"abc","cwd":"/home/me/av","name":"Delve previews"}"#, "/home/me/av-delve-previews"),
            (#"{"pid":43,"sessionId":"def","cwd":"/home/me/av"}"#, ""),
        ])
        let answer = Herdr.read(text)
        let result = try #require(found(answer.listing))
        #expect(result.agents.map(\.path) == ["/home/me/av-delve-previews", "/home/me/av"])
        #expect(result.agents.map(\.folderName) == ["av-delve-previews", "av"])
        #expect(answer.details.contains("agent review apps [default w1:p1, claude pid 42] in /home/me/av-delve-previews (pane in /home/me/av)"),
                "\(answer.details)")
    }

    /// A transcript can end in a subfolder after a cd; the agent opens the
    /// checkout or worktree holding it.
    @Test func snapsAnAgentToTheCheckoutHoldingItsFolder() throws {
        let snap = snapshot([
            P(id: "w1:p1", cwd: "/home/me/mp", agent: "claude", status: "idle", title: "viewer"),
            P(id: "w2:p1", cwd: "/home/me/mp", agent: "claude", status: "idle", title: "coffin", workspace: "w2"),
        ])
        let claudeIn = { (pane: String, pid: Int) in
            #"{"id":"cli:pane:process_info","result":{"process_info":{"pane_id":"\#(pane)","foreground_processes":[{"pid":\#(pid),"argv0":"claude"}]}}}"#
        }
        let list = #"{"id":"cli:worktree:list","result":{"worktrees":[{"branch":"main","is_linked_worktree":false,"path":"/home/me/mp"},"#
            + #"{"branch":"coffin","is_linked_worktree":true,"path":"/home/me/mp/.claude/worktrees/coffin"}]}}"#
        let text = report([S(snapshot: snap, panes: [("w1:p1", claudeIn("w1:p1", 1)), ("w2:p1", claudeIn("w2:p1", 2))])],
                          claude: [(#"{"pid":1,"sessionId":"a"}"#, "/home/me/mp/viewer/dist"),
                                   (#"{"pid":2,"sessionId":"b"}"#, "/home/me/mp/.claude/worktrees/coffin/projects/tot")],
                          worktrees: [("/home/me/mp", list)])
        let answer = Herdr.read(text)
        let result = try #require(found(answer.listing))
        #expect(result.agents.map(\.path) == ["/home/me/mp", "/home/me/mp/.claude/worktrees/coffin"])
        #expect(answer.details.contains("(worked in /home/me/mp/viewer/dist)"), "\(answer.details)")
    }

    /// vdesk: every pane sits in ~/av while the work is in its worktrees,
    /// which are folders beside it. Those come from `herdr worktree list`.
    @Test func listsEachRepoWithItsWorktreesUnderIt() throws {
        let worktrees = #"""
            {"id":"cli:worktree:list","result":{"worktrees":[\#
            {"branch":"common/master/latest","is_bare":false,"is_linked_worktree":false,"path":"/home/me/av"},\#
            {"branch":"kf/trt-stable-sort","is_bare":false,"is_linked_worktree":true,"path":"/home/me/av-trt-stable-sort"},\#
            {"branch":"kf/delve-preview-ci","is_bare":false,"is_linked_worktree":true,"path":"/home/me/av-delve-previews"}]}}
            """#
        let notRepo = #"{"error":{"code":"not_git_worktree","message":"Herdr worktree actions require a path inside a Git work tree"},"id":"cli:worktree:list"}"#
        let snap = snapshot([P(cwd: "/home/me/av", agent: "claude", status: "idle", title: "x"),
                             P(id: "w2:p1", cwd: "/home/me/notes"), P(id: "w3:p1", cwd: "/home/me")])
        let text = report([S(snapshot: snap)], worktrees: [("/home/me/av", worktrees), ("/home/me/notes", notRepo)])
        let answer = Herdr.read(text)
        let result = try #require(found(answer.listing))
        #expect(result.folders.map(\.display) == ["~/av", "~/av-delve-previews", "~/av-trt-stable-sort", "~/notes", "~"])
        #expect(result.folders.map(\.worktreeOf) == [nil, "/home/me/av", "/home/me/av", nil, nil])
        #expect(result.folders.map(\.branch) == ["common/master/latest", "kf/delve-preview-ci", "kf/trt-stable-sort", nil, nil])
        #expect(result.folders.map(\.name) == ["av", "av-delve-previews", "av-trt-stable-sort", "notes", "~"])
        #expect(answer.details.contains("worktrees of /home/me/av: 2 linked"), "\(answer.details)")
        #expect(answer.details.contains("worktrees of /home/me/notes: not_git_worktree"), "\(answer.details)")
    }

    /// herdr runs one server per named session; every running one is read.
    @Test func readsEveryRunningSession() throws {
        let text = report([
            S(snapshot: snapshot([P(cwd: "/home/me/code/fwd", agent: "claude", status: "working", title: "a")])),
            S(name: "work", snapshot: snapshot([P(cwd: "/home/me/code/corridor", agent: "claude", status: "idle", title: "b")])),
            S(name: "old", exit: 1, snapshot: notRunning),
        ])
        let answer = Herdr.read(text)
        let result = try #require(found(answer.listing))
        #expect(result.agents.map(\.title) == ["a", "b"])
        #expect(result.agents.map(\.id) == ["default w1:p1", "work w1:p1"], "the same pane ID in two sessions stays two agents")
        #expect(answer.details.contains("herdr 0.9.5 at /usr/bin/herdr"), "\(answer.details)")
        #expect(answer.details.contains("session work: 1 panes, 1 with an agent"), "\(answer.details)")
        #expect(answer.details.contains("session old: not running"), "\(answer.details)")
    }

    @Test func saysWhenHerdrIsMissingOrNotRunning() {
        #expect(Herdr.parse("{\"home\":\"/home/me\"}\n{\"noherdr\":true}\n") == .notInstalled)
        #expect(Herdr.parse(output(notRunning, exit: 1)) == .notRunning)
        #expect(Herdr.parse(report([S(exit: 1, snapshot: notRunning), S(name: "work", exit: 1, snapshot: notRunning)])) == .notRunning)
        let other = #"{"id":"cli:api:snapshot","error":{"code":"boom","message":"something broke"}}"#
        #expect(Herdr.parse(output(other, exit: 1)) == .failed("something broke"))
        #expect(Herdr.parse(output("Segmentation fault", exit: 139)) == .failed("herdr didn't give a snapshot."))
        #expect(Herdr.parse("") == .failed("The host didn't answer as expected."))
        #expect(Herdr.parse(output(snapshot([]))) == .found(Herdr.Found(agents: [], folders: [])))
        #expect(Herdr.tilde("/home/meow", home: "/home/me") == "/home/meow")
    }

    /// The command fwd sends, under sh, with a stand-in herdr where a login
    /// PATH wouldn't find it, a Claude Code session that moved into a
    /// worktree, and a herdr call that crashes.
    @Test func theScriptRunsEveryStep() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-herdr-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "HOME=\(home.path)", "/bin/sh", "-c"]
        // The command exactly as fwd sends it.
        let script = Herdr.command(script: try Herdr.loadScript())

        // Unless this machine has its own herdr in one of the system folders.
        if !["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"].contains(where: FileManager.default.isExecutableFile) {
            let missing = await Shell.run(env[0], Array(env.dropFirst()) + [script])
            #expect(missing.ok)
            #expect(Herdr.parse(missing.stdout) == .notInstalled)
        }

        let h = home.path
        let bin = home.appendingPathComponent(".local/bin")
        let sessions = home.appendingPathComponent(".claude/sessions")
        let projects = home.appendingPathComponent(".claude/projects/-code-fwd")
        for dir in [bin, sessions, projects] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try #"{"pid":4242,"sessionId":"abc","cwd":"\#(h)/code/fwd","name":"fwd release"}"#
            .write(to: sessions.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)
        try "{\"type\":\"user\",\"cwd\":\"\(h)/code/fwd\"}\n{\"type\":\"assistant\",\"cwd\":\"\(h)/code/fwd-x\"}\n"
            .write(to: projects.appendingPathComponent("abc.jsonl"), atomically: true, encoding: .utf8)

        let fake = bin.appendingPathComponent("herdr")
        let main = snapshot([P(cwd: "\(h)/code/fwd", agent: "claude", status: "working", title: "fwd release")])
        let work = snapshot([P(cwd: "\(h)/code/corridor")])
        // Two sessions, as `herdr session list --json` prints them.
        try """
            #!/bin/sh
            case "$*" in
            "--version") echo "herdr 0.9.5" ;;
            "session list --json") echo '{"sessions":[{"default":true,"name":"default","running":true},{"default":false,"name":"work","running":true}]}' ;;
            "--session default api snapshot") echo '\(main)' ;;
            "--session work api snapshot") echo '\(work)' ;;
            "--session default pane process-info --pane w1:p1") echo '{"id":"cli:pane:process_info","result":{"process_info":{"pane_id":"w1:p1","foreground_processes":[{"pid":4242,"name":"2.1.311","argv0":"claude"}]}}}' ;;
            "--session work pane process-info --pane w1:p1") echo "thread 'main' panicked" >&2; exit 101 ;;
            "worktree list --cwd \(h)/code/fwd") echo '{"id":"cli:worktree:list","result":{"worktrees":[{"branch":"main","is_linked_worktree":false,"path":"\(h)/code/fwd"},{"branch":"kf/x","is_linked_worktree":true,"path":"\(h)/code/fwd-x"}]}}' ;;
            "worktree list --cwd "*) echo '{"id":"cli:worktree:list","error":{"code":"not_git_worktree"}}' >&2; exit 1 ;;
            *) exit 2 ;;
            esac
            """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let ran = await Shell.run(env[0], Array(env.dropFirst()) + [script])
        #expect(ran.ok)
        for line in ran.stdout.split(separator: "\n") {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil, "every line is JSON: \(line)")
        }
        // A crash is reported as JSON and logged; the rest still reads.
        #expect(Herdr.read(ran.stdout).details.contains(
            "herdr --session work pane process-info --pane w1:p1 failed, exit 101: thread 'main' panicked"), "\(ran.stdout)")
        #expect(Herdr.parse(ran.stdout) == .found(Herdr.Found(
            agents: [Herdr.Agent(id: "default w1:p1", title: "fwd release", path: "\(h)/code/fwd-x",
                                 display: "~/code/fwd-x", status: .agent)],
            folders: [
                Herdr.Directory(path: "\(h)/code/corridor", display: "~/code/corridor"),
                Herdr.Directory(path: "\(h)/code/fwd", display: "~/code/fwd", branch: "main"),
                Herdr.Directory(path: "\(h)/code/fwd-x", display: "~/code/fwd-x", worktreeOf: "\(h)/code/fwd", branch: "kf/x"),
            ])), "\(ran.stdout)")
    }

    /// Base64 and a pipe: nothing any login shell, csh included, reads specially.
    @Test func theCommandSurvivesAnyLoginShell() throws {
        let command = Herdr.command(script: try Herdr.loadScript())
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/= |-")
        #expect(command.allSatisfy(allowed.contains))
        #expect(command.hasSuffix(" | base64 -d | sh"))
    }

    @Test func isOnUnlessTurnedOff() throws {
        #expect(Preferences().herdr)
        #expect(try YAMLDecoder().decode(Preferences.self, from: "check_for_updates: true\n").herdr)
        #expect(try !YAMLDecoder().decode(Preferences.self, from: "herdr: false\n").herdr)
    }
}
