import Foundation
import Testing
@testable import FwdCore

/// A tiny HTTP server standing in for GitHub.
final class TestHTTPServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var routes: [String: (status: Int, body: Data, headers: String)] = [:]
    private(set) var hits: [String] = []
    /// Each request's full text, headers included.
    private(set) var requests: [String] = []

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { throw TestFailure("http server couldn't listen") }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = Int(in_port_t(bigEndian: actual.sin_port))
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                self?.serve(client)
            }
        }
    }

    func route(_ path: String, status: Int = 200, body: Data, headers: [String: String] = [:]) {
        lock.lock()
        routes[path] = (status, body, headers.map { "\($0.key): \($0.value)\r\n" }.joined())
        lock.unlock()
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = read(client, &buffer, buffer.count)
        guard n > 0 else { return }
        let request = String(decoding: buffer[0..<n], as: UTF8.self)
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        lock.lock()
        hits.append(path)
        requests.append(request)
        let route = routes[path]
        lock.unlock()
        let status = route?.status ?? 404
        let body = route?.body ?? Data()
        var response = Data("HTTP/1.1 \(status) X\r\n\(route?.headers ?? "")Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        response.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let w = write(client, raw.baseAddress! + sent, raw.count - sent)
                if w <= 0 { return }
                sent += w
            }
        }
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}

@MainActor
@Suite struct UpdaterTests {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-upd-\(UUID().uuidString)")

    /// Makes a minimal `fwd.app` with the given identity.
    func makeBundle(in dir: URL, version: String, identifier: String = Paths.bundleIdentifier, marker: String = "") throws -> URL {
        let app = dir.appendingPathComponent("fwd.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try marker.write(to: app.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
        return app
    }

    func zip(_ app: URL) async throws -> Data {
        let out = app.deletingLastPathComponent().appendingPathComponent("fwd.zip")
        let result = await Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, out.path])
        guard result.ok else { throw TestFailure("ditto failed: \(result.stderr)") }
        return try Data(contentsOf: out)
    }

    func releaseJSON(tag: String, server: TestHTTPServer, withAsset: Bool = true) -> Data {
        let assets = withAsset
            ? "[{\"name\": \"fwd.zip\", \"browser_download_url\": \"\(server.url("/fwd.zip"))\"}]" : "[]"
        return Data("{\"tag_name\": \"\(tag)\", \"html_url\": \"https://example.com/notes\", \"assets\": \(assets)}".utf8)
    }

    func updater(_ server: TestHTTPServer, installed: URL, version: String, kind: InstallKind? = .release,
                 signatureOK: Bool = true) -> Updater {
        Updater(releasesURL: server.url("/latest"), bundleURL: installed, currentVersion: version,
                log: Log(file: work.appendingPathComponent("log")), kind: kind,
                verifySignature: { _ in signatureOK }, trustedDownloads: server.url("/").absoluteString)
    }

    @Test func versionOrdering() {
        #expect(Version("v1.2.3")! > Version("1.2.2")!)
        #expect(Version("1.10.0")! > Version("1.9.9")!)
        #expect(Version("2")! > Version("1.99")!)
        #expect(Version("1.2")! == Version("1.2.0")!)
        #expect(!(Version("1.2.0")! > Version("v1.2")!))
        #expect(Version("dev") == nil)
        #expect(Version("") == nil)
        #expect(Version("1.x") == nil)
        #expect(Version("1..2") == nil)
        #expect(Version("-1") == nil)
    }

    @Test func betaVersionsSortBeforeTheirRelease() {
        #expect(Version("v0.1.1-beta.57")!.description == "0.1.1-beta.57")
        #expect(Version("0.1.1-beta.57")! > Version("0.1.0")!)
        #expect(Version("0.1.1-beta.57")! < Version("0.1.1")!, "the release replaces its betas")
        #expect(Version("0.1.1-beta.58")! > Version("0.1.1-beta.57")!)
        #expect(Version("0.1.1-beta.9")! < Version("0.1.1-beta.10")!)
        #expect(Version("0.1.2-beta.1")! > Version("0.1.1")!)
        #expect(Version("0.1.1-beta")  == nil)
        #expect(Version("0.1.1-rc.1") == nil)
    }

    func listJSON(_ releases: [(tag: String, prerelease: Bool, draft: Bool)], server: TestHTTPServer) -> Data {
        let items = releases.map {
            "{\"tag_name\": \"\($0.tag)\", \"prerelease\": \($0.prerelease), \"draft\": \($0.draft), "
                + "\"html_url\": \"https://example.com/\($0.tag)\", "
                + "\"assets\": [{\"name\": \"fwd.zip\", \"browser_download_url\": \"\(server.url("/fwd.zip"))\"}]}"
        }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }

    @Test func theBetaChannelTakesTheNewestReleaseOfAnyKind() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "0.1.0")
        let beta = try makeBundle(in: work.appendingPathComponent("build"), version: "0.1.1-beta.58")
        server.route("/latest", body: releaseJSON(tag: "v0.1.0", server: server))
        server.route("/list", body: listJSON([
            ("v0.1.1-beta.59", true, true),  // a draft isn't published
            ("v0.1.1-beta.58", true, false),
            ("v0.1.1-beta.57", true, false),
            ("v0.1.0", false, false),
        ], server: server))
        server.route("/fwd.zip", body: try await zip(beta))

        var channel = UpdateChannel.stable
        let u = Updater(releasesURL: server.url("/latest"), releasesListURL: server.url("/list"),
                        bundleURL: installed, currentVersion: "0.1.0",
                        log: Log(file: work.appendingPathComponent("log")), kind: .release,
                        verifySignature: { _ in true }, trustedDownloads: server.url("/").absoluteString, channel: { channel })
        await u.check()
        #expect(u.state == .upToDate, "stable ignores prereleases")
        #expect(!server.hits.contains("/list"))

        channel = .beta
        await u.check()
        #expect(u.state == .ready(version: "0.1.1-beta.58", notes: URL(string: "https://example.com/v0.1.1-beta.58")))
        _ = try u.install()
        #expect(Updater.bundleVersion(installed) == "0.1.1-beta.58")
    }

    @Test func homebrewIgnoresTheBetaChannel() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Cellar/fwd/0.1.0"), version: "0.1.0")
        server.route("/latest", body: releaseJSON(tag: "v0.1.0", server: server))
        server.route("/list", body: listJSON([("v0.1.1-beta.3", true, false)], server: server))
        let u = Updater(releasesURL: server.url("/latest"), releasesListURL: server.url("/list"),
                        bundleURL: installed, currentVersion: "0.1.0",
                        log: Log(file: work.appendingPathComponent("log")), kind: .homebrew,
                        channel: { .beta })
        await u.check()
        #expect(u.state == .upToDate, "brew can't install a beta, so don't offer one")
        #expect(!server.hits.contains("/list"))
    }

    @Test func aBetaUserMovesOntoTheRelease() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "0.1.1-beta.58")
        let release = try makeBundle(in: work.appendingPathComponent("build"), version: "0.1.1")
        server.route("/list", body: listJSON([("v0.1.1", false, false), ("v0.1.1-beta.58", true, false)], server: server))
        server.route("/fwd.zip", body: try await zip(release))
        let u = Updater(releasesURL: server.url("/latest"), releasesListURL: server.url("/list"),
                        bundleURL: installed, currentVersion: "0.1.1-beta.58",
                        log: Log(file: work.appendingPathComponent("log")), kind: .release,
                        verifySignature: { _ in true }, trustedDownloads: server.url("/").absoluteString, channel: { .beta })
        await u.check()
        #expect(u.state == .ready(version: "0.1.1", notes: URL(string: "https://example.com/v0.1.1")))
    }

    @Test func theChannelIsReadFromConfig() throws {
        let store = Store(paths: tempPaths())
        try FileManager.default.createDirectory(at: store.paths.configDir, withIntermediateDirectories: true)
        func channel(_ yaml: String) throws -> UpdateChannel {
            try yaml.write(to: store.paths.preferencesFile, atomically: true, encoding: .utf8)
            return store.loadPreferences().updateChannel
        }
        #expect(try channel("update_channel: beta\n") == .beta)
        #expect(try channel("check_for_updates: true\n") == .stable)
        #expect(try channel("update_channel: nightly\n") == .stable, "an unknown channel falls back to stable")
        #expect(try store.loadPreferences().sendUsageStats == true, "on unless turned off")
        try "send_usage_stats: false\n".write(to: store.paths.preferencesFile, atomically: true, encoding: .utf8)
        #expect(store.loadPreferences().sendUsageStats == false)
        #expect(store.loadPreferences().checkForUpdates == true)
    }

    @Test func installKindDetection() {
        #expect(Updater.detectKind(bundleURL: URL(fileURLWithPath: "/Applications/fwd.app"), version: "1.0.0") == .release)
        #expect(Updater.detectKind(bundleURL: URL(fileURLWithPath: "/Applications/fwd.app"), version: "dev") == .source)
        let brew = URL(fileURLWithPath: "/opt/homebrew/Cellar/fwd/1.0.0/fwd.app")
        #expect(Updater.detectKind(bundleURL: brew, version: "1.0.0") == .homebrew)
        #expect(Updater.homebrewCurrentBundle(for: brew)?.path == "/opt/homebrew/opt/fwd/fwd.app")
    }

    // MARK: Counting installs

    func counted(_ github: TestHTTPServer, installed: URL, stats: TestHTTPServer) -> Updater {
        Updater(releasesURL: github.url("/latest"), releasesListURL: github.url("/list"),
                bundleURL: installed, currentVersion: "1.0.0",
                log: Log(file: work.appendingPathComponent("log")), kind: .release,
                verifySignature: { _ in true }, trustedDownloads: github.url("/").absoluteString,
                statsServer: stats.url("/"), installID: "test-install", osVersion: "26.1")
    }

    @Test func eachCheckPingsTheStatsServerAndAsksGitHubDirectly() async throws {
        let github = try TestHTTPServer()
        let stats = try TestHTTPServer()
        defer { github.stop(); stats.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "1.0.0")
        github.route("/latest", body: releaseJSON(tag: "v1.0.0", server: github))
        stats.route("/v1/ping", status: 204, body: Data())
        let u = counted(github, installed: installed, stats: stats)
        await u.check()
        #expect(u.state == .upToDate)
        #expect(github.hits.contains("/latest"), "release info always comes from GitHub")
        try await eventually("pinged") { !stats.requests.isEmpty }
        let ping = try #require(stats.requests.first).lowercased()
        #expect(ping.hasPrefix("post /v1/ping "))
        #expect(ping.contains("x-fwd-install: test-install"))
        #expect(ping.contains("x-fwd-version: 1.0.0"))
        #expect(ping.contains("x-fwd-channel: stable"))
        #expect(ping.contains("x-fwd-os: 26.1"))
        #expect(!(github.requests.first ?? "").lowercased().contains("x-fwd-install"),
                "install info only goes to the stats server")
    }

    @Test func turningStatsOffKeepsUpdateChecks() async throws {
        let github = try TestHTTPServer()
        let stats = try TestHTTPServer()
        defer { github.stop(); stats.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "1.0.0")
        github.route("/latest", body: releaseJSON(tag: "v1.0.0", server: github))
        stats.route("/v1/ping", status: 204, body: Data())
        let u = Updater(releasesURL: github.url("/latest"), bundleURL: installed, currentVersion: "1.0.0",
                        log: Log(file: work.appendingPathComponent("log")), kind: .release,
                        statsServer: stats.url("/"), installID: "test-install", sendStats: { false })
        await u.check()
        #expect(u.state == .upToDate)
        #expect(github.hits.contains("/latest"))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(stats.requests.isEmpty)
    }

    @Test func aPingNeverFollowsARedirect() async throws {
        let github = try TestHTTPServer()
        let stats = try TestHTTPServer()
        let elsewhere = try TestHTTPServer()
        defer { github.stop(); stats.stop(); elsewhere.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "1.0.0")
        github.route("/latest", body: releaseJSON(tag: "v1.0.0", server: github))
        // A redirect rule on the domain sends everything somewhere else.
        stats.route("/v1/ping", status: 302, body: Data(), headers: ["Location": elsewhere.url("/profile").absoluteString])
        elsewhere.route("/profile", body: Data("hi".utf8))
        await counted(github, installed: installed, stats: stats).check()
        try await eventually("pinged") { !stats.requests.isEmpty }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(elsewhere.requests.isEmpty, "install details must not go wherever a redirect points")
    }

    @Test func aDownStatsServerChangesNothing() async throws {
        let github = try TestHTTPServer()
        let stats = try TestHTTPServer()
        defer { github.stop() }
        stats.stop()
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "1.0.0")
        let next = try makeBundle(in: work.appendingPathComponent("build"), version: "1.1.0")
        github.route("/latest", body: releaseJSON(tag: "v1.1.0", server: github))
        github.route("/fwd.zip", body: try await zip(next))
        let u = counted(github, installed: installed, stats: stats)
        await u.check()
        #expect(u.state == .ready(version: "1.1.0", notes: URL(string: "https://example.com/notes")))
    }

    @Test func downloadsOnlyComeFromThisRepositorysReleases() async throws {
        let github = try TestHTTPServer()
        let elsewhere = try TestHTTPServer()
        defer { github.stop(); elsewhere.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "1.0.0")
        github.route("/latest", body: releaseJSON(tag: "v1.1.0", server: elsewhere))
        let u = updater(github, installed: installed, version: "1.0.0")
        await u.check()
        guard case .manual(_, _, let reason) = u.state else {
            Issue.record("expected a manual install, got \(u.state)")
            return
        }
        #expect(reason.contains("isn't from"))
        #expect(!elsewhere.hits.contains("/fwd.zip"))
    }

    @Test func aReadyUpdateStaysInstallableWhileANewerOneFails() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "1.0.0", marker: "old")
        let next = try makeBundle(in: work.appendingPathComponent("build"), version: "1.1.0", marker: "new")
        server.route("/latest", body: releaseJSON(tag: "v1.1.0", server: server))
        server.route("/fwd.zip", body: try await zip(next))
        let u = updater(server, installed: installed, version: "1.0.0")
        await u.check()
        #expect(u.state == .ready(version: "1.1.0", notes: URL(string: "https://example.com/notes")))

        // 1.2.0 comes out, but its download fails.
        server.route("/latest", body: releaseJSON(tag: "v1.2.0", server: server))
        server.route("/fwd.zip", status: 500, body: Data())
        await u.check()
        #expect(u.state == .ready(version: "1.1.0", notes: URL(string: "https://example.com/notes")))
        _ = try u.install()
        #expect(Updater.bundleVersion(installed) == "1.1.0")
    }

    @Test func newerReleaseIsDownloadedVerifiedAndSwappedIn() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "1.0.0", marker: "old")
        let next = try makeBundle(in: work.appendingPathComponent("build"), version: "1.1.0", marker: "new")
        server.route("/latest", body: releaseJSON(tag: "v1.1.0", server: server))
        server.route("/fwd.zip", body: try await zip(next))

        let u = updater(server, installed: installed, version: "1.0.0")
        await u.check()
        #expect(u.state == .ready(version: "1.1.0", notes: URL(string: "https://example.com/notes")))
        // Nothing is replaced until the user says so.
        #expect(Updater.bundleVersion(installed) == "1.0.0")

        // Checking again must neither download again nor hide the offer.
        await u.check()
        #expect(u.state == .ready(version: "1.1.0", notes: URL(string: "https://example.com/notes")))
        #expect(server.hits.filter { $0 == "/fwd.zip" }.count == 1)

        let launch = try u.install()
        #expect(launch == installed)
        #expect(Updater.bundleVersion(installed) == "1.1.0")
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8) == "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        #expect(leftovers == ["fwd.app"])
    }

    @Test(arguments: ["v1.0.0", "v0.9.0", "1.0"])
    func sameOrOlderReleaseIsUpToDate(_ tag: String) async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent(tag), version: "1.0.0")
        server.route("/latest", body: releaseJSON(tag: tag, server: server))
        let u = updater(server, installed: installed, version: "1.0.0")
        await u.check()
        #expect(u.state == .upToDate)
        #expect(!server.hits.contains("/fwd.zip"))
    }

    @Test func downloadsThatFailAnyCheckAreNotInstalled() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "1.0.0", marker: "old")
        server.route("/latest", body: releaseJSON(tag: "v1.1.0", server: server))

        func expectManual(_ u: Updater, _ what: String) async {
            await u.check()
            guard case .manual = u.state else {
                Issue.record("\(what): expected manual, got \(u.state)")
                return
            }
            #expect(throws: Updater.UpdateError.self) { try u.install() }
        }

        let wrongApp = try makeBundle(in: work.appendingPathComponent("a"), version: "1.1.0", identifier: "com.evil.app")
        server.route("/fwd.zip", body: try await zip(wrongApp))
        await expectManual(updater(server, installed: installed, version: "1.0.0"), "wrong bundle id")

        let wrongVersion = try makeBundle(in: work.appendingPathComponent("b"), version: "9.9.9")
        server.route("/fwd.zip", body: try await zip(wrongVersion))
        await expectManual(updater(server, installed: installed, version: "1.0.0"), "version mismatch")

        let good = try makeBundle(in: work.appendingPathComponent("c"), version: "1.1.0")
        server.route("/fwd.zip", body: try await zip(good))
        await expectManual(updater(server, installed: installed, version: "1.0.0", signatureOK: false), "bad signature")

        server.route("/fwd.zip", body: Data("this is not a zip".utf8))
        await expectManual(updater(server, installed: installed, version: "1.0.0"), "corrupt zip")

        server.route("/latest", body: releaseJSON(tag: "v1.1.0", server: server, withAsset: false))
        await expectManual(updater(server, installed: installed, version: "1.0.0"), "no asset")

        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8) == "old")
    }

    @Test func unwritableFolderOffersTheReleasePageInstead() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let dir = work.appendingPathComponent("locked")
        let installed = try makeBundle(in: dir, version: "1.0.0")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        server.route("/latest", body: releaseJSON(tag: "v2.0.0", server: server))
        let u = updater(server, installed: installed, version: "1.0.0")
        await u.check()
        guard case .manual(let version, let page, _) = u.state else {
            Issue.record("expected manual, got \(u.state)")
            return
        }
        #expect(version == "2.0.0")
        #expect(page != nil)
        #expect(!server.hits.contains("/fwd.zip"))
    }

    @Test func networkTroubleIsQuiet() async throws {
        let server = try TestHTTPServer()
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "1.0.0")
        server.route("/latest", status: 403, body: Data("rate limited".utf8))
        let u = updater(server, installed: installed, version: "1.0.0")
        await u.check()
        #expect(u.state == .idle)
        server.route("/latest", body: Data("{not json".utf8))
        await u.check()
        #expect(u.state == .idle)
        server.stop()
        await u.check()
        #expect(u.state == .idle)
    }

    @Test func sourceBuildsNeverOfferARelease() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "dev")
        server.route("/latest", body: releaseJSON(tag: "v1.0.0", server: server))
        let u = updater(server, installed: installed, version: "dev", kind: nil)
        #expect(u.kind == .source)
        await u.check()
        #expect(u.state == .upToDate)
        #expect(!server.hits.contains("/fwd.zip"))
        #expect(throws: Updater.UpdateError.self) { try u.install() }
    }

    @Test func dismissingTheBannerHidesOnlyThatVersion() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let prefix = work.appendingPathComponent("brew")
        let running = try makeBundle(in: prefix.appendingPathComponent("Cellar/fwd/1.0.0"), version: "1.0.0")
        server.route("/latest", body: releaseJSON(tag: "v1.1.0", server: server))
        let u = updater(server, installed: running, version: "1.0.0", kind: nil)
        await u.check()
        #expect(u.dismissedVersion == nil)
        u.dismissBanner()
        #expect(u.dismissedVersion == "1.1.0")
        #expect(u.bannerDismissed)
        server.route("/latest", body: releaseJSON(tag: "v1.2.0", server: server))
        await u.check()
        #expect(u.state == .available(version: "1.2.0", notes: URL(string: "https://example.com/notes")))
        #expect(!u.bannerDismissed)
    }

    @Test func homebrewInstallsNeverReplaceThemselves() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let prefix = work.appendingPathComponent("brew")
        let running = try makeBundle(in: prefix.appendingPathComponent("Cellar/fwd/1.0.0"), version: "1.0.0", marker: "old")
        server.route("/latest", body: releaseJSON(tag: "v1.1.0", server: server))
        let u = updater(server, installed: running, version: "1.0.0", kind: nil)
        #expect(u.kind == .homebrew)

        await u.check()
        #expect(u.state == .available(version: "1.1.0", notes: URL(string: "https://example.com/notes")))
        #expect(!server.hits.contains("/fwd.zip"))

        // After `brew upgrade`, opt/fwd points at the new version.
        let upgraded = try makeBundle(in: prefix.appendingPathComponent("Cellar/fwd/1.1.0"), version: "1.1.0")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("opt"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: prefix.appendingPathComponent("opt/fwd"),
            withDestinationURL: upgraded.deletingLastPathComponent())
        await u.check()
        #expect(u.state == .ready(version: "1.1.0", notes: URL(string: "https://example.com/notes")))
        let launch = try u.install()
        #expect(launch.path.hasSuffix("opt/fwd/fwd.app"))
        #expect(try String(contentsOf: running.appendingPathComponent("Contents/marker"), encoding: .utf8) == "old")
    }

    @Test func failedSwapPutsTheOldBundleBack() throws {
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "1.0.0", marker: "old")
        let missing = work.appendingPathComponent("nowhere/fwd.app")
        #expect(throws: (any Error).self) { try Updater.swap(newBundle: missing, into: installed) }
        #expect(Updater.bundleVersion(installed) == "1.0.0")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        #expect(leftovers == ["fwd.app"])
    }

    // MARK: fwd try

    @Test func readsWhichBuildToSwitchTo() {
        #expect(SwitchTarget("42") == .pullRequest(42))
        #expect(SwitchTarget("#42") == .pullRequest(42))
        #expect(SwitchTarget("pr-42") == .pullRequest(42))
        #expect(SwitchTarget("beta") == .beta)
        #expect(SwitchTarget("Release") == .stable)
        #expect(SwitchTarget("stable") == .stable)
        #expect(SwitchTarget("0") == nil)
        #expect(SwitchTarget("main") == nil)
    }

    @Test func switchesToAPullRequestsPreviewEvenWhenItIsntNewer() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "0.2.1-beta.15", marker: "beta")
        // Previews carry the newest beta's version, so it's no newer.
        let preview = try makeBundle(in: work.appendingPathComponent("build"), version: "0.2.1-beta.15", marker: "pr")
        server.route("/tags/pr-42", body: releaseJSON(tag: "pr-42", server: server))
        server.route("/fwd.zip", body: try await zip(preview))
        let u = updater(server, installed: installed, version: "0.2.1-beta.15")
        #expect(try await u.switchTo(.pullRequest(42)) == "0.2.1-beta.15")
        #expect(try u.install() == installed)
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8) == "pr")
    }

    @Test func switchesBackToAnOlderRelease() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "0.2.1-beta.15")
        let release = try makeBundle(in: work.appendingPathComponent("build"), version: "0.2.0")
        server.route("/latest", body: releaseJSON(tag: "v0.2.0", server: server))
        server.route("/fwd.zip", body: try await zip(release))
        let u = updater(server, installed: installed, version: "0.2.1-beta.15")
        #expect(try await u.switchTo(.stable) == "0.2.0")
        _ = try u.install()
        #expect(Updater.bundleVersion(installed) == "0.2.0")
    }

    @Test func aPullRequestWithoutAPreviewSaysSo() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "0.2.0")
        let u = updater(server, installed: installed, version: "0.2.0")
        await #expect(throws: SwitchError.noPreview(7)) { try await u.switchTo(.pullRequest(7)) }
        #expect(Updater.bundleVersion(installed) == "0.2.0")
    }

    @Test func homebrewCopiesDontSwitch() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "0.2.0")
        let u = updater(server, installed: installed, version: "0.2.0", kind: .homebrew)
        await #expect(throws: SwitchError.notSelfUpdating("is managed by Homebrew")) {
            try await u.switchTo(.pullRequest(42))
        }
        #expect(server.hits.isEmpty)
    }

    @Test func tryingTheSameBuildTwiceKeepsItInstallable() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "0.2.0", marker: "old")
        let preview = try makeBundle(in: work.appendingPathComponent("build"), version: "0.2.1-beta.15", marker: "pr")
        server.route("/tags/pr-42", body: releaseJSON(tag: "pr-42", server: server))
        server.route("/fwd.zip", body: try await zip(preview))
        let u = updater(server, installed: installed, version: "0.2.0")
        _ = try await u.switchTo(.pullRequest(42))
        _ = try await u.switchTo(.pullRequest(42))
        _ = try u.install()
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8) == "pr")
    }

    @Test func anUpdateCheckDoesntReplaceTheBuildBeingTried() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "0.2.0", marker: "old")
        let preview = try makeBundle(in: work.appendingPathComponent("build"), version: "0.2.1-beta.15", marker: "pr")
        server.route("/tags/pr-42", body: releaseJSON(tag: "pr-42", server: server))
        // A release newer than the preview, which a check would offer.
        server.route("/latest", body: releaseJSON(tag: "v0.3.0", server: server))
        server.route("/fwd.zip", body: try await zip(preview))
        let u = updater(server, installed: installed, version: "0.2.0")
        _ = try await u.switchTo(.pullRequest(42))
        await u.check()
        #expect(u.state == .ready(version: "0.2.1-beta.15", notes: URL(string: "https://example.com/notes")))
        _ = try u.install()
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8) == "pr")
    }

    @Test func onlyAMissingReleaseMeansNoPreview() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "0.2.0")
        server.route("/tags/pr-42", status: 403, body: Data("rate limited".utf8))
        let u = updater(server, installed: installed, version: "0.2.0")
        await #expect(throws: SwitchError.failed("GitHub answered 403")) { try await u.switchTo(.pullRequest(42)) }
    }

    @Test func aBuildReadyTooLateIsDropped() async throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let installed = try makeBundle(in: work.appendingPathComponent("Applications"), version: "0.2.0", marker: "old")
        let preview = try makeBundle(in: work.appendingPathComponent("build"), version: "0.2.1-beta.15", marker: "pr")
        server.route("/tags/pr-42", body: releaseJSON(tag: "pr-42", server: server))
        server.route("/fwd.zip", body: try await zip(preview))
        let u = updater(server, installed: installed, version: "0.2.0")
        await #expect(throws: SwitchError.timedOut(0)) { try await u.switchTo(.pullRequest(42), timeout: 0) }
        #expect(throws: Updater.UpdateError.self) { try u.install() }
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8) == "old")
    }
}
