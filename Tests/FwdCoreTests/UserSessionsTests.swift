import Foundation
import Testing
@testable import FwdCore

/// Finding which hosts you have your own ssh session to.
@Suite struct UserSessionsTests {
    let socketDir = "/tmp/fwd-501"

    func hosts(_ commands: [String]) -> Set<String> {
        // One process per command line, all started from a shell (pid 1).
        let processes = commands.enumerated().map { i, line in
            UserSessions.Process(pid: Int32(100 + i), ppid: 1, arguments: line.split(separator: " ").map(String.init))
        }
        return UserSessions.hosts(processes, socketDir: socketDir)
    }

    @Test func plainAndOptionHeavySessions() {
        #expect(hosts(["/usr/bin/ssh vdesk"]) == ["vdesk"])
        #expect(hosts(["ssh -t -A mbar tmux attach"]) == ["mbar"])
        #expect(hosts(["/opt/homebrew/bin/ssh -p 2222 -i ~/.ssh/id -o ServerAliveInterval=5 devbox"]) == ["devbox"])
        #expect(hosts(["ssh -p2222 -lme devbox"]) == ["devbox"], "option values stuck to the flag")
        #expect(hosts(["ssh -L 8080:localhost:80 -- devbox"]) == ["devbox"])
    }

    @Test func anOptionValueWithSpacesStaysOneArgument() {
        let p = UserSessions.Process(pid: 9, ppid: 1, arguments: ["ssh", "-o", "ProxyCommand nc -X 5 %h %p", "devbox"])
        #expect(UserSessions.hosts([p], socketDir: socketDir) == ["devbox"])
    }

    @Test func userURIAndCaseNameTheHost() {
        #expect(hosts(["ssh kfritz@vdesk"]) == ["vdesk"])
        #expect(hosts(["ssh ssh://kfritz@devbox:2222"]) == ["devbox"])
        #expect(hosts(["ssh DevBox"]) == ["devbox"], "ssh treats host names case-insensitively")
    }

    @Test func notSessions() {
        // fwd's own masters and control commands use its socket directory.
        #expect(hosts(["ssh -M -N -S \(socketDir)/abc.sock -o BatchMode=yes mbar"]).isEmpty)
        #expect(hosts(["ssh -S \(socketDir)/abc.sock -O check mbar"]).isEmpty)
        // The one-off ssh for the VS Code button's herdr check.
        #expect(hosts(["ssh -o BatchMode=yes -o ControlMaster=no -o ControlPath=\(socketDir)/herdr-check -- devbox echo"]).isEmpty)
        // Config queries, and the stdio hop ProxyJump runs, aren't sessions.
        #expect(hosts(["ssh -G mbar", "ssh -W [devbox]:22 jumphost"]).isEmpty)
        // Other programs, including ones whose name ends in ssh.
        #expect(hosts(["/usr/sbin/sshd -D", "ssh-agent -l", "/usr/bin/autossh devbox", "vim ssh devbox"]).isEmpty)
        #expect(hosts(["ssh", "ssh -V"]).isEmpty)
    }

    @Test func anSshStartedByAnotherSshIsAProxyHopNotASession() {
        let master = UserSessions.Process(pid: 50, ppid: 1, arguments: ["ssh", "-M", "-S", "\(socketDir)/x", "mbar"])
        let hop = UserSessions.Process(pid: 51, ppid: 50, arguments: ["ssh", "jump", "nc", "mbar", "22"])
        let yours = UserSessions.Process(pid: 60, ppid: 1, arguments: ["ssh", "devbox"])
        let yourHop = UserSessions.Process(pid: 61, ppid: 60, arguments: ["ssh", "-W", "devbox:22", "bastion"])
        let yourProxyCommand = UserSessions.Process(pid: 62, ppid: 60, arguments: ["ssh", "bastion", "nc", "devbox", "22"])
        #expect(UserSessions.hosts([master, hop, yours, yourHop, yourProxyCommand], socketDir: socketDir) == ["devbox"])
    }

    @Test func aNewProxiedSshIsSettlingNotASession() {
        let young = UserSessions.Process(pid: 70, ppid: 1, arguments: ["ssh", "mbar"], age: 8)
        let proxy = UserSessions.Process(pid: 71, ppid: 70, arguments: ["cloudflared"], age: 8)
        let found = UserSessions.find([young, proxy], socketDir: socketDir)
        #expect(found.sessions.isEmpty)
        #expect(found.settling == ["mbar"])

        let settled = UserSessions.Process(pid: 70, ppid: 1, arguments: ["ssh", "mbar"], age: 25)
        #expect(UserSessions.find([settled, proxy], socketDir: socketDir) == .init(sessions: ["mbar"]))
    }

    @Test func aNewPlainSshCountsRightAway() {
        let p = UserSessions.Process(pid: 70, ppid: 1, arguments: ["ssh", "devbox"], age: 1)
        #expect(UserSessions.hosts([p], socketDir: socketDir) == ["devbox"])
    }

    @Test func anOlderSessionToTheSameHostWins() {
        let old = UserSessions.Process(pid: 70, ppid: 1, arguments: ["ssh", "mbar"], age: 600)
        let oldProxy = UserSessions.Process(pid: 71, ppid: 70, arguments: ["cloudflared"])
        let new = UserSessions.Process(pid: 80, ppid: 1, arguments: ["ssh", "mbar"], age: 2)
        let newProxy = UserSessions.Process(pid: 81, ppid: 80, arguments: ["cloudflared"])
        #expect(UserSessions.find([old, oldProxy, new, newProxy], socketDir: socketDir) == .init(sessions: ["mbar"]))
    }

    @Test func parsesPsElapsedTime() {
        #expect(UserSessions.elapsed("00:09") == 9)
        #expect(UserSessions.elapsed("12:34") == 754)
        #expect(UserSessions.elapsed("01:02:03") == 3723)
        #expect(UserSessions.elapsed("2-01:02:03") == 176_523, "2 days, 1h 2m 3s")
        #expect(UserSessions.elapsed("soon") == nil)
    }

    @Test func readsARealProcessesArguments() throws {
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["5"]
        try p.run()
        defer { p.terminate() }
        let args = try #require(UserSessions.arguments(pid: p.processIdentifier))
        #expect(args.last == "5")
        #expect(args.first?.hasSuffix("sleep") == true)
    }
}
