import Foundation

/// One-click Screen Sharing: forward a host's VNC port and open it.
public enum ScreenSharing {
    /// Where macOS Screen Sharing (and most VNC servers) listen.
    public static let remotePort = 5900
    /// The laptop's own Screen Sharing holds 5900 when it's turned on, so
    /// the forward starts one above it. A second host bumps to 5902.
    public static let laptopPort = 5901
    public static let entryText = "\(remotePort) -> \(laptopPort)"
    public static let entryName = "vnc"

    /// VNC display :N listens on 5900+N.
    public static let vncPorts = 5900...5909

    /// What opens a forwarded port: the Screen Sharing app for VNC ports,
    /// the browser for everything else.
    public static func url(remote: Int, local: Int) -> URL {
        let scheme = vncPorts.contains(remote) ? "vnc" : "http"
        return URL(string: "\(scheme)://localhost:\(local)")!
    }

    /// `vnc://user@localhost:port`. The macOS Screen Sharing app opens it,
    /// with the user name filled in.
    public static func url(local: Int, user: String?) -> URL {
        var parts = URLComponents()
        parts.scheme = "vnc"
        parts.user = user
        parts.host = "localhost"
        parts.port = local
        return parts.url!
    }

    /// The `User` ssh would log in as, which is usually the account to
    /// sign in to the screen with too.
    public static func user(host: String, paths: Paths) async -> String? {
        var args: [String] = []
        if let config = paths.sshConfigOverride { args += ["-F", config.path] }
        args += ["-G", "--", host]
        let result = await Shell.run(SSHConnection.sshPath, args, timeout: 10)
        guard result.ok else { return nil }
        return user(sshG: result.stdout)
    }

    static func user(sshG: String) -> String? {
        for line in sshG.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1)
            if fields.count == 2, fields[0] == "user" { return String(fields[1]) }
        }
        return nil
    }
}

public enum ScreenSharingError: Error, CustomStringConvertible, Equatable {
    case hostProblem(String)
    case notSharing(String)
    case blocked(String)
    case timedOut(String)

    public var description: String {
        switch self {
        case .hostProblem(let message): return message
        case .notSharing(let host):
            return "Nothing is listening on port 5900 on \(host). Turn on Screen Sharing there "
                + "(System Settings → General → Sharing) and try again."
        case .blocked(let reason): return "Couldn't forward Screen Sharing: \(reason)"
        case .timedOut(let host): return "Couldn't reach \(host) yet. fwd will keep trying; click again once it connects."
        }
    }
}
