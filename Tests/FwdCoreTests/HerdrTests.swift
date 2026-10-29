import Foundation
import Testing
@testable import FwdCore
import Yams

@Suite struct HerdrTests {
    /// A snapshot as herdr 0.9 prints it, trimmed to the fields fwd reads.
    func snapshot(_ panes: [(cwd: String, agent: String?, status: String?)]) -> String {
        let items = panes.map { pane in
            """
            {"cwd":"\(pane.cwd)","foreground_cwd":"\(pane.cwd)",\
            "agent":\(pane.agent.map { "\"\($0)\"" } ?? "null"),\
            "agent_status":\(pane.status.map { "\"\($0)\"" } ?? "null"),"pane_id":"w1:p1"}
            """
        }
        return #"{"id":"cli:api:snapshot","result":{"type":"snapshot","snapshot":{"panes":["#
            + items.joined(separator: ",") + "]}}}"
    }

    func output(_ json: String, home: String = "/home/me", exit: Int = 0) -> String {
        "Welcome to devbox!\n#fwd:home \(home)\n#fwd:herdr /usr/bin/herdr\n#fwd:version herdr 0.9.5\n"
            + block("default", json, exit: exit)
    }

    func block(_ session: String, _ json: String, exit: Int = 0) -> String {
        "#fwd:session \(session)\n\(json)\n\n#fwd:exit \(exit)\n"
    }

    let notRunning = #"{"id":"cli:api:snapshot","error":{"code":"server_not_running","message":"no herdr server is running"}}"#

    /// herdr runs one server per named session; a folder open in any
    /// running one is listed.
    @Test func listsTheDirectoriesOfEveryRunningSession() {
        let text = output(snapshot([("/home/me/code/fwd", "claude", "working")]))
            + block("work", snapshot([("/home/me/code/corridor", nil, nil), ("/home/me/wt/fwd-herdr", "claude", "idle")]))
            + block("old", notRunning, exit: 1)
        let answer = Herdr.read(text)
        guard case .directories(let dirs) = answer.listing else {
            Issue.record("expected directories: \(answer)"); return
        }
        #expect(dirs.map(\.display) == ["~/code/fwd", "~/wt/fwd-herdr", "~/code/corridor"])
        #expect(answer.details.contains("herdr 0.9.5 at /usr/bin/herdr"), "\(answer.details)")
        #expect(answer.details.contains("session work: 2 panes in /home/me/code/corridor, /home/me/wt/fwd-herdr"), "\(answer.details)")
        #expect(answer.details.contains("session old: not running"), "\(answer.details)")
        #expect(answer.details.contains("3 directories listed"), "\(answer.details)")
    }

    @Test func listsEachDirectoryOnceWithItsMostPressingStatus() {
        let json = snapshot([
            ("/home/me/code/fwd", "claude", "working"),
            ("/home/me/code/fwd", nil, nil),
            ("/home/me/code/finance", "claude", "idle"),
            ("/home/me/code/finance", "codex", "blocked"),
            ("/home/me/code", nil, nil),
            ("/srv/app", "pi", "done"),
        ])
        guard case .directories(let dirs) = Herdr.parse(output(json)) else {
            Issue.record("expected directories"); return
        }
        #expect(dirs.map(\.display) == ["~/code/finance", "/srv/app", "~/code/fwd", "~/code"])
        #expect(dirs.map(\.status) == [.blocked, .agent, .agent, .none])
        #expect(dirs.map(\.name) == ["finance", "app", "fwd", "code"])
        #expect(dirs[2].path == "/home/me/code/fwd")
    }

    /// vdesk: every pane sits in ~/av while the agents work in its worktrees,
    /// which are folders beside it. Those come from `herdr worktree list`.
    @Test func listsTheWorktreesOfEachFolderUnderIt() {
        let home = "/home/kfritz"
        let worktrees = #"""
            {"id":"cli:worktree:list","result":{"source":{"repo_root":"/home/kfritz/av"},"type":"worktree_list","worktrees":[\#
            {"branch":"common/master/latest","is_bare":false,"is_linked_worktree":false,"path":"/home/kfritz/av"},\#
            {"branch":"kf/trt-stable-sort","is_bare":false,"is_linked_worktree":true,"path":"/home/kfritz/av-trt-stable-sort"},\#
            {"branch":"kf/delve-preview-ci","is_bare":false,"is_linked_worktree":true,"path":"/home/kfritz/av-delve-previews"}]}}
            """#
        let notRepo = #"{"error":{"code":"not_git_worktree","message":"Herdr worktree actions require a path inside a Git work tree"},"id":"cli:worktree:list"}"#
        let text = output(snapshot([("/home/kfritz/av", "claude", "idle"), ("/home/kfritz/av", nil, nil),
                                    ("/home/kfritz/notes", nil, nil)]), home: home)
            + "#fwd:worktrees /home/kfritz/av\n\(worktrees)\n\n#fwd:end\n"
            + "#fwd:worktrees /home/kfritz/notes\n\(notRepo)\n\n#fwd:end\n"
        let answer = Herdr.read(text)
        guard case .directories(let dirs) = answer.listing else {
            Issue.record("expected directories: \(answer)"); return
        }
        #expect(dirs.map(\.display) == ["~/av", "~/av-delve-previews", "~/av-trt-stable-sort", "~/notes"])
        #expect(dirs.map(\.worktreeOf) == [nil, "/home/kfritz/av", "/home/kfritz/av", nil])
        #expect(dirs.map(\.branch) == [nil, "kf/delve-preview-ci", "kf/trt-stable-sort", nil])
        #expect(dirs[0].status == .agent)
        #expect(answer.details.contains("worktrees of /home/kfritz/av: 2 linked"), "\(answer.details)")
        #expect(answer.details.contains("worktrees of /home/kfritz/notes: not_git_worktree"), "\(answer.details)")
    }

    @Test func theHomeDirectoryShowsAsATilde() {
        guard case .directories(let dirs) = Herdr.parse(output(snapshot([("/home/me", nil, nil)]))) else {
            Issue.record("expected directories"); return
        }
        #expect(dirs.map(\.display) == ["~"])
        #expect(dirs.map(\.name) == ["~"])
        #expect(Herdr.tilde("/home/meow", home: "/home/me") == "/home/meow")
    }

    @Test func saysWhenHerdrIsMissingOrNotRunning() {
        #expect(Herdr.parse("#fwd:home /home/me\n#fwd:noherdr\n") == .notInstalled)
        #expect(Herdr.parse(output(notRunning, exit: 1)) == .notRunning)
        #expect(Herdr.parse(output(notRunning, exit: 1) + block("work", notRunning, exit: 1)) == .notRunning)
        let other = #"{"id":"x","error":{"code":"boom","message":"something broke"}}"#
        #expect(Herdr.parse(output(other, exit: 1)) == .failed("something broke"))
        #expect(Herdr.parse(output("Segmentation fault", exit: 139)) == .failed("herdr didn't give a snapshot (exit status 139)."))
        #expect(Herdr.parse("") == .failed("The host didn't answer as expected."))
        #expect(Herdr.parse(output(snapshot([]))) == .directories([]))
    }

    /// The script itself, under sh, with a stand-in herdr where a login
    /// PATH wouldn't find it.
    @Test func theScriptFindsHerdrOffThePath() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-herdr-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "HOME=\(home.path)", "/bin/sh", "-c"]
        let script = Herdr.script.trimmingCharacters(in: .newlines)

        // Unless this machine has its own herdr in one of the system folders.
        if !["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"].contains(where: FileManager.default.isExecutableFile) {
            let missing = await Shell.run(env[0], Array(env.dropFirst()) + [script])
            #expect(missing.ok)
            #expect(Herdr.parse(missing.stdout) == .notInstalled)
        }

        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("herdr")
        // Two sessions, as `herdr session list --json` prints them.
        try """
            #!/bin/sh
            case "$*" in
            "--version") echo "herdr 0.9.5" ;;
            "session list --json") echo '{"sessions":[{"default":true,"name":"default","running":true},{"default":false,"name":"work","running":true}]}' ;;
            "--session default api snapshot") echo '\(snapshot([("\(home.path)/code/fwd", "claude", "working")]))' ;;
            "--session work api snapshot") echo '\(snapshot([("\(home.path)/code/corridor", nil, nil)]))' ;;
            "worktree list --cwd \(home.path)/code/fwd") echo '{"result":{"worktrees":[{"branch":"main","is_linked_worktree":false,"path":"\(home.path)/code/fwd"},{"branch":"kf/x","is_linked_worktree":true,"path":"\(home.path)/code/fwd-x"}]}}' ;;
            "worktree list --cwd "*) echo '{"error":{"code":"not_git_worktree"}}' ;;
            *) exit 2 ;;
            esac
            """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let found = await Shell.run(env[0], Array(env.dropFirst()) + [script])
        #expect(found.ok)
        #expect(Herdr.parse(found.stdout) == .directories([
            Herdr.Directory(path: "\(home.path)/code/fwd", display: "~/code/fwd", status: .agent),
            Herdr.Directory(path: "\(home.path)/code/fwd-x", display: "~/code/fwd-x", status: .none,
                            worktreeOf: "\(home.path)/code/fwd", branch: "kf/x"),
            Herdr.Directory(path: "\(home.path)/code/corridor", display: "~/code/corridor", status: .none),
        ]), "\(found.stdout)")
    }

    @Test func theCommandSurvivesAnyLoginShell() {
        #expect(!Herdr.script.trimmingCharacters(in: .newlines).contains("'"))
        #expect(!Herdr.script.trimmingCharacters(in: .newlines).contains("\n"))
        #expect(Herdr.command.hasPrefix("sh -c '"))
    }

    @Test func isOnUnlessTurnedOff() throws {
        #expect(Preferences().herdr)
        #expect(try YAMLDecoder().decode(Preferences.self, from: "check_for_updates: true\n").herdr)
        #expect(try !YAMLDecoder().decode(Preferences.self, from: "herdr: false\n").herdr)
    }
}
