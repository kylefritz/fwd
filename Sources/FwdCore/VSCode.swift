import Foundation

/// One-click VS Code: open a Remote-SSH window on a host.
///
/// Nothing is forwarded for this. The Remote-SSH extension makes its own ssh
/// connection from the host's name in ~/.ssh/config; fwd only asks the
/// editor's command line to open the window.
public enum VSCode {
    public struct Editor: Equatable, Sendable {
        public let name: String
        public let bundleID: String
        /// The command line inside the app bundle, under Contents/Resources/app/bin.
        public let command: String
    }

    /// Checked in order; the first one installed is used. Cursor and Insiders
    /// are VS Code underneath and take the same `--remote` argument.
    public static let editors = [
        Editor(name: "VS Code", bundleID: "com.microsoft.VSCode", command: "code"),
        Editor(name: "VS Code Insiders", bundleID: "com.microsoft.VSCodeInsiders", command: "code-insiders"),
        Editor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", command: "cursor"),
    ]

    /// The bundle's own copy of the command line. A menu bar app doesn't get
    /// the login shell's PATH, so `code` on the PATH can't be relied on.
    public static func commandLine(app: URL, editor: Editor) -> URL {
        app.appendingPathComponent("Contents/Resources/app/bin/\(editor.command)")
    }

    /// A new window connected to `host`, with no folder open yet.
    public static func arguments(host: String) -> [String] {
        ["--new-window", "--remote", "ssh-remote+\(host)"]
    }

    /// Asks the editor at `app` to open a Remote-SSH window on `host`. It
    /// returns once the editor has the request, before the window connects.
    public static func open(host: String, app: URL, editor: Editor) async throws {
        // The editor would read a leading dash in the authority as an option.
        guard !host.hasPrefix("-") else { throw VSCodeError.badHost(host) }
        let command = commandLine(app: app, editor: editor)
        guard FileManager.default.isExecutableFile(atPath: command.path) else {
            throw VSCodeError.noCommandLine(editor.name, command.path)
        }
        let result = await Shell.run(command.path, arguments(host: host), timeout: 20)
        guard result.ok else {
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw VSCodeError.failed(editor.name, reason.isEmpty ? "exit status \(result.status)" : reason)
        }
    }
}

public enum VSCodeError: Error, CustomStringConvertible, Equatable {
    case notInstalled
    case badHost(String)
    case noCommandLine(String, String)
    case failed(String, String)

    public var description: String {
        switch self {
        case .notInstalled:
            return "Install VS Code (or Cursor) with the Remote - SSH extension to open hosts in it."
        case .badHost(let host): return "VS Code can't open a host named \(host)."
        case .noCommandLine(let name, let path): return "\(name)'s command line isn't at \(path)."
        case .failed(let name, let reason): return "\(name) couldn't open the host: \(reason)"
        }
    }
}
