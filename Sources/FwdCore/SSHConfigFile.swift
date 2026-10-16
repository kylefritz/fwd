import Foundation

/// Opening and seeding the user's ssh config.
public enum SSHConfigFile {
    public enum Editor: Equatable {
        /// A GUI app, opened with the file.
        case app(URL)
        /// A terminal command from `$EDITOR`, run in Terminal.
        case terminal(String)
        case textEdit
    }

    /// VS Code if it's installed, then `$EDITOR`, then TextEdit.
    public static func chooseEditor(vsCode: URL?, editor: String?) -> Editor {
        if let vsCode { return .app(vsCode) }
        if let editor = editor?.trimmingCharacters(in: .whitespaces), !editor.isEmpty { return .terminal(editor) }
        return .textEdit
    }

    /// Creates an empty config (and `~/.ssh`) with ssh's permissions if
    /// there isn't one, so there is something to open.
    public static func ensureExists(_ path: URL) throws {
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if !fm.fileExists(atPath: path.path) {
            guard fm.createFile(atPath: path.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    public static func example(user: String) -> String {
        """
        # Added by fwd as a starting point. Rename "devbox", point HostName at
        # your machine and save; fwd picks up the change right away.
        # Test it with `ssh devbox` in a terminal.
        Host devbox
          HostName devbox.example.com
          User \(user)
          # IdentityFile ~/.ssh/id_ed25519

        """
    }

    public enum ExampleError: Error, CustomStringConvertible {
        case alreadyHasHosts
        public var description: String { "Your ssh config already has hosts, so fwd left it alone." }
    }

    /// Appends the example host. Only for a config with no hosts yet, so it
    /// never touches a config someone has set up.
    public static func addExample(to path: URL, user: String) throws {
        guard SSHConfig.hosts(configPath: path).isEmpty else { throw ExampleError.alreadyHasHosts }
        try ensureExists(path)
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        var text = existing
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty { text += "\n" }
        text += example(user: user)
        // Write in place, keeping the file's permissions.
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }
}
