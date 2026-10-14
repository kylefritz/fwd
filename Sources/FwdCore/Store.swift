import Foundation
import Yams

/// One line of a host's history: the entry text and whether it is on.
public struct Entry: Codable, Equatable, Sendable {
    public var port: String
    public var on: Bool
    /// A short alias shown on the pill, such as `api` or `vnc`.
    public var name: String?

    public init(port: String, on: Bool = true, name: String? = nil) {
        self.port = port
        self.on = on
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Accept `port: 3000` as well as `port: "3000"`.
        if let number = try? c.decode(Int.self, forKey: .port) {
            port = String(number)
        } else {
            port = try c.decode(String.self, forKey: .port)
        }
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
        name = EntryName.clean(try c.decodeIfPresent(String.self, forKey: .name) ?? "")
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

    enum CodingKeys: String, CodingKey { case checkForUpdates = "check_for_updates" }

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? true
    }
}

private struct StateFile: Codable {
    var assigned: [String: Int] = [:]
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

    public func loadSticky() -> [String: Int] {
        guard let text = try? String(contentsOf: paths.stateFile, encoding: .utf8),
              let state = try? YAMLDecoder().decode(StateFile.self, from: text) else { return [:] }
        return state.assigned
    }

    public func saveSticky(_ assigned: [String: Int]) {
        var options = YAMLEncoder.Options()
        options.sortKeys = true
        let encoder = YAMLEncoder()
        encoder.options = options
        if let text = try? encoder.encode(StateFile(assigned: assigned)) {
            try? write(text, to: paths.stateFile)
        }
    }

    // MARK: config.yaml

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
