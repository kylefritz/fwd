import Foundation
import Testing
@testable import FwdCore

@Suite struct SSHConfigFileTests {
    func tempConfig() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fwd-sshcfg-\(UUID().uuidString.prefix(8))/.ssh/config")
    }

    func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1
    }

    @Test func prefersVSCodeThenEditorThenTextEdit() {
        let code = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        #expect(SSHConfigFile.chooseEditor(vsCode: code, editor: "nvim") == .app(code))
        #expect(SSHConfigFile.chooseEditor(vsCode: nil, editor: "nvim") == .terminal("nvim"))
        #expect(SSHConfigFile.chooseEditor(vsCode: nil, editor: "  ") == .textEdit)
        #expect(SSHConfigFile.chooseEditor(vsCode: nil, editor: nil) == .textEdit)
    }

    @Test func createsAMissingConfigWithSSHsPermissions() throws {
        let config = tempConfig()
        try SSHConfigFile.ensureExists(config)
        #expect(mode(config) == 0o600)
        #expect(mode(config.deletingLastPathComponent()) == 0o700)
        // A second call leaves it alone.
        try "Host a\n".write(to: config, atomically: true, encoding: .utf8)
        try SSHConfigFile.ensureExists(config)
        #expect(try String(contentsOf: config, encoding: .utf8) == "Host a\n")
    }

    @Test func exampleHostAppearsAsAHost() throws {
        let config = tempConfig()
        try SSHConfigFile.addExample(to: config, user: "sam")
        #expect(SSHConfig.hosts(configPath: config) == ["devbox"])
        #expect(try String(contentsOf: config, encoding: .utf8).contains("User sam"))
        #expect(mode(config) == 0o600)
    }

    @Test func exampleKeepsGlobalSettingsAndRefusesARealConfig() throws {
        let config = tempConfig()
        try SSHConfigFile.ensureExists(config)
        try "Host *\n  ServerAliveInterval 30".write(to: config, atomically: false, encoding: .utf8)
        try SSHConfigFile.addExample(to: config, user: "sam")
        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(text.hasPrefix("Host *\n  ServerAliveInterval 30\n\n# Added by fwd"))
        #expect(throws: SSHConfigFile.ExampleError.self) {
            try SSHConfigFile.addExample(to: config, user: "sam")
        }
    }
}
