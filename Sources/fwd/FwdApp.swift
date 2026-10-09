import AppKit
import FwdCore
import SwiftUI

@main
struct FwdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: delegate.model, updater: delegate.updater, app: delegate, inWindow: false)
                .frame(width: 380)
        } label: {
            MenuBarIcon(model: delegate.model, updater: delegate.updater)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar glyph: one shape per overall state, so it never relies on
/// color, plus a badge when an update is waiting.
struct MenuBarIcon: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel(label)
    }

    private var updateWaiting: Bool {
        if case .ready = updater.state { return true }
        return false
    }

    private var symbol: String {
        if updateWaiting { return "arrow.down.circle.fill" }
        switch model.overall {
        case .idle: return "arrow.right.circle"
        case .forwarding: return "arrow.right.circle.fill"
        case .attention: return "exclamationmark.circle"
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
        releasesURL: paths.releasesURL, bundleURL: Bundle.main.bundleURL,
        currentVersion: AppDelegate.version, log: model.log)

    private var window: NSWindow?
    private var visibleSurfaces = 0
    private var updateTimer: Timer?
    private var quitting = false
    private var cleanedUp = false

    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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

    /// Opening the app again (Finder, `open -a`, the `fwd` command) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    /// Quitting closes the ssh connections first. The first request is
    /// declined while that happens and then repeated; waiting inside
    /// `.terminateLater` instead would stall, because the cleanup needs the
    /// main queue that AppKit is then blocking.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if cleanedUp { return .terminateNow }
        if !quitting {
            quitting = true
            Task {
                await model.shutdown()
                cleanedUp = true
                NSApp.terminate(nil)
            }
        }
        return .terminateCancel
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
        let body = "#!/bin/sh\necho \"fwd: connecting to \(host.replacingOccurrences(of: "\"", with: ""))...\"\nexec \(command)\n"
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
