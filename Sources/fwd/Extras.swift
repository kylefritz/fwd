import AppKit
import FwdCore
import ServiceManagement
import SwiftUI

/// Launch at login, backed by the system's own list.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an explanation when it couldn't be changed.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// The `fwd` terminal command: a symlink in `~/.local/bin` to a script
/// inside the app bundle.
enum CommandInstaller {
    static var script: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/fwd")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var binDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
    }

    static var link: URL { binDir.appendingPathComponent("fwd") }

    /// Homebrew links the command itself, and an unbundled dev run has no script.
    static var isOffered: Bool {
        script != nil && !Bundle.main.bundleURL.resolvingSymlinksInPath().pathComponents.contains("Cellar")
    }

    static var isInstalled: Bool {
        guard let script, let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return false
        }
        return URL(fileURLWithPath: destination).standardizedFileURL == script.standardizedFileURL
    }

    static var binDirOnPath: Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { $0 == binDir.path }
            || loginShellPathContainsBinDir
    }

    /// The app's own PATH is the bare launchd one, so ask the login shell.
    private static let loginShellPathContainsBinDir: Bool = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "echo $PATH"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self)
        return path.split(whereSeparator: { $0 == ":" || $0 == " " || $0.isNewline })
            .contains { $0 == CommandInstaller.binDir.path }
    }()

    static func install() throws {
        guard let script else { return }
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Row {
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
        var y: CGFloat = 0
        var height: CGFloat = 0
        var width: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
                x = 0
            }
            row.items.append((index, x, size))
            row.height = max(row.height, size.height)
            row.width = x + size.width
            x += size.width + spacing
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
