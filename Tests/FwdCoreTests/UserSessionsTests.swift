import Foundation
import Testing
@testable import FwdCore

/// Finding which hosts you have your own ssh session to, from `ps` output.
@Suite struct UserSessionsTests {
    let socketDir = "/Users/me/Library/Application Support/fwd/sockets"

    func hosts(_ ps: String) -> Set<String> {
        UserSessions.hosts(psOutput: ps, socketDir: socketDir)
    }

    @Test func plainAndOptionHeavySessions() {
        #expect(hosts("/usr/bin/ssh vdesk\n") == ["vdesk"])
        #expect(hosts("ssh -t -A mbar tmux attach\n") == ["mbar"])
        #expect(hosts("/opt/homebrew/bin/ssh -p 2222 -i ~/.ssh/id -o ServerAliveInterval=5 devbox\n") == ["devbox"])
        #expect(hosts("ssh -p2222 -lme devbox\n") == ["devbox"], "option values stuck to the flag")
        #expect(hosts("ssh -L 8080:localhost:80 -- devbox\n") == ["devbox"])
    }

    @Test func userAndURIFormsNameTheHost() {
        #expect(hosts("ssh kfritz@vdesk\n") == ["vdesk"])
        #expect(hosts("ssh ssh://kfritz@devbox:2222\n") == ["devbox"])
    }

    @Test func notSessions() {
        // fwd's own masters and control commands use its socket directory.
        #expect(hosts("ssh -M -N -S \(socketDir)/abc.sock -o BatchMode=yes mbar\n").isEmpty)
        #expect(hosts("ssh -S \(socketDir)/abc.sock -O check mbar\n").isEmpty)
        // Config queries, and the stdio hop ProxyJump runs, aren't sessions.
        #expect(hosts("ssh -G mbar\n").isEmpty)
        #expect(hosts("ssh -W [devbox]:22 jumphost\n").isEmpty)
        // Other programs, including ones whose name ends in ssh.
        #expect(hosts("/usr/sbin/sshd -D\nssh-agent -l\n/usr/bin/autossh devbox\nvim ssh devbox\n").isEmpty)
        #expect(hosts("ssh\nssh -V\n").isEmpty)
    }

    @Test func severalSessions() {
        let ps = """
            /sbin/launchd
            /usr/bin/ssh vdesk
            -fish
            ssh mbar
            /usr/bin/ssh vdesk
            """
        #expect(hosts(ps) == ["vdesk", "mbar"])
    }
}
