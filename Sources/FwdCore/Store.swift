import Foundation
import Yams

/// One line of a host's history: the entry text and whether it is on.
public struct Entry: Codable, Equatable, Sendable {
    public var port: String
    public var on: Bool
    /// A short alias shown on the pill, such as `api` or `vnc`.
    public var name: String?
    /// Keep the host connected while this entry is on, reconnecting after
    /// drops, sleep and network changes. Without it fwd only connects while
    /// you have an ssh session to the host, or for a moment after a click.
    public var keep: Bool

    enum CodingKeys: String, CodingKey { case port, on, name, keep }

    public init(port: String, on: Bool = true, name: String? = nil, keep: Bool = false) {
        self.port = port
        self.on = on
        self.name = name
        self.keep = keep
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(port, forKey: .port)
        try c.encode(on, forKey: .on)
        try c.encodeIfPresent(name, forKey: .name)
        // Left out when false, so existing files don't change.
        if keep { try c.encode(true, forKey: .keep) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Accept `port: 3000` as well as `port: "3000"`.
        let raw: String
        if let number = try? c.decode(Int.self, forKey: .port) {
            raw = String(number)
        } else {
            raw = try c.decode(String.self, forKey: .port)
        }
        // In the app's own spelling (`3000->4000` is `3000 -> 4000`), since
        // that is what matching, history and saved laptop ports go by.
        port = (try? PortPattern.parse(raw).text) ?? raw
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
        name = EntryName.clean(try c.decodeIfPresent(String.self, forKey: .name) ?? "")
        keep = try c.decodeIfPresent(Bool.self, forKey: .keep) ?? false
    }
}

/// Aliases: typed after the port (`3000 api`, `3000 -> 4000 web`) or set
/// later with Rename.
public enum EntryName {
    public static let maxLength = 24

    /// Splits `3000 -> 4000 web` into the port text and the name. A name is
    /// a trailing word that starts with a letter, so `3000 -> 4000` alone
    /// has none.
    public static func split(_ text: String) -> (port: String, name: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.lastIndex(where: \.isWhitespace) else { return (trimmed, nil) }
        let word = String(trimmed[trimmed.index(after: space)...])
        guard word.first?.isLetter == true else { return (trimmed, nil) }
        return (String(trimmed[..<space]).trimmingCharacters(in: .whitespaces), clean(word))
    }

    /// A tidy name, or nil for an empty one.
    public static func clean(_ name: String) -> String? {
        let oneLine = name.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return oneLine.isEmpty ? nil : String(oneLine.prefix(maxLength))
    }
}

public struct PortsFile: Codable, Equatable, Sendable {
    public var hosts: [String: [Entry]]

    public init(hosts: [String: [Entry]] = [:]) {
        self.hosts = hosts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: [Entry]?].self, forKey: .hosts) ?? [:]
        hosts = raw.mapValues { $0 ?? [] }
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var checkForUpdates: Bool = true
    /// `beta` follows every build of main; anything else is stable.
    public var updateChannel: UpdateChannel = .stable
    /// The install-counting ping that goes with each update check. Turning
    /// it off leaves update checks alone.
    public var sendUsageStats: Bool = true

    enum CodingKeys: String, CodingKey {
        case checkForUpdates = "check_for_updates"
        case updateChannel = "update_channel"
        case sendUsageStats = "send_usage_stats"
    }

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? true
        // A typo shouldn't throw away the other settings.
        let channel = try? c.decodeIfPresent(String.self, forKey: .updateChannel)
        updateChannel = channel.flatMap { UpdateChannel(rawValue: $0.lowercased()) } ?? .stable
        sendUsageStats = (try? c.decodeIfPresent(Bool.self, forKey: .sendUsageStats)) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(checkForUpdates, forKey: .checkForUpdates)
        try c.encode(updateChannel.rawValue, forKey: .updateChannel)
        try c.encode(sendUsageStats, forKey: .sendUsageStats)
    }
}

private struct StateFile: Codable {
    var assigned: [String: Int] = [:]
    /// A random ID for this install, sent with update checks to count
    /// installs. Not derived from anything about the machine or the user.
    var install_id: String?
}

/// Reads and writes the YAML files under `~/.config/fwd`.
public final class Store {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    // MARK: ports.yaml (the user's file)

    /// A missing or empty file is an empty list. A malformed one throws, and
    /// callers must then leave both their state and the file alone.
    public func loadPorts() throws -> PortsFile {
        guard let text = try? String(contentsOf: paths.portsFile, encoding: .utf8) else {
            return PortsFile()
        }
        return try Self.decodePorts(text)
    }

    public static func decodePorts(_ text: String) throws -> PortsFile {
        guard let node = try Yams.compose(yaml: text), node != Node("", Tag(.null)) else {
            return PortsFile()
        }
        if case .scalar(let scalar) = node, scalar.string.isEmpty || scalar.string == "~" || scalar.string == "null" {
            return PortsFile()
        }
        return try YAMLDecoder().decode(PortsFile.self, from: text)
    }

    public func savePorts(_ file: PortsFile) throws {
        var options = YAMLEncoder.Options()
        options.sortKeys = true
        let encoder = YAMLEncoder()
        encoder.options = options
        try write(try encoder.encode(file), to: paths.portsFile)
    }

    public func portsModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: paths.portsFile.path))?[.modificationDate] as? Date
    }

    // MARK: state.yaml (app-owned)

    private func loadState() -> StateFile {
        guard let text = try? String(contentsOf: paths.stateFile, encoding: .utf8),
              let state = try? YAMLDecoder().decode(StateFile.self, from: text) else { return StateFile() }
        return state
    }

    private func saveState(_ state: StateFile) {
        var options = YAMLEncoder.Options()
        options.sortKeys = true
        let encoder = YAMLEncoder()
        encoder.options = options
        if let text = try? encoder.encode(state) {
            try? write(text, to: paths.stateFile)
        }
    }

    public func loadSticky() -> [String: Int] { loadState().assigned }

    public func saveSticky(_ assigned: [String: Int]) {
        var state = loadState()
        state.assigned = assigned
        saveState(state)
    }

    /// This install's random ID, made on first use.
    public func installID() -> String {
        var state = loadState()
        if let id = state.install_id { return id }
        let id = UUID().uuidString.lowercased()
        state.install_id = id
        saveState(state)
        return id
    }

    // MARK: config.yaml

    /// What a new config.yaml says: every option, commented out at its default.
    public static let preferencesTemplate = """
        # fwd settings. Uncomment a line to change it; fwd reads this file at
        # each update check, so no restart is needed.

        # Check GitHub for new versions of fwd.
        # check_for_updates: true

        # With each update check, send a ping that counts installs: a random
        # install ID, the version, channel, install kind and macOS version.
        # false keeps update checks but stops the ping.
        # send_usage_stats: true

        # stable gets tagged releases; beta gets every build of main.
        # update_channel: stable

        """

    /// Creates config.yaml from the template if there isn't one, so there is
    /// something to open. Never touches an existing file.
    public func ensurePreferencesFile() throws {
        guard !FileManager.default.fileExists(atPath: paths.preferencesFile.path) else { return }
        try write(Self.preferencesTemplate, to: paths.preferencesFile)
    }

    public func loadPreferences() -> Preferences {
        guard let text = try? String(contentsOf: paths.preferencesFile, encoding: .utf8),
              let prefs = try? YAMLDecoder().decode(Preferences.self, from: text) else {
            return Preferences()
        }
        return prefs
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
