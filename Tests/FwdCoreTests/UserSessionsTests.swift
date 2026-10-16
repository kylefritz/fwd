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
