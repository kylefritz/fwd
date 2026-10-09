import Combine
import Foundation

/// A dotted numeric version such as `1.4.0`, with or without a leading `v`.
public struct Version: Comparable, Equatable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("v") || s.hasPrefix("V") { s = s.dropFirst() }
        let pieces = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard let n = Int(piece), n >= 0 else { return nil }
            parts.append(n)
        }
        self.parts = parts
    }

    public static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// How this copy of the app got onto the machine, which decides how it updates.
public enum InstallKind: Equatable, Sendable {
    /// Downloaded release: replaces itself.
    case release
    /// Homebrew owns the files: tell the user to `brew upgrade`.
    case homebrew
    /// Built from source (version `dev`): only mention that a release exists.
    case source
}

public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    /// A newer release exists but this install doesn't replace itself.
    case available(version: String, notes: URL?)
    /// The new version is on disk and verified; restarting switches to it.
    case ready(version: String, notes: URL?)
    /// A newer release exists but couldn't be installed automatically.
    case manual(version: String, page: URL?, reason: String)
}

private struct Release: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let html_url: URL?
    let assets: [Asset]?
}

@MainActor
public final class Updater: ObservableObject {
    @Published public private(set) var state: UpdateState = .idle

    public let currentVersion: String
    public let kind: InstallKind
    public static let assetName = "fwd.zip"

    private let releasesURL: URL
    private let bundleURL: URL
    private let log: Log
    private let session: URLSession
    private let verifySignature: (URL) async -> Bool
    private var staged: URL?

    public init(releasesURL: URL, bundleURL: URL, currentVersion: String, log: Log,
                kind: InstallKind? = nil, session: URLSession = .shared,
                verifySignature: ((URL) async -> Bool)? = nil) {
        self.releasesURL = releasesURL
        self.bundleURL = bundleURL
        self.currentVersion = currentVersion
        self.log = log
        self.kind = kind ?? Self.detectKind(bundleURL: bundleURL, version: currentVersion)
        self.session = session
        self.verifySignature = verifySignature ?? Self.codesignVerifies
    }

    public static func detectKind(bundleURL: URL, version: String) -> InstallKind {
        if bundleURL.resolvingSymlinksInPath().pathComponents.contains("Cellar") { return .homebrew }
        if Version(version) == nil { return .source }
        return .release
    }

    /// For a Homebrew install, the stable path that always points at the
    /// newest installed version: `<prefix>/opt/fwd/fwd.app`.
    public static func homebrewCurrentBundle(for bundleURL: URL) -> URL? {
        let parts = bundleURL.resolvingSymlinksInPath().pathComponents
        guard let cellar = parts.firstIndex(of: "Cellar"), cellar + 1 < parts.count else { return nil }
        let prefix = NSString.path(withComponents: Array(parts[..<cellar]))
        return URL(fileURLWithPath: prefix)
            .appendingPathComponent("opt").appendingPathComponent(parts[cellar + 1])
            .appendingPathComponent(bundleURL.lastPathComponent)
    }

    public static func bundleVersion(_ bundle: URL) -> String? {
        info(bundle)?["CFBundleShortVersionString"] as? String
    }

    private static func info(_ bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func codesignVerifies(_ bundle: URL) async -> Bool {
        await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path], timeout: 30).ok
    }

    /// Asks GitHub for the latest release and prepares it if it's newer.
    /// Network trouble is logged and otherwise ignored; the next check retries.
    public func check() async {
        let before = state
        state = .checking
        do {
            var request = URLRequest(url: releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let latest = Version(release.tag_name) else {
                throw URLError(.cannotParseResponse)
            }
            log.write("update check: latest is \(latest), running \(currentVersion)")

            switch kind {
            case .source:
                state = .available(version: latest.description, notes: release.html_url)
            case .homebrew:
                guard let running = Version(currentVersion), latest > running else {
                    state = .upToDate
                    return
                }
                // `brew upgrade` may already have put the new version on disk.
                if let current = Self.homebrewCurrentBundle(for: bundleURL),
                   let onDisk = Self.bundleVersion(current).flatMap(Version.init), onDisk > running {
                    staged = current
                    state = .ready(version: onDisk.description, notes: release.html_url)
                } else {
                    state = .available(version: latest.description, notes: release.html_url)
                }
            case .release:
                guard let running = Version(currentVersion), latest > running else {
                    state = .upToDate
                    return
                }
                await prepare(release, version: latest)
            }
        } catch {
            log.write("update check failed: \(error.localizedDescription)")
            state = (before == .checking) ? .idle : before
        }
    }

    private func prepare(_ release: Release, version: Version) async {
        func manual(_ reason: String) {
            log.write("update \(version) needs a manual install: \(reason)")
            state = .manual(version: version.description, page: release.html_url, reason: reason)
        }
        guard FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            return manual("fwd's folder isn't writable")
        }
        guard let asset = release.assets?.first(where: { $0.name == Self.assetName }) else {
            return manual("the release has no \(Self.assetName)")
        }
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, response) = try await session.download(from: asset.browser_download_url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let zip = work.appendingPathComponent(Self.assetName)
            try FileManager.default.moveItem(at: downloaded, to: zip)
            let unpacked = work.appendingPathComponent("unpacked")
            guard await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], timeout: 60).ok else {
                return manual("the download couldn't be unpacked")
            }
            let candidate = unpacked.appendingPathComponent(bundleURL.lastPathComponent)
            guard let info = Self.info(candidate),
                  info["CFBundleIdentifier"] as? String == Paths.bundleIdentifier else {
                return manual("the download isn't fwd")
            }
            guard let packaged = (info["CFBundleShortVersionString"] as? String).flatMap(Version.init),
                  packaged == version else {
                return manual("the download's version doesn't match the release")
            }
            guard await verifySignature(candidate) else {
                return manual("the download failed its signature check")
            }
            staged = candidate
            log.write("update \(version) downloaded and verified")
            state = .ready(version: version.description, notes: release.html_url)
        } catch {
            log.write("update download failed: \(error.localizedDescription)")
            state = .idle
        }
    }

    /// Puts the prepared version in place and returns the bundle to launch.
    /// The running app then relaunches from that path and quits.
    public func install() throws -> URL {
        guard case .ready = state, let staged else { throw UpdateError.nothingReady }
        if kind == .homebrew { return staged }
        try Self.swap(newBundle: staged, into: bundleURL)
        log.write("update installed at \(bundleURL.path)")
        return bundleURL
    }

    public enum UpdateError: Error { case nothingReady }

    /// Replaces `current` with `newBundle`, restoring the original if the
    /// move fails partway.
    public static func swap(newBundle: URL, into current: URL) throws {
        let fm = FileManager.default
        let backup = current.deletingLastPathComponent()
            .appendingPathComponent(".\(current.lastPathComponent).old-\(UUID().uuidString.prefix(8))")
        try fm.moveItem(at: current, to: backup)
        do {
            try fm.moveItem(at: newBundle, to: current)
        } catch {
            try? fm.moveItem(at: backup, to: current)
            throw error
        }
        try? fm.removeItem(at: backup)
    }
}
