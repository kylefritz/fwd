import Foundation

/// Where fwd keeps things. Everything can be redirected for tests.
public struct Paths: Sendable {
    /// Holds ports.yaml, state.yaml and config.yaml.
    public var configDir: URL
    public var logFile: URL
    /// Passed to ssh with `-F` when set; nil means ssh's own default.
    public var sshConfigOverride: URL?
    /// Control sockets live here. Must be short: socket paths cap at 104 bytes.
    public var socketDir: URL
    public var releasesURL: URL
    /// Recent releases including prereleases, for the beta channel.
    public var releasesListURL: URL
    /// Where update checks send a ping that counts installs (see worker/).
    /// Nil sends none. Update information always comes from GitHub.
    public var statsServer: URL?

    public static let defaultStatsServer = URL(string: "https://fwd.kylefritz.co")!

    public static let repository = "kylefritz/fwd"
    public static let bundleIdentifier = "io.github.kylefritz.fwd"

    public var sshConfig: URL {
        sshConfigOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    }
    public var portsFile: URL { configDir.appendingPathComponent("ports.yaml") }
    public var stateFile: URL { configDir.appendingPathComponent("state.yaml") }
    public var preferencesFile: URL { configDir.appendingPathComponent("config.yaml") }
    /// Where the running app answers the `fwd` command line.
    public var controlSocket: URL { socketDir.appendingPathComponent("control.sock") }

    public init(configDir: URL, logFile: URL, sshConfigOverride: URL?, socketDir: URL, releasesURL: URL,
                releasesListURL: URL? = nil) {
        self.configDir = configDir
        self.logFile = logFile
        self.sshConfigOverride = sshConfigOverride
        self.socketDir = socketDir
        self.releasesURL = releasesURL
        self.releasesListURL = releasesListURL
            ?? URL(string: "https://api.github.com/repos/\(Paths.repository)/releases?per_page=30")!
    }

    /// Defaults, with `FWD_HOME`, `FWD_SSH_CONFIG`, `FWD_RELEASES_URL`,
    /// `FWD_RELEASES_LIST_URL` and `FWD_STATS_SERVER` honored so a test or a
    /// curious user can sandbox the app.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var configDir = home.appendingPathComponent(".config/fwd")
        var logFile = home.appendingPathComponent("Library/Logs/fwd/fwd.log")
        var socketDir = URL(fileURLWithPath: "/tmp/fwd-\(getuid())")
        if let override = env["FWD_HOME"], !override.isEmpty {
            let base = URL(fileURLWithPath: override)
            configDir = base.appendingPathComponent("config")
            logFile = base.appendingPathComponent("logs/fwd.log")
            socketDir = URL(fileURLWithPath: "/tmp/fwd-\(getuid())-\(shortHash(override))")
        }
        let sshConfig = env["FWD_SSH_CONFIG"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let releases = env["FWD_RELEASES_URL"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let list = env["FWD_RELEASES_LIST_URL"].flatMap(URL.init(string:))
        var paths = Paths(configDir: configDir, logFile: logFile, sshConfigOverride: sshConfig,
                          socketDir: socketDir, releasesURL: releases, releasesListURL: list)
        // An empty FWD_STATS_SERVER sends no pings.
        if let server = env["FWD_STATS_SERVER"] {
            paths.statsServer = server.isEmpty ? nil : URL(string: server)
        } else {
            paths.statsServer = defaultStatsServer
        }
        return paths
    }

    /// Short stable hash (FNV-1a), for socket file names.
    public static func shortHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }
}
