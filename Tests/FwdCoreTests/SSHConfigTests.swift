import Foundation
import Testing
@testable import FwdCore

@Suite struct SSHConfigTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func listsConcreteHostsInOrder() throws {
        let dir = try tempDir()
        let config = dir.appendingPathComponent("config")
        try """
        # a comment
        Host devbox
          HostName dev.example.com
        Host homelab staging   # two names
        \tUser me
        Host *.internal !bastion web?
          User nobody
        host=quoted "with space"
        Host *
          ServerAliveInterval 30
        Host devbox
        """.write(to: config, atomically: true, encoding: .utf8)
        #expect(SSHConfig.hosts(configPath: config, sshDir: dir) == ["devbox", "homelab", "staging", "quoted", "with space"])
    }

    @Test func followsIncludesWithGlobsAndRelativePaths() throws {
        let dir = try tempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("conf.d"), withIntermediateDirectories: true)
        try "Host one\n".write(to: dir.appendingPathComponent("conf.d/a.conf"), atomically: true, encoding: .utf8)
        try "Host two\nInclude conf.d/*.conf\n".write(to: dir.appendingPathComponent("conf.d/b.conf"), atomically: true, encoding: .utf8)
        let other = dir.appendingPathComponent("elsewhere")
        try "Host three\n".write(to: other, atomically: true, encoding: .utf8)
        let config = dir.appendingPathComponent("config")
        try "Include conf.d/*.conf \(other.path) missing-file\nHost main\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(SSHConfig.hosts(configPath: config, sshDir: dir) == ["one", "two", "three", "main"])
        #expect(SSHConfig.files(configPath: config, sshDir: dir).count == 4)
    }

    @Test func missingConfigIsEmpty() throws {
        let dir = try tempDir()
        #expect(SSHConfig.hosts(configPath: dir.appendingPathComponent("nope"), sshDir: dir).isEmpty)
    }

    @Test func hundredsOfHosts() throws {
        let dir = try tempDir()
        let config = dir.appendingPathComponent("config")
        let text = (0..<800).map { "Host box\($0)\n  HostName 10.0.0.\($0 % 250)\n" }.joined()
        try text.write(to: config, atomically: true, encoding: .utf8)
        let hosts = SSHConfig.hosts(configPath: config, sshDir: dir)
        #expect(hosts.count == 800)
        #expect(hosts.first == "box0" && hosts.last == "box799")
    }

    @Test func parsesForwardsFromSSHG() {
        let output = """
        host devbox
        user me
        localforward 8000 [127.0.0.1]:8000
        localforward 127.0.0.1:5432 db.internal:5432
        localforward [::1]:9000 localhost:9000
        remoteforward 9222 localhost:9222
        localforward 8000 [127.0.0.1]:8000
        localforward /tmp/sock /var/run/other.sock
        forwardagent no
        """
        #expect(SSHConfig.parseForwards(sshG: output) == [
            ConfigForward(kind: .local, listenPort: 8000, target: "[127.0.0.1]:8000"),
            ConfigForward(kind: .local, listenPort: 5432, target: "db.internal:5432"),
            ConfigForward(kind: .local, listenPort: 9000, target: "localhost:9000"),
            ConfigForward(kind: .remote, listenPort: 9222, target: "localhost:9222"),
        ])
    }
}
