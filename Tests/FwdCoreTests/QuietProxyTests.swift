import Foundation
import Testing
@testable import FwdCore

@Suite struct QuietProxyTests {
    let standIn = "/Users/me/Library/Application Support/fwd/sockets/ab12-CDEF34.open"

    @Test func putsTheStandInFirstAfterTheShellHasStarted() {
        let wrapped = QuietProxy.wrapped("/opt/homebrew/bin/cloudflared access ssh --hostname %h",
                                         standIn: standIn, shell: "/opt/homebrew/bin/fish")
        #expect(wrapped == "env PATH=\"\(standIn):$PATH\" /opt/homebrew/bin/cloudflared access ssh --hostname %h")
    }

    @Test func leavesTheCommandItselfUntouched() {
        // Quotes, ssh's % tokens and a script handed to sh all pass through as written.
        let command = #"sh -c 'open "https://example.com"; exec nc %h %p' -- "a b" 100%%"#
        #expect(QuietProxy.wrapped(command, standIn: standIn, shell: "/bin/zsh") == "env PATH=\"\(standIn):$PATH\" " + command)
    }

    @Test func worksForTheShellsThatReadThatLineTheSameWay() {
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/ksh", "/usr/local/bin/fish", nil, ""] {
            #expect(QuietProxy.wrapped("nc %h %p", standIn: standIn, shell: shell) != nil, "\(shell ?? "nil")")
        }
        #expect(QuietProxy.wrapped("nc %h %p", standIn: standIn, shell: "/opt/homebrew/bin/nu") == nil)
        #expect(QuietProxy.wrapped("nc %h %p", standIn: standIn, shell: "/bin/tcsh") == nil)
    }

    @Test func leavesAloneWhatEnvCantRun() {
        // `env` runs one program. A pipeline, a list or a shell keyword would break under it.
        for command in ["a %h | b", "a; b", "a && b", "exec nc %h %p", "FOO=1 nc %h %p", "(nc %h %p)",
                        "nc %h %p > /dev/null", "nc `hostname` 22", "if true; then nc %h %p; fi", "", "  "] {
            #expect(QuietProxy.wrapped(command, standIn: standIn, shell: "/bin/zsh") == nil, "\(command)")
        }
        // The same characters inside quotes are just arguments.
        #expect(QuietProxy.wrapped(#"sh -c "a | b; c""#, standIn: standIn, shell: "/bin/zsh") != nil)
        #expect(QuietProxy.wrapped(#"nc a\;b 22"#, standIn: standIn, shell: "/bin/zsh") != nil)
    }

    @Test func leavesAloneAFolderNameItCouldntQuote() {
        for dir in ["/tmp/a\"b.open", "/tmp/a$b.open", "/tmp/a`b.open", "/tmp/a\\b.open", "/tmp/a%b.open", "/tmp/a:b.open"] {
            #expect(QuietProxy.wrapped("nc %h %p", standIn: dir, shell: "/bin/zsh") == nil, "\(dir)")
        }
    }

    @Test func readsTheProxyCommandFromSSHsOwnAnswer() {
        let config = "user me\nproxyusefdpass no\nproxycommand /opt/x/cloudflared access ssh --hostname %h\nport 22\n"
        #expect(QuietProxy.command(sshG: config) == "/opt/x/cloudflared access ssh --hostname %h")
        #expect(QuietProxy.command(sshG: "user me\nproxyusefdpass no\nport 22\n") == nil)
    }
}
