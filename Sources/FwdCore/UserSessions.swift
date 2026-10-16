import Foundation

/// Which hosts you have your own ssh session to right now, found by
/// reading the command lines of running `ssh` processes. fwd connects a
/// host only while one of these is open, unless an entry says keep
/// connected or you just clicked something.
public enum UserSessions {
    public static func current(paths: Paths) async -> Set<String> {
        let result = await Shell.run("/bin/ps", ["-axww", "-o", "args="], timeout: 5)
        guard result.ok else { return [] }
        return hosts(psOutput: result.stdout, socketDir: paths.socketDir.path)
    }

    /// ssh options that take a value (`ssh -p 22`, or `-p22`).
    private static let takesValue = Set("BbcDEeFIiJLlmOoPpQRSWw")

    /// Options that mean the process isn't an interactive session:
    /// config queries, control commands, and ProxyJump's stdio hop.
    private static let notASession = Set("GOQVW")

    static func hosts(psOutput: String, socketDir: String) -> Set<String> {
        var found = Set<String>()
        for line in psOutput.split(whereSeparator: \.isNewline) {
            // fwd's own masters and control commands use its socket directory.
            if line.contains(socketDir) { continue }
            let args = line.split(separator: " ").map(String.init)
            guard let program = args.first, program == "ssh" || program.hasSuffix("/ssh") else { continue }
            if let host = destination(Array(args.dropFirst())) { found.insert(host) }
        }
        return found
    }

    /// The host alias from an ssh command line, or nil if it isn't a session.
    static func destination(_ args: [String]) -> String? {
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--" { return i + 1 < args.count ? hostName(args[i + 1]) : nil }
            if arg.hasPrefix("-"), arg.count > 1 {
                var letters = arg.dropFirst()
                while let letter = letters.first {
                    letters = letters.dropFirst()
                    if notASession.contains(letter) { return nil }
                    if takesValue.contains(letter) {
                        if letters.isEmpty { i += 1 }  // the value is the next argument
                        break
                    }
                }
                i += 1
                continue
            }
            return hostName(arg)
        }
        return nil
    }

    /// `me@host` and `ssh://me@host:22` both name `host`.
    private static func hostName(_ destination: String) -> String? {
        var text = Substring(destination)
        let isURI = text.hasPrefix("ssh://")
        if isURI { text = text.dropFirst("ssh://".count) }
        if let at = text.lastIndex(of: "@") { text = text[text.index(after: at)...] }
        if isURI, let colon = text.lastIndex(of: ":") { text = text[..<colon] }
        return text.isEmpty ? nil : String(text)
    }
}
