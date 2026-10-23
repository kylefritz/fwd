import Foundation
import Testing
@testable import FwdCore

@MainActor
@Suite struct VSCodeTests {
    typealias Rig = AppModelTests.Rig
    let editor = VSCode.editors[0]

    /// A stand-in app bundle whose command line writes its arguments to a
    /// file, then exits with `status`.
    func fakeApp(status: Int = 0, stderr: String = "") throws -> (app: URL, argsFile: URL) {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("fwd-vscode-\(UUID().uuidString.prefix(8)).app")
        let bin = app.appendingPathComponent("Contents/Resources/app/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let argsFile = app.appendingPathComponent("args")
        let script = bin.appendingPathComponent("code")
        try """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(argsFile.path)'
            printf '%s' '\(stderr)' >&2
            exit \(status)
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (app, argsFile)
    }

    @Test func opensANewRemoteWindowThroughTheBundledCommandLine() async throws {
        let (app, argsFile) = try fakeApp()
        defer { try? FileManager.default.removeItem(at: app) }
        try await VSCode.open(host: "devbox", app: app, editor: editor)
        #expect(try String(contentsOf: argsFile, encoding: .utf8) == "--new-window\n--remote\nssh-remote+devbox\n")
    }

    @Test func eachEditorKeepsItsCommandLineInTheSamePlace() {
        let app = URL(fileURLWithPath: "/Applications/Cursor.app")
        let cursor = VSCode.editors.first { $0.name == "Cursor" }!
        #expect(VSCode.commandLine(app: app, editor: cursor).path
                == "/Applications/Cursor.app/Contents/Resources/app/bin/cursor")
    }

    @Test func saysWhyWhenTheEditorFails() async throws {
        let (app, _) = try fakeApp(status: 1, stderr: "Remote-SSH is not installed")
        defer { try? FileManager.default.removeItem(at: app) }
        await #expect(throws: VSCodeError.failed("VS Code", "Remote-SSH is not installed")) {
            try await VSCode.open(host: "devbox", app: app, editor: editor)
        }
    }

    @Test func refusesHostsThatLookLikeOptionsAndBundlesWithoutACommandLine() async throws {
        let (app, argsFile) = try fakeApp()
        defer { try? FileManager.default.removeItem(at: app) }
        await #expect(throws: VSCodeError.badHost("-oProxyCommand=x")) {
            try await VSCode.open(host: "-oProxyCommand=x", app: app, editor: editor)
        }
        #expect(!FileManager.default.fileExists(atPath: argsFile.path), "the editor never ran")

        let empty = URL(fileURLWithPath: "/nonexistent/Code.app")
        await #expect(throws: VSCodeError.noCommandLine("VS Code", "/nonexistent/Code.app/Contents/Resources/app/bin/code")) {
            try await VSCode.open(host: "devbox", app: empty, editor: editor)
        }
    }

    @Test func theCodeCommandOpensHostsFromTheSSHConfigOnly() async throws {
        let rig = try Rig()
        await rig.model.start(runTimer: false)
        var opened: [String] = []
        let handler = ControlHandler(model: rig.model, open: { _ in },
                                     openInVSCode: { opened.append($0) }, pollInterval: 0.02)
        let reply = await handler.handle(ControlRequest(cmd: "code", args: ["devbox"]))
        #expect(reply.ok, "\(reply)")
        #expect(reply.host?.host == "devbox")
        #expect(opened == ["devbox"])

        let unknown = await handler.handle(ControlRequest(cmd: "code", args: ["nowhere"]))
        #expect(!unknown.ok)
        #expect(opened == ["devbox"])

        let missing = await ControlHandler(model: rig.model, open: { _ in })
            .handle(ControlRequest(cmd: "code", args: ["devbox"]))
        #expect(missing.exitCode == .failed)
        #expect(missing.error?.contains("Install VS Code") == true, "\(missing)")
        await rig.model.shutdown()
    }
}
