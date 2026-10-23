import Combine
import Foundation

/// A dotted numeric version such as `1.4.0`, with or without a leading `v`,
/// optionally a beta of it: `1.4.0-beta.7` comes after 1.3.x and before 1.4.0.
public struct Version: Comparable, Equatable, CustomStringConvertible, Sendable {
    public let parts: [Int]
    /// The beta number, or nil for a release.
    public let beta: Int?

    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("v") || s.hasPrefix("V") { s = s.dropFirst() }
        if let dash = s.firstIndex(of: "-") {
            let suffix = s[s.index(after: dash)...]
            guard suffix.hasPrefix("beta."), let n = Int(suffix.dropFirst("beta.".count)), n >= 0 else { return nil }
            beta = n
            s = s[..<dash]
        } else {
            beta = nil
        }
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
        switch (a.beta, b.beta) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        default: return false
        }
    }

    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
    public var description: String {
        parts.map(String.init).joined(separator: ".") + (beta.map { "-beta.\($0)" } ?? "")
    }
}

/// Which releases an install follows: tagged releases only, or every
/// prerelease built from main as well. Set with `update_channel` in config.yaml.
public enum UpdateChannel: String, Sendable {
    case stable
    case beta
}

/// How this copy of the app got onto the machine, which decides how it updates.
public enum InstallKind: Equatable, Sendable {
    /// Downloaded release: replaces itself.
    case release
    /// Homebrew owns the files: tell the user to `brew upgrade`.
    case homebrew
    /// Built from source (version `dev`): there is no version to compare, so
    /// it never offers a release.
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

/// A build to switch to on purpose, whether or not it's newer: a pull
/// request's preview, or back to the newest beta or release.
public enum SwitchTarget: Equatable, Sendable {
    case pullRequest(Int)
    case beta
    case stable

    /// `42`, `#42` or `pr-42`; `beta`; `stable` or `release`.
    public init?(_ text: String) {
        let word = text.lowercased()
        switch word {
        case "beta": self = .beta
        case "stable", "release": self = .stable
        default:
            var number = Substring(word)
            for prefix in ["pr-", "#"] where number.hasPrefix(prefix) { number = number.dropFirst(prefix.count) }
            guard let n = Int(number), n > 0 else { return nil }
            self = .pullRequest(n)
        }
    }

    /// The release tag the preview workflow publishes a pull request under.
    public static func tag(pullRequest: Int) -> String { "pr-\(pullRequest)" }
}

public enum SwitchError: Error, CustomStringConvertible, Equatable {
    case notSelfUpdating(String)
    case noPreview(Int)
    case failed(String)

    public var description: String {
        switch self {
        case .notSelfUpdating(let how):
            return "this copy of fwd \(how), so it can't switch builds; install the download from GitHub to try one"
        case .noPreview(let n):
            return "PR #\(n) has no preview build; it appears once the Preview check on the pull request passes"
        case .failed(let reason): return "couldn't get the build ready: \(reason)"
        }
    }
}

private struct Release: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let html_url: URL?
    let assets: [Asset]?
    let draft: Bool?
}

@MainActor
public final class Updater: ObservableObject {
    @Published public private(set) var state: UpdateState = .idle
    /// The version whose banner the user closed. A newer one shows again.
    @Published public private(set) var dismissedVersion: String?

    public let currentVersion: String
    public let kind: InstallKind
    public static let assetName = "fwd.zip"

    private let releasesURL: URL
    private let releasesListURL: URL?
    private let bundleURL: URL
    private let log: Log
    private let session: URLSession
    private let verifySignature: (URL) async -> Bool
    /// Read at every check, so editing config.yaml takes effect without a restart.
    private let channel: () -> UpdateChannel
    /// Downloads are only taken from URLs that start with this: this
    /// repository's releases.
    private let trustedDownloads: String
    /// Where each check sends a ping that counts installs (see worker/). It
    /// only ever receives; nothing about updates depends on its answer.
    private let statsServer: URL?
    private let installID: String?
    /// Read at every check, like the channel.
    private let sendStats: () -> Bool
    private let osVersion: String
    private var staged: URL?
    /// Bumped by `switchTo`, so a check that was already under way drops its
    /// result instead of replacing the build the user asked for.
    private var generation = 0
    /// Set from `switchTo` until `install()`: no checks in between.
    private var switchPending = false
    private let stagingDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fwd-update-\(UUID().uuidString.prefix(8))")

    /// `releasesURL` answers with the latest release (GitHub skips
    /// prereleases there); `releasesListURL` with all recent ones, for beta.
    public init(releasesURL: URL, releasesListURL: URL? = nil, bundleURL: URL, currentVersion: String, log: Log,
                kind: InstallKind? = nil, session: URLSession = .shared,
                verifySignature: ((URL) async -> Bool)? = nil,
                trustedDownloads: String = "https://github.com/\(Paths.repository)/releases/download/",
                statsServer: URL? = nil, installID: String? = nil,
                osVersion: String = Updater.systemVersion,
                sendStats: @escaping () -> Bool = { true },
                channel: @escaping () -> UpdateChannel = { .stable }) {
        self.trustedDownloads = trustedDownloads
        self.statsServer = statsServer
        self.installID = installID
        self.osVersion = osVersion
        self.sendStats = sendStats
        self.releasesURL = releasesURL
        self.releasesListURL = releasesListURL
        self.channel = channel
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

    /// Whether the user closed the banner for the version now on offer.
    public var bannerDismissed: Bool {
        switch state {
        case .available(let version, _), .ready(let version, _), .manual(let version, _, _):
            return version == dismissedVersion
        default:
            return false
        }
    }

    /// Hides the banner for the version it currently offers.
    public func dismissBanner() {
        switch state {
        case .available(let version, _), .ready(let version, _), .manual(let version, _, _):
            dismissedVersion = version
        default:
            break
        }
    }

    /// Asks GitHub for the latest release and prepares it if it's newer.
    /// Network trouble is logged and otherwise ignored; the next check retries.
    public func check() async {
        guard !switchPending else { return }
        let token = generation
        let before = state
        // Keep a waiting "Restart to update" on screen while re-checking.
        if case .ready = before {} else { state = .checking }
        // Homebrew only ships tagged releases, so a beta there could never
        // be installed; only a self-updating copy follows the beta channel.
        let beta = kind == .release && channel() == .beta && releasesListURL != nil
        // Separate from the check, so it can never hold it up or change it.
        Task { await self.ping(beta: beta) }
        do {
            let (release, latest) = try await newestRelease(beta: beta)
            guard token == generation else { return }
            log.write("update check\(beta ? " (beta)" : ""): latest is \(latest), running \(currentVersion)")

            switch kind {
            case .source:
                state = .upToDate
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
                // Already downloaded and verified: nothing more to do.
                if case .ready(let version, _) = before, Version(version) == latest, staged != nil {
                    state = before
                    return
                }
                await prepare(release, version: latest, fallback: before, token: token)
            }
        } catch {
            log.write("update check failed: \(error.localizedDescription)")
            state = (before == .checking) ? .idle : before
        }
    }

    public nonisolated static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Counts this install: version, channel, kind and macOS version, under
    /// a random install ID. Failures are ignored.
    private func ping(beta: Bool) async {
        guard let statsServer, sendStats() else { return }
        var request = URLRequest(url: statsServer.appendingPathComponent("v1/ping"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        for (name, value) in [("X-Fwd-Install", installID ?? ""), ("X-Fwd-Version", currentVersion),
                              ("X-Fwd-Channel", beta ? "beta" : "stable"), ("X-Fwd-Kind", "\(kind)"),
                              ("X-Fwd-OS", osVersion)] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // Never follow a redirect: a rule on the domain could otherwise send
        // these details anywhere.
        _ = try? await get(request, expecting: 204, delegate: NoRedirects())
    }

    private func fetchReleases(beta: Bool) async throws -> Data {
        var request = URLRequest(url: beta ? releasesListURL! : releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        return try await get(request)
    }

    private func get(_ request: URLRequest, expecting status: Int = 200,
                     delegate: (any URLSessionTaskDelegate)? = nil) async throws -> Data {
        var request = request
        request.setValue("fwd/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request, delegate: delegate)
        guard (response as? HTTPURLResponse)?.statusCode == status else { throw URLError(.badServerResponse) }
        return data
    }

    /// The latest release, or on beta the newest published one of any kind.
    private func newestRelease(beta: Bool) async throws -> (Release, Version) {
        let data = try await fetchReleases(beta: beta)
        let candidates = beta
            ? try JSONDecoder().decode([Release].self, from: data).filter { $0.draft != true }
            : [try JSONDecoder().decode(Release.self, from: data)]
        let versioned = candidates.compactMap { release in Version(release.tag_name).map { (release, $0) } }
        guard let newest = versioned.max(by: { $0.1 < $1.1 }) else { throw URLError(.cannotParseResponse) }
        return newest
    }

    /// If a newer version is already installed by Homebrew, offers the
    /// restart. Cheap and offline, so the app calls it whenever its panel opens.
    public func noticeHomebrewUpgrade() {
        guard kind == .homebrew, let running = Version(currentVersion),
              let current = Self.homebrewCurrentBundle(for: bundleURL),
              let onDisk = Self.bundleVersion(current).flatMap(Version.init), onDisk > running else { return }
        if case .ready = state { return }
        var notes: URL?
        if case .available(_, let url) = state { notes = url }
        staged = current
        state = .ready(version: onDisk.description, notes: notes)
    }

    /// Downloads and checks `release`. Its bundle must be `version`, or any
    /// version when that's nil, as for a pull request's preview.
    private func prepare(_ release: Release, version: Version?, fallback: UpdateState, token: Int) async {
        let label = version?.description ?? release.tag_name
        func manual(_ reason: String) {
            guard token == generation else { return }
            log.write("update \(label) needs a manual install: \(reason)")
            state = .manual(version: label, page: release.html_url, reason: reason)
        }
        guard FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            return manual("fwd's folder isn't writable")
        }
        guard let asset = release.assets?.first(where: { $0.name == Self.assetName }) else {
            return manual("the release has no \(Self.assetName)")
        }
        guard asset.browser_download_url.absoluteString.hasPrefix(trustedDownloads) else {
            return manual("the download isn't from \(trustedDownloads)")
        }
        do {
            // A folder per version and switch, so a ready update stays
            // installable while another one downloads. The older folder goes
            // once this one is in.
            let work = stagingDir.appendingPathComponent("\(label)-\(token)")
            try? FileManager.default.removeItem(at: work)
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
                  version == nil || packaged == version else {
                return manual("the download's version doesn't match the release")
            }
            guard await verifySignature(candidate) else {
                return manual("the download failed its signature check")
            }
            guard token == generation else { return }
            // The same version again reuses `work`, which now holds the new copy.
            if let previous = staged, previous.path.hasPrefix(stagingDir.path) {
                let folder = previous.deletingLastPathComponent().deletingLastPathComponent()
                if folder.standardizedFileURL != work.standardizedFileURL {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
            staged = candidate
            log.write("update \(label) downloaded and verified")
            state = .ready(version: packaged.description, notes: release.html_url)
        } catch {
            log.write("update download failed: \(error.localizedDescription)")
            guard token == generation else { return }
            // A ready update is untouched, so keep offering it.
            state = (fallback == .checking) ? .idle : fallback
        }
    }

    /// Readies `target` to install even when it's older than this copy, and
    /// returns its version. `install()` then puts it in place, as for an
    /// update.
    public func switchTo(_ target: SwitchTarget) async throws -> String {
        switch kind {
        case .homebrew: throw SwitchError.notSelfUpdating("is managed by Homebrew")
        case .source, .release: break
        }
        let release: Release
        var version: Version?
        do {
            switch target {
            case .pullRequest(let n):
                let tag = SwitchTarget.tag(pullRequest: n)
                var request = URLRequest(url: releasesURL.deletingLastPathComponent()
                    .appendingPathComponent("tags").appendingPathComponent(tag))
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 20
                let data: Data
                do {
                    data = try await get(request)
                } catch let error as URLError where error.code == .badServerResponse {
                    throw SwitchError.noPreview(n)  // GitHub answers 404 for a tag with no release
                }
                release = try JSONDecoder().decode(Release.self, from: data)
            case .beta, .stable:
                (release, version) = try await newestRelease(beta: target == .beta && releasesListURL != nil)
            }
        } catch let error as SwitchError {
            throw error
        } catch {
            throw SwitchError.failed(error.localizedDescription)
        }
        log.write("switching to \(release.tag_name), running \(currentVersion)")
        generation += 1
        let token = generation
        switchPending = true
        await prepare(release, version: version, fallback: .idle, token: token)
        guard token == generation else { throw SwitchError.failed("another fwd try replaced this one") }
        if case .ready = state {} else { switchPending = false }
        switch state {
        case .ready(let ready, _): return ready
        case .manual(_, _, let reason): throw SwitchError.failed(reason)
        default: throw SwitchError.failed("the download didn't finish; see the log")
        }
    }

    /// Puts the prepared version in place and returns the bundle to launch.
    /// The running app then relaunches from that path and quits.
    public func install() throws -> URL {
        defer { switchPending = false }
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

/// Answers every redirect with "no": the response is the redirect itself.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
