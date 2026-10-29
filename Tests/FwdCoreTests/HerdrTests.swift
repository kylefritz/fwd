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

    func output(_ json: String, home: String = "/home/me", exit: Int = 0) -> String {
        "Welcome to devbox!\n#fwd:home \(home)\n#fwd:herdr /usr/bin/herdr\n#fwd:version herdr 0.9.5\n"
            + block("default", json, exit: exit)
    }

    func block(_ session: String, _ json: String, exit: Int = 0) -> String {
        "#fwd:session \(session)\n\(json)\n#fwd:exit \(exit)\n"
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
        let text = output(snapshot([
            P(id: "w1:p1", cwd: "/home/me/av", agent: "claude", status: "idle", title: "review apps"),
            P(id: "w2:p1", cwd: "/home/me/av", agent: "claude", status: "idle", title: "Dash costs", workspace: "w2"),
        ]))
            + "#fwd:process default w1:p1\n"
            + #"{"result":{"process_info":{"foreground_processes":[{"pid":10,"name":"zsh","argv0":"-zsh"},{"pid":42,"name":"2.1.311","argv0":"claude"}]}}}"#
            + "\n#fwd:end\n"
            + "#fwd:process default w2:p1\n"
            + #"{"result":{"process_info":{"foreground_processes":[{"pid":43,"name":"claude","argv0":"/usr/local/bin/claude"}]}}}"#
            + "\n#fwd:end\n"
            + "#fwd:claude\n" + #"{"pid":42,"sessionId":"abc","cwd":"/home/me/av","name":"Delve previews"}"#
            + "\n#fwd:lastcwd /home/me/av-delve-previews\n#fwd:end\n"
            + "#fwd:claude\n" + #"{"pid":43,"sessionId":"def","cwd":"/home/me/av"}"# + "\n#fwd:end\n"
        let answer = Herdr.read(text)
        let result = try #require(found(answer.listing))
        #expect(result.agents.map(\.path) == ["/home/me/av-delve-previews", "/home/me/av"])
        #expect(result.agents.map(\.folderName) == ["av-delve-previews", "av"])
        #expect(answer.details.contains("agent review apps [default w1:p1, claude pid 42] in /home/me/av-delve-previews (pane in /home/me/av)"),
                "\(answer.details)")
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
        let text = output(snapshot([P(cwd: "/home/me/av", agent: "claude", status: "idle", title: "x"),
                                    P(id: "w2:p1", cwd: "/home/me/notes"), P(id: "w3:p1", cwd: "/home/me")]))
            + "#fwd:worktrees /home/me/av\n\(worktrees)\n#fwd:end\n"
            + "#fwd:worktrees /home/me/notes\n\(notRepo)\n#fwd:end\n"
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
        let text = output(snapshot([P(cwd: "/home/me/code/fwd", agent: "claude", status: "working", title: "a")]))
            + block("work", snapshot([P(cwd: "/home/me/code/corridor", agent: "claude", status: "idle", title: "b")]))
            + block("old", notRunning, exit: 1)
        let answer = Herdr.read(text)
        let result = try #require(found(answer.listing))
        #expect(result.agents.map(\.title) == ["a", "b"])
        #expect(result.agents.map(\.id) == ["default w1:p1", "work w1:p1"], "the same pane ID in two sessions stays two agents")
        #expect(answer.details.contains("herdr 0.9.5 at /usr/bin/herdr"), "\(answer.details)")
        #expect(answer.details.contains("session work: 1 panes, 1 with an agent"), "\(answer.details)")
        #expect(answer.details.contains("session old: not running"), "\(answer.details)")
    }

    @Test func saysWhenHerdrIsMissingOrNotRunning() {
        #expect(Herdr.parse("#fwd:home /home/me\n#fwd:noherdr\n") == .notInstalled)
        #expect(Herdr.parse(output(notRunning, exit: 1)) == .notRunning)
        #expect(Herdr.parse(output(notRunning, exit: 1) + block("work", notRunning, exit: 1)) == .notRunning)
        let other = #"{"id":"x","error":{"code":"boom","message":"something broke"}}"#
        #expect(Herdr.parse(output(other, exit: 1)) == .failed("something broke"))
        #expect(Herdr.parse(output("Segmentation fault", exit: 139)) == .failed("herdr didn't give a snapshot (exit status 139)."))
        #expect(Herdr.parse("") == .failed("The host didn't answer as expected."))
        #expect(Herdr.parse(output(snapshot([]))) == .found(Herdr.Found(agents: [], folders: [])))
        #expect(Herdr.tilde("/home/meow", home: "/home/me") == "/home/meow")
    }

    /// The command fwd sends, under sh, with a stand-in herdr where a login
    /// PATH wouldn't find it, and a Claude Code session that moved into a
    /// worktree.
    @Test func theScriptRunsEveryStep() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-herdr-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "HOME=\(home.path)", "/bin/sh", "-c"]
        // The command exactly as fwd sends it.
        let script = Herdr.command

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
            "--session default pane process-info --pane w1:p1") echo '{"result":{"process_info":{"foreground_processes":[{"pid":4242,"name":"2.1.311","argv0":"claude"}]}}}' ;;
            "--session work pane process-info --pane w1:p1") echo '{"result":{"process_info":{"foreground_processes":[{"pid":7,"name":"zsh","argv0":"-zsh"}]}}}' ;;
            "worktree list --cwd \(h)/code/fwd") echo '{"result":{"worktrees":[{"branch":"main","is_linked_worktree":false,"path":"\(h)/code/fwd"},{"branch":"kf/x","is_linked_worktree":true,"path":"\(h)/code/fwd-x"}]}}' ;;
            "worktree list --cwd "*) echo '{"error":{"code":"not_git_worktree"}}' ;;
            *) exit 2 ;;
            esac
            """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let ran = await Shell.run(env[0], Array(env.dropFirst()) + [script])
        #expect(ran.ok)
        #expect(Herdr.parse(ran.stdout) == .found(Herdr.Found(
            agents: [Herdr.Agent(id: "default w1:p1", title: "fwd release", path: "\(h)/code/fwd-x",
                                 display: "~/code/fwd-x", status: .agent)],
            folders: [
                Herdr.Directory(path: "\(h)/code/corridor", display: "~/code/corridor"),
                Herdr.Directory(path: "\(h)/code/fwd", display: "~/code/fwd", branch: "main"),
                Herdr.Directory(path: "\(h)/code/fwd-x", display: "~/code/fwd-x", worktreeOf: "\(h)/code/fwd", branch: "kf/x"),
            ])), "\(ran.stdout)")
    }

    @Test func scriptMatchesTheFileInScripts() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/herdr.sh")
        #expect(try String(contentsOf: file, encoding: .utf8) == Herdr.script)
    }

    /// Base64 and a pipe: nothing any login shell, csh included, reads specially.
    @Test func theCommandSurvivesAnyLoginShell() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/= |-")
        #expect(Herdr.command.allSatisfy(allowed.contains))
        #expect(Herdr.command.hasSuffix(" | base64 -d | sh"))
    }

    @Test func isOnUnlessTurnedOff() throws {
        #expect(Preferences().herdr)
        #expect(try YAMLDecoder().decode(Preferences.self, from: "check_for_updates: true\n").herdr)
        #expect(try !YAMLDecoder().decode(Preferences.self, from: "herdr: false\n").herdr)
    }
}
