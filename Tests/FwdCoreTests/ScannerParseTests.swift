import Foundation
import Testing
@testable import FwdCore

@Suite struct ScannerParseTests {
    @Test func ss() {
        let out = """
        #ss
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
        #netstat
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
        #netstat
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
        #lsof
        COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node    81234   me   22u  IPv4 0x1234567890abcdef      0t0  TCP 127.0.0.1:3000 (LISTEN)
        ruby    81300   me   10u  IPv6 0x1234567890abcdee      0t0  TCP [::1]:4567 (LISTEN)
        python  81400   me    4u  IPv4 0x1234567890abcded      0t0  TCP *:8000 (LISTEN)
        """
        #expect(RemoteScanner.parse(out) == [3000, 4567, 8000])
    }

    @Test func noToolOrGarbageMeansUnknownNotCrash() {
        #expect(RemoteScanner.parse("#none\n") == nil)
        #expect(RemoteScanner.parse("") == nil)
        #expect(RemoteScanner.parse("Welcome to devbox!\nLast login: yesterday\n") == nil)
        #expect(RemoteScanner.parse("#ss\ngarbage line\nLISTEN x y notanaddress z\nLISTEN 0 1 1.2.3.4:99999 *\n") == [])
        #expect(RemoteScanner.parse("#ss\n") == [])
    }

    @Test func scriptMatchesTheFileCIRunsOnLinux() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/scan.sh")
        #expect(try String(contentsOf: file, encoding: .utf8) == RemoteScanner.script)
        #expect(!RemoteScanner.script.contains("'"))
    }
}
