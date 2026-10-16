import AppKit
import FwdCore

/// The fwd.app this command was installed in, found through the symlink in
/// ~/.local/bin or Homebrew's bin. Nil when run from a build folder.
let app: URL? = {
    let me = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
    // .../fwd.app/Contents/Resources/bin/fwd
    let bundle = me.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let plist = bundle.appendingPathComponent("Contents/Info.plist")
    return FileManager.default.fileExists(atPath: plist.path) ? bundle : nil
}()

func version() -> String {
    guard let app, let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let version = info["CFBundleShortVersionString"] as? String else { return "dev" }
    return version
}

/// Opens fwd by bundle identifier, so a copy that's already running answers
/// even if it was started from another path; falls back to this copy.
func openApp(window: Bool) {
    func run(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
    let extra = window ? ["--args", "--show-window"] : []
    let quiet = window ? [] : ["-g"]
    if run(quiet + ["-b", Paths.bundleIdentifier] + extra) { return }
    if let app { _ = run(quiet + [app.path] + extra) }
}

func fail(_ message: String, _ code: ExitCode) -> Never {
    FileHandle.standardError.write(Data("fwd: \(message)\n".utf8))
    exit(Int32(code.rawValue))
}

switch CLIArguments.parse(Array(CommandLine.arguments.dropFirst())) {
case .version:
    print(version())
case .help:
    print(CLIArguments.help)
case .agents:
    print(CLIArguments.agentInstructions)
case .usage(let message, let json):
    if json {
        print(ControlFormat.json(.failure(.usage(message))))
        exit(Int32(ExitCode.usage.rawValue))
    }
    fail(message, .usage)
case .openWindow:
    openApp(window: true)
case .request(let request, let json):
    let socket = Paths.fromEnvironment().controlSocket.path
    let reply = CLIRunner.send(request, socket: socket, launch: { openApp(window: false) }, isRunning: {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Paths.bundleIdentifier).isEmpty
    })
    if json {
        print(ControlFormat.json(reply))
    } else if reply.ok {
        let text = ControlFormat.human(reply, command: request.cmd)
        if !text.isEmpty { print(text) }
    } else {
        FileHandle.standardError.write(Data((ControlFormat.human(reply, command: request.cmd) + "\n").utf8))
    }
    exit(Int32(reply.exitCode.rawValue))
}
