import Foundation

/// Whether a forward from the user's own ssh config is currently in effect.
public enum ConfigForwardStatus: Equatable, Sendable {
    /// Being forwarded (by an ssh process, or seen listening on the remote).
    case on
    case notForwarded
    /// The port is held by something that isn't the user's ssh; named here.
    case taken(String)
    /// Can't tell: fwd has no connection to that host.
    case unknown
}

public enum ConfigForwards {
    /// The forwards ssh would apply for `host`, read with `ssh -G` so that
    /// `Include` and `Match` resolve exactly as ssh resolves them.
    public static func load(host: String, paths: Paths) async -> [ConfigForward] {
        var args: [String] = []
        if let config = paths.sshConfigOverride { args += ["-F", config.path] }
        args += ["-G", "--", host]
        let result = await Shell.run(SSHConnection.sshPath, args, timeout: 10)
        guard result.ok else { return [] }
        return SSHConfig.parseForwards(sshG: result.stdout)
    }

    /// Who, if anyone, is listening on a laptop port.
    public static func localStatus(port: Int, fwdMasters: Set<Int32>) async -> ConfigForwardStatus {
        let result = await Shell.run(
            "/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"], timeout: 5)
        return interpret(lsofFields: result.stdout, fwdMasters: fwdMasters)
    }

    /// `lsof -F pc` prints `p<pid>` then `c<command>` per process.
    static func interpret(lsofFields: String, fwdMasters: Set<Int32>) -> ConfigForwardStatus {
        var pid: Int32?
        var command: String?
        for line in lsofFields.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p"), pid == nil { pid = Int32(line.dropFirst()) }
            if line.hasPrefix("c"), command == nil { command = String(line.dropFirst()) }
        }
        guard let pid else { return .notForwarded }
        if fwdMasters.contains(pid) { return .taken("fwd") }
        if command == "ssh" { return .on }
        return .taken(command ?? "pid \(pid)")
    }
}
