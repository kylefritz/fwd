import Foundation
import Testing
@testable import FwdCore

@Suite struct ScannerParseTests {
    @Test func ss() {
        let out = """
        #fwd:ss
        LISTEN 0      128          0.0.0.0:22         0.0.0.0:*
        LISTEN 0      511        127.0.0.1:3000       0.0.0.0:*
        LISTEN 0      4096   127.0.0.53%lo:53         0.0.0.0:*
        LISTEN 0      128             [::]:22            [::]:*
        LISTEN 0      511                *:8080             *:*
        LISTEN 0      511            [::1]:5173          [::]:*
        """
        #expect(RemoteScanner.parse(out) == [22, 3000, 53, 8080, 5173])
    }

    @Test func netstatOnMacOS() {
        let out = """
        #fwd:netstat
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  127.0.0.1.3000         *.*                    LISTEN
        tcp46      0      0  *.8080                 *.*                    LISTEN
        tcp6       0      0  ::1.5173               *.*                    LISTEN
        tcp4       0      0  192.168.1.5.52100      17.57.144.10.5223      ESTABLISHED
        udp4       0      0  *.5353                 *.*
        """
        #expect(RemoteScanner.parse(out) == [3000, 8080, 5173])
    }

    @Test func netstatOnLinux() {
        let out = """
        #fwd:netstat
        Active Internet connections (servers and established)
        Proto Recv-Q Send-Q Local Address           Foreign Address         State
        tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN
        tcp6       0      0 :::3000                 :::*                    LISTEN
        tcp        0      0 10.0.0.4:22             10.0.0.9:51234          ESTABLISHED
        """
        #expect(RemoteScanner.parse(out) == [22, 3000])
    }

    @Test func lsof() {
        let out = """
        #fwd:lsof
        COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node    81234   me   22u  IPv4 0x1234567890abcdef      0t0  TCP 127.0.0.1:3000 (LISTEN)
        ruby    81300   me   10u  IPv6 0x1234567890abcdee      0t0  TCP [::1]:4567 (LISTEN)
        python  81400   me    4u  IPv4 0x1234567890abcded      0t0  TCP *:8000 (LISTEN)
        """
        #expect(RemoteScanner.parse(out) == [3000, 4567, 8000])
    }

    @Test func chatterBeforeTheHeaderIsSkipped() {
        let out = """
        Welcome to devbox!
        You have new mail.
        #fwd:ss
        LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*
        """
        #expect(RemoteScanner.parse(out) == [3000])
    }

    @Test func theCommandIsOneLineSoAnyLoginShellAcceptsIt() {
        #expect(!RemoteScanner.command.contains("\n"))
        #expect(RemoteScanner.command.hasPrefix("sh -c '") && RemoteScanner.command.hasSuffix("'"))
    }

    @Test func failuresAreSortedIntoRetryOrAskAPerson() {
        func needsPerson(_ stderr: String) -> Bool {
            if case .needsAttention = SSHConnection.classify(stderr: stderr) { return true }
            return false
        }
        #expect(needsPerson("me@host: Permission denied (publickey)."))
        #expect(needsPerson("Host key verification failed."))
        #expect(needsPerson("Please open the following URL and log in with your account:\nhttps://example.com"))
        #expect(!needsPerson("ssh: connect to host 10.0.0.1 port 22: Operation timed out"))
        #expect(!needsPerson("ssh: Could not resolve hostname devbox: nodename nor servname provided"))
        #expect(!needsPerson(""))
        // cloudflared's wording; each retry would open another browser tab.
        let cloudflared = """
            A browser window should have opened at the following URL:
            https://ssh.example.com/cdn-cgi/access/cli?aud=abc
            If the browser failed to open, please visit the URL above directly in your browser.
            Connection timed out during banner exchange
            Connection to UNKNOWN port 65535 timed out
            """
        #expect(needsPerson(cloudflared))
        #expect(SSHConnection.classify(stderr: cloudflared).message.contains("sign in"),
                "the card should say why, not show the timeout")
        // A server banner mentioning these words must not stop retries.
        #expect(!needsPerson("Use your browser to read the policy. Enter your passphrase carefully.\nConnection timed out during banner exchange"))
    }

    @Test func noToolOrGarbageMeansUnknownNotCrash() {
        #expect(RemoteScanner.parse("#fwd:none\n") == nil)
        #expect(RemoteScanner.parse("") == nil)
        #expect(RemoteScanner.parse("Welcome to devbox!\nLast login: yesterday\n") == nil)
        #expect(RemoteScanner.parse("#fwd:ss\ngarbage line\nLISTEN x y notanaddress z\nLISTEN 0 1 1.2.3.4:99999 *\n") == [])
        #expect(RemoteScanner.parse("#fwd:ss\n") == [])
    }

    @Test func scriptMatchesTheFileCIRunsOnLinux() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/scan.sh")
        #expect(try String(contentsOf: file, encoding: .utf8) == RemoteScanner.script)
        #expect(!RemoteScanner.script.contains("'"))
    }
}
