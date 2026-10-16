import Darwin
import Foundation

/// Which hosts you have your own ssh session to right now, found from the
/// command lines of your running `ssh` processes. fwd connects a host only
/// while one of these is open, unless an entry says keep connected or you
/// just clicked something.
public enum UserSessions {
    struct Process {
        let pid: Int32
        let ppid: Int32
        let arguments: [String]
    }

    /// Host names, lowercased: ssh matches them case-insensitively.
    public static func current(paths: Paths) async -> Set<String> {
        // Only your own processes; `comm` is the executable, so this is cheap.
        let result = await Shell.run("/bin/ps", ["-x", "-U", String(getuid()), "-o", "pid=,ppid=,comm="], timeout: 5)
        guard result.ok else { return [] }
        var processes: [Process] = []
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { continue }
            // Every process's parent is needed to spot proxy hops, but only
            // ssh processes need their arguments read.
            let isSSH = isSSHProgram(String(fields[2]))
            let arguments = isSSH ? (Self.arguments(pid: pid) ?? []) : [String(fields[2])]
            processes.append(Process(pid: pid, ppid: ppid, arguments: arguments))
        }
        return hosts(processes, socketDir: paths.socketDir.path)
    }

    static func hosts(_ processes: [Process], socketDir: String) -> Set<String> {
        let sshPIDs = Set(processes.filter { $0.arguments.first.map(isSSHProgram) == true }.map(\.pid))
        var found = Set<String>()
        for process in processes where sshPIDs.contains(process.pid) {
            // An ssh started by an ssh is a ProxyCommand or ProxyJump hop.
            if sshPIDs.contains(process.ppid) { continue }
            // fwd's own masters and control commands use its socket directory.
            if process.arguments.contains(where: { $0.contains(socketDir) }) { continue }
            if let host = destination(Array(process.arguments.dropFirst())) { found.insert(host.lowercased()) }
        }
        return found
    }

    private static func isSSHProgram(_ path: String) -> Bool { path == "ssh" || path.hasSuffix("/ssh") }

    /// A process's exact arguments, quoting and all, from the kernel.
    static func arguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        // Layout: argc, the executable path, NUL padding, then argc strings.
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var arguments: [String] = []
        while arguments.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            arguments.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return arguments
    }

    /// ssh options that take a value (`ssh -p 22`, or `-p22`).
    private static let takesValue = Set("BbcDEeFIiJLlmOoPpQRSWw")

    /// Options that mean the process isn't an interactive session:
    /// config queries, control commands, and ProxyJump's stdio hop.
    private static let notASession = Set("GOQVW")

    /// The host from an ssh command line, or nil if it isn't a session.
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
