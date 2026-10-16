import AppKit
import FwdCore
import SwiftUI

@main
struct FwdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Build step: `fwd --write-iconset <dir>` draws the app icon and exits.
        if let flag = CommandLine.arguments.firstIndex(of: "--write-iconset"), flag + 1 < CommandLine.arguments.count {
            do {
                try FwdMark.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("couldn't write the iconset: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: delegate.model, updater: delegate.updater, app: delegate, inWindow: false)
                .frame(width: 440)
        } label: {
            MenuBarIcon(model: delegate.model, updater: delegate.updater)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar glyph: the fwd mark, dimmed when idle, with a dot at the top
/// for attention and at the bottom when an update is waiting. Never relies
/// on color.
struct MenuBarIcon: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    var body: some View {
        Image(nsImage: FwdMark.menuBarImage(look))
            .accessibilityLabel(label)
    }

    private var updateWaiting: Bool {
        if case .ready = updater.state { return true }
        return false
    }

    private var look: FwdMark.Look {
        if updateWaiting { return .updateReady }
        switch model.overall {
        case .idle: return .idle
        case .forwarding: return .forwarding
        case .attention: return .attention
        }
    }

    private var label: String {
        if updateWaiting { return "fwd, update ready" }
        switch model.overall {
        case .idle: return "fwd, idle"
        case .forwarding: return "fwd, forwarding"
        case .attention: return "fwd, needs attention"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let paths = Paths.fromEnvironment()
    let power = SystemPowerMonitor()
    lazy var model = AppModel(paths: paths, power: power)
    lazy var updater = Updater(
        releasesURL: paths.releasesURL, releasesListURL: paths.releasesListURL, bundleURL: Bundle.main.bundleURL,
        currentVersion: AppDelegate.version, log: model.log,
        channel: { [store = model.store] in store.loadPreferences().updateChannel })

    private var window: NSWindow?
    private var visibleSurfaces = 0
    private var updateTimer: Timer?
    private var isDuplicate = false

    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Two copies would close each other's connections. If one is already
        // running, hand over to it and leave.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Paths.bundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if Bundle.main.bundleIdentifier == Paths.bundleIdentifier, let running = others.first,
           !CommandLine.arguments.contains("--snapshot") {
            isDuplicate = true
            running.activate()
            NSApp.terminate(nil)
            return
        }
        power.start()
        Task {
            await model.start()
            if model.store.loadPreferences().checkForUpdates {
                await updater.check()
            }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.model.store.loadPreferences().checkForUpdates else { return }
                await self.updater.check()
            }
        }
        if CommandLine.arguments.contains("--show-window") {
            showWindow()
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), flag + 1 < CommandLine.arguments.count {
            snapshot(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot-panel"), flag + 1 < CommandLine.arguments.count {
            snapshotPanel(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        }
    }

    /// Development aid: `--snapshot <file.png>` draws the window to an image
    /// after a few seconds and quits. Used for README screenshots and for
    /// checking the layout on a machine with no one at the screen.
    private func snapshot(to file: URL) {
        showWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, let view = self.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                NSApp.terminate(nil)
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
            NSApp.terminate(nil)
        }
    }

    /// Like `--snapshot`, but draws the menu bar panel at the size it picks for itself.
    private func snapshotPanel(to file: URL) {
        let view = NSHostingView(rootView:
            PanelView(model: model, updater: updater, app: self, inWindow: false)
                .frame(width: 440)
                .background(.windowBackground))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 100),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            w.setContentSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
            }
            NSApp.terminate(nil)
        }
    }

    /// Opening the app again (Finder, `open -a`, the `fwd` command) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    /// Quitting closes the ssh connections first, synchronously, so that a
    /// logout or restart is never held up or cancelled by fwd. Each
    /// connection gets a couple of seconds at most.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !isDuplicate {
            SSHConnection.closeAllBlocking(paths: paths)
            model.log.write("fwd stopped")
            model.log.flush()
        }
        return .terminateNow
    }

    func showWindow() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: PanelView(model: model, updater: updater, app: self, inWindow: true))
            let w = NSWindow(contentViewController: hosting)
            w.title = "fwd"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 440, height: 600))
            w.contentMinSize = NSSize(width: 360, height: 320)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Panel and window each report when they appear and disappear; live
    /// status is only sampled while at least one is showing.
    func surfaceAppeared() {
        visibleSurfaces += 1
        model.setVisible(true)
        updater.noticeHomebrewUpgrade()
    }

    func surfaceDisappeared() {
        visibleSurfaces = max(0, visibleSurfaces - 1)
        model.setVisible(visibleSurfaces > 0)
    }

    // MARK: Actions the views can't do themselves

    func openLog() {
        if !FileManager.default.fileExists(atPath: paths.logFile.path) {
            model.log.write("log opened")
            model.log.flush()
        }
        NSWorkspace.shared.open(paths.logFile)
    }

    /// Opens the ssh config in VS Code, else `$EDITOR` in Terminal, else
    /// TextEdit. Creates an empty one first if there's none.
    func openSSHConfig() {
        let file = model.paths.sshConfig
        do {
            try SSHConfigFile.ensureExists(file)
        } catch {
            model.log.write("couldn't create \(file.path): \(error.localizedDescription)")
            return
        }
        let vsCode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")
        Task {
            let editor = vsCode == nil ? await loginShellEditor() : nil
            switch SSHConfigFile.chooseEditor(vsCode: vsCode, editor: editor) {
            case .app(let app):
                _ = try? await NSWorkspace.shared.open([file], withApplicationAt: app,
                                                       configuration: NSWorkspace.OpenConfiguration())
            case .terminal(let command):
                runInTerminal(name: "edit-ssh-config", command: "\(command) \(shellQuote(file.path))")
            case .textEdit:
                if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
                    _ = try? await NSWorkspace.shared.open([file], withApplicationAt: textEdit,
                                                           configuration: NSWorkspace.OpenConfiguration())
                }
            }
            model.log.write("opened the ssh config")
        }
    }

    /// Writes an example host into an ssh config that has none, then opens it.
    func addExampleHost() throws {
        try SSHConfigFile.addExample(to: model.paths.sshConfig, user: NSUserName())
        model.log.write("added an example host to the ssh config")
        openSSHConfig()
    }

    /// Apps opened from the Dock or at login don't inherit the shell's
    /// environment, so ask the login shell what `$EDITOR` is.
    private func loginShellEditor() async -> String? {
        if let editor = ProcessInfo.processInfo.environment["EDITOR"], !editor.isEmpty { return editor }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // A marker, because shell startup files can print greetings.
        let result = await Shell.run(shell, ["-l", "-c", "printf '__fwd_editor__%s\\n' \"$EDITOR\""], timeout: 5)
        guard let line = result.stdout.split(whereSeparator: \.isNewline)
            .last(where: { $0.hasPrefix("__fwd_editor__") }) else { return nil }
        let editor = line.dropFirst("__fwd_editor__".count).trimmingCharacters(in: .whitespaces)
        return editor.isEmpty ? nil : editor
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Runs `command` in a new Terminal window through the user's login
    /// shell, so their PATH applies.
    private func runInTerminal(name: String, command: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-terminal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("\(name).command")
        let body = "#!/bin/sh\nexec \"${SHELL:-/bin/zsh}\" -l -c \(shellQuote(command))\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            model.log.write("couldn't open a terminal: \(error.localizedDescription)")
        }
    }

    func copyLogLocation() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.logFile.path, forType: .string)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Runs `ssh <host>` in the user's terminal so they can answer whatever
    /// ssh is asking for. A `.command` file opens in the default terminal app
    /// without needing automation permission.
    func openInTerminal(host: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-terminal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("ssh-\(Paths.shortHash(host)).command")
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var command = "ssh"
        if let config = paths.sshConfigOverride { command += " -F \(quote(config.path))" }
        command += " -- \(quote(host))"
        // The host name only ever appears single-quoted, so nothing in it
        // can be read by the shell as code.
        let body = "#!/bin/sh\nprintf 'fwd: connecting to %s\\n' \(quote(host))\nexec \(command)\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
            model.log.write("opened a terminal for the user", host: host)
        } catch {
            model.log.write("couldn't open a terminal: \(error.localizedDescription)", host: host)
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Switches to the prepared update: launch the new copy once this one
    /// has gone, then quit.
    func restartToUpdate() {
        do {
            let bundle = try updater.install()
            relaunch(bundle)
        } catch {
            model.log.write("update install failed: \(error.localizedDescription)")
            if let url = URL(string: "https://github.com/\(Paths.repository)/releases/latest") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func relaunch(_ bundle: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits for this process to exit before opening the new copy.
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", bundle.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
