import Foundation

public enum ConnectionError: Error, Equatable {
    /// Needs a human: bad key, unknown host key, expired sign-in. Don't retry.
    case needsAttention(String)
    /// Couldn't reach the host. Retry later.
    case unreachable(String)
    /// A single operation on a live connection failed.
    case failed(String)

    public var message: String {
        switch self {
        case .needsAttention(let m), .unreachable(let m), .failed(let m): return m
        }
    }
}

/// A background link to one host that forwards can be added to and removed from.
public protocol Connection: AnyObject {
    /// Called once if the link dies by itself after `start()` succeeded.
    var onExit: (() -> Void)? { get set }
    var masterPID: Int32? { get }
    func start() async throws
    func isAlive() async -> Bool
    func stop() async
    func addForward(local: Int, remote: Int) async throws
    func cancelForward(local: Int, remote: Int) async throws
    func run(_ command: String) async throws -> String
    /// `start()` is waiting for you to sign in in a browser it opened.
    var waitingForSignIn: Bool { get }
    /// Nobody asked for this connection (a reconnect, a kept port, an ssh
    /// session fwd noticed, a script), so `start()` must not let a sign-in
    /// proxy open a browser page. It fails with `needsAttention` instead,
    /// and the page opens when a person clicks Sign In (#28, #29).
    var quietSignIn: Bool { get set }
}

public extension Connection {
    var waitingForSignIn: Bool { false }
    var quietSignIn: Bool {
        get { false }
        set {}
    }
}

public extension ConnectionError {
    /// How every "this host wants a browser sign-in" message starts, so the
    /// card can offer Sign In instead of Retry.
    static let signInSentence = "This host wants you to sign in in a browser."
    /// A sign-in is needed and no page is open for it.
    static let signInNeeded = "\(signInSentence) Click Sign In and fwd opens the page."
    /// A page was opened and nobody answered it in time.
    static let signInTimedOut = "\(signInSentence) The page fwd opened wasn't answered. Click Sign In to open it again."

    /// Whether `message` is one of the sign-in messages above.
    static func asksToSignIn(_ message: String) -> Bool { message.hasPrefix(signInSentence) }
}

/// A do-nothing `open` put first on an ssh's PATH, so a sign-in proxy that
/// runs `open <url>` (cloudflared does) leaves a note instead of opening a
/// browser page. Only that one ssh and its ProxyCommand see it.
struct OpenStandIn {
    let dir: URL
    private var asked: URL { dir.appendingPathComponent("asked") }

    init(in parent: URL, name: String) throws {
        dir = parent.appendingPathComponent(name + ".open")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        // The URL holds a sign-in token, so it isn't kept: only that it was asked for.
        let quoted = "'" + asked.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\n# fwd's stand-in for open: see OpenStandIn in Connection.swift.\n: > \(quoted)\nexit 0\n"
        let file = dir.appendingPathComponent("open")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }

    /// `env` with the stand-in ahead of everything else on PATH.
    func environment(_ env: [String: String]) -> [String: String] {
        var env = env
        let path = env["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = dir.path + ":" + path
        return env
    }

    /// Whether the proxy ran the stand-in. It prints its sign-in lines
    /// about when it runs `open`, so this gives the note a second to land.
    func wasAsked() async -> Bool {
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: asked.path) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return FileManager.default.fileExists(atPath: asked.path)
    }
}

/// Rewrites a host's ProxyCommand for a quiet attempt so the stand-in `open`
/// is first on PATH when the proxy runs.
///
/// Putting it first on ssh's own PATH isn't enough: ssh runs a ProxyCommand
/// as `$SHELL -c "exec <command>"`, and the shell's startup files run before
/// the proxy looks `open` up. fish puts fish_user_paths ahead of what it
/// inherits, and a startup file can rebuild PATH outright, so the proxy found
/// the real `open` and a page opened by itself (#31). Prefixed with `env
/// PATH=…`, the command gets the stand-in first after the shell has started.
enum QuietProxy {
    /// Shells that read `env PATH="dir:$PATH" command` the same way. fish
    /// joins its PATH list with colons inside double quotes, as the others do.
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]

    /// The host's ProxyCommand as `ssh -G` prints it, with ssh's % tokens
    /// still in place, or nil when the host has none.
    static func command(sshG: String) -> String? {
        for line in sshG.split(whereSeparator: \.isNewline) where line.hasPrefix("proxycommand ") {
            let command = line.dropFirst("proxycommand ".count).trimmingCharacters(in: .whitespaces)
            return command.isEmpty ? nil : command
        }
        return nil
    }

    /// `command` with the stand-in folder put first on PATH, or nil when
    /// that can't be done safely: a shell that may read the line differently,
    /// a folder name that would need quoting, or a command `env` can't run.
    /// The command itself is passed through exactly as written.
    static func wrapped(_ command: String, standIn: String, shell: String?) -> String? {
        guard shells.contains(name(ofShell: shell)), isPlain(standIn), isOneProgram(command) else { return nil }
        return "env PATH=\"\(standIn):$PATH\" \(command)"
    }

    /// ssh uses /bin/sh when SHELL isn't set.
    static func name(ofShell shell: String?) -> String {
        guard let shell, !shell.isEmpty else { return "sh" }
        return URL(fileURLWithPath: shell).lastPathComponent
    }

    /// Nothing a shell treats specially inside double quotes, no `%` (ssh
    /// would read it as a token) and no `:` (it would split the PATH entry).
    static func isPlain(_ path: String) -> Bool {
        !path.isEmpty && !path.contains { "\"$`\\%:\n".contains($0) }
    }

    /// Words that aren't programs `env` can run.
    private static let shellWords: Set<String> = [
        "exec", "eval", "command", "builtin", "source", ".", "cd", "set", "export", "if", "for", "while",
        "until", "case", "begin", "function", "time", "!", "{", "[[", "noglob", "nocorrect",
    ]

    /// One program and its arguments: no pipeline, list, redirection,
    /// subshell or shell keyword outside quotes, any of which `env` would
    /// run only the first part of, or fail on.
    static func isOneProgram(_ command: String) -> Bool {
        let first = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard !first.isEmpty, !shellWords.contains(first), !first.contains("=") else { return false }
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let open = quote {
                // Command substitution runs inside double quotes too; that is the shell's to do.
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if ";|&<>(){}`\n".contains(character) {
                return false
            }
        }
        return quote == nil && !escaped
    }
}

/// `Connection` built on the system ssh client and a ControlMaster socket.
public final class SSHConnection: Connection, @unchecked Sendable {
    public static let sshPath = "/usr/bin/ssh"

    public let host: String
    public var onExit: (() -> Void)?
    private let paths: Paths
    private let log: Log
    private let connectTimeout: Int
    /// How long to wait for you once a sign-in proxy has opened a browser.
    private let signInTimeout: TimeInterval
    let socketPath: String

    private let lock = NSLock()
    private var process: Process?
    private var stderrLines: [String] = []
    private var ready = false
    private var stopping = false
    private var signInPending = false
    private var quiet = false
    /// The folder holding the stand-in `open` for a quiet attempt.
    private var standInDir: URL?

    public var waitingForSignIn: Bool { lock.withLock { signInPending } }

    public var quietSignIn: Bool {
        get { lock.withLock { quiet } }
        set { lock.withLock { quiet = newValue } }
    }

    /// What the master ssh inherits. ssh runs a ProxyCommand with its `SHELL`.
    private let environment: [String: String]

    public init(host: String, paths: Paths, log: Log, connectTimeout: Int = 8, signInTimeout: TimeInterval = 180,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.host = host
        self.paths = paths
        self.log = log
        self.environment = environment
        self.connectTimeout = connectTimeout
        self.signInTimeout = signInTimeout
        // One socket per connection, not per host: a stale connection being
        // stopped must never remove or close the one that replaced it.
        let name = Paths.shortHash(host + "\u{0}" + paths.configDir.path) + "-" + UUID().uuidString.prefix(6)
        self.socketPath = paths.socketDir.appendingPathComponent(name).path
    }

    /// Creates the socket folder, or checks an existing one: it must be a
    /// real folder (not a symlink) owned by you, and nobody else may write
    /// to it, or another account could swap a socket under fwd.
    public static func prepareSocketDir(_ dir: URL) throws {
        let path = dir.path
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            throw ConnectionError.failed("Couldn't create \(path): \(String(cString: strerror(errno)))")
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw ConnectionError.needsAttention("\(path) isn't a folder you own, so fwd won't put its sockets there")
        }
        if info.st_mode & 0o077 != 0, chmod(path, 0o700) != 0 {
            throw ConnectionError.failed("Couldn't make \(path) private")
        }
    }

    public var masterPID: Int32? {
        lock.lock(); defer { lock.unlock() }
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    /// Options every invocation carries. `ClearAllForwardings` must be on
    /// each one: a command sent through the socket without it makes the
    /// master open the config's own forwards.
    public static func baseOptions(paths: Paths) -> [String] {
        var args = ["-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes",
                    "-o", "RemoteCommand=none", "-o", "RequestTTY=no"]
        if let config = paths.sshConfigOverride {
            args = ["-F", config.path] + args
        }
        return args
    }

    private var base: [String] { Self.baseOptions(paths: paths) }

    /// Closes every master in fwd's socket folder without using Swift
    /// concurrency, for use while the app is quitting. Each one gets a couple
    /// of seconds at most.
    public static func closeAllBlocking(paths: Paths) {
        let sockets = (try? FileManager.default.contentsOfDirectory(atPath: paths.socketDir.path)) ?? []
        for name in sockets {
            let socket = paths.socketDir.appendingPathComponent(name).path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: sshPath)
            process.arguments = ["-F", "none", "-S", socket, "-O", "exit", "--", "quit"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning, Date() < deadline { usleep(20_000) }
                if process.isRunning { process.terminate() }
            }
            try? FileManager.default.removeItem(atPath: socket)
        }
    }

    /// Closes masters left behind by a run that was killed or crashed.
    /// Without this they would keep their laptop ports forever. Only touches
    /// sockets in fwd's own socket folder.
    public static func closeLeftovers(paths: Paths, log: Log) async {
        let sockets = (try? FileManager.default.contentsOfDirectory(atPath: paths.socketDir.path)) ?? []
        for name in sockets {
            let socket = paths.socketDir.appendingPathComponent(name).path
            let result = await Shell.run(
                sshPath, ["-F", "none", "-S", socket, "-O", "exit", "--", "leftover"], timeout: 5)
            if result.ok { log.write("closed a connection left over from a previous run") }
            try? FileManager.default.removeItem(atPath: socket)
        }
    }

    private func control(_ arguments: [String], timeout: TimeInterval = 15) async -> ShellResult {
        await Shell.run(Self.sshPath, base + ["-S", socketPath] + arguments + ["--", host], timeout: timeout)
    }

    public func start() async throws {
        try Self.prepareSocketDir(paths.socketDir)
        guard socketPath.utf8.count < 100 else {
            throw ConnectionError.failed("Control socket path is too long: \(socketPath)")
        }
        lock.withLock { stopping = false }

        // ssh's ConnectTimeout also bounds the wait for the server's banner,
        // which a sign-in proxy holds back until you've signed in. Give a
        // proxied host the whole sign-in time; the deadline below still
        // gives up on it as quickly as any other unless a sign-in starts.
        let proxyCommand = await proxyCommand()
        let proxied = proxyCommand != nil
        let sshTimeout = proxied ? max(connectTimeout, Int(signInTimeout)) : connectTimeout

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sshPath)
        var options = [
            "-M", "-N", "-S", socketPath,
            "-o", "ExitOnForwardFailure=no",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
            "-o", "ConnectTimeout=\(sshTimeout)",
            "-o", "ControlPersist=no",
            // The master must stay our child so its exit can be observed.
            "-o", "ForkAfterAuthentication=no",
        ]
        // A sign-in proxy (cloudflared) opens the browser by running `open`.
        // When nobody asked for this connection, give it a stand-in that
        // only notes it was asked, so no page appears by itself.
        var standIn: OpenStandIn?
        if quietSignIn, let proxyCommand {
            do {
                let made = try OpenStandIn(in: paths.socketDir, name: URL(fileURLWithPath: socketPath).lastPathComponent)
                standIn = made
                lock.withLock { standInDir = made.dir }
                process.environment = made.environment(environment)
                log.write("nobody asked for this connection, so a sign-in page won't be opened for it", host: host)
                // ssh's own PATH isn't what the proxy sees: your shell runs
                // it and may reorder PATH first (#31). The command line wins
                // over the config, so this replaces the host's ProxyCommand
                // for this one ssh. Never logged: it may hold a token.
                let shell = QuietProxy.name(ofShell: environment["SHELL"])
                if let wrapped = QuietProxy.wrapped(proxyCommand, standIn: made.dir.path, shell: environment["SHELL"]) {
                    options += ["-o", "ProxyCommand=\(wrapped)"]
                    log.write("running this host's ProxyCommand with fwd's stand-in for open first on PATH, "
                              + "set after your shell (\(shell)) has started", host: host)
                } else {
                    log.write("left this host's ProxyCommand as it is (your shell is \(shell); the command may be "
                              + "more than one program, or fwd's folder name needs quoting), so the stand-in for open "
                              + "is first only on ssh's own PATH; a shell that reorders PATH can still open a page",
                              host: host)
                }
            } catch {
                log.write("couldn't set up the stand-in for open (\(error.localizedDescription)); "
                          + "a sign-in page may open by itself", host: host)
            }
        }
        process.arguments = base + options + ["--", host]
        // Only the sign-in needs it; it's gone once this attempt has ended.
        defer {
            if let standIn {
                try? FileManager.default.removeItem(at: standIn.dir)
                lock.withLock { standInDir = nil }
            }
        }
        let errPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.absorb(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let notify = self.ready && !self.stopping
            self.ready = false
            self.lock.unlock()
            if notify {
                self.log.write("connection lost", host: self.host)
                self.onExit?()
            }
        }

        // stop() may have come in while the proxy check ran, before there
        // was a process for it to stop.
        let stopped = lock.withLock { () -> Bool in
            if stopping { return true }
            self.process = process
            stderrLines = []
            ready = false
            return false
        }
        if stopped {
            log.write("stopped before ssh started", host: host)
            throw ConnectionError.failed("Stopped")
        }

        do {
            try process.run()
        } catch {
            throw ConnectionError.unreachable("Couldn't start ssh: \(error.localizedDescription)")
        }

        var deadline = Date().addingTimeInterval(TimeInterval(connectTimeout) + 6)
        var signingIn = false
        defer { lock.withLock { signInPending = false } }
        while Date() < deadline {
            // The ssh that opened the browser connects by itself once you've
            // signed in, so wait for you instead of killing it.
            if !signingIn, Self.asksForBrowserSignIn(collectedStderr()) {
                if let standIn {
                    if await standIn.wasAsked() {
                        log.write("this host wants a browser sign-in; kept the page from opening, "
                                  + "and stopped until you click Sign In", host: host)
                        await stop()
                        throw ConnectionError.needsAttention(ConnectionError.signInNeeded)
                    }
                    // The proxy reached the browser some other way (its own
                    // PATH, an absolute path), so a page is open: wait for it.
                    log.write("the proxy opened the sign-in page without going through fwd's stand-in "
                              + "for open, so a page did open", host: host)
                }
                signingIn = true
                lock.withLock { signInPending = true }
                deadline = max(deadline, Date().addingTimeInterval(signInTimeout))
                log.write("waiting up to \(Int(signInTimeout))s for you to sign in in the browser", host: host)
            }
            if !process.isRunning {
                // Give the pipe a moment to deliver the last lines.
                try? await Task.sleep(nanoseconds: 50_000_000)
                throw Self.classify(stderr: collectedStderr())
            }
            if FileManager.default.fileExists(atPath: socketPath),
               await control(["-O", "check"], timeout: 5).ok {
                lock.withLock { ready = true }
                if signingIn { log.write("signed in", host: host) }
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let stderr = collectedStderr()
        await stop()
        let reason = Self.classify(stderr: stderr)
        if case .needsAttention = reason { throw reason }
        throw ConnectionError.unreachable(stderr.isEmpty ? "Timed out connecting" : reason.message)
    }

    private func absorb(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        lock.lock()
        stderrLines.append(contentsOf: lines)
        if stderrLines.count > 50 { stderrLines.removeFirst(stderrLines.count - 50) }
        lock.unlock()
        for line in lines { log.write("ssh: \(line)", host: host) }
    }

    private func collectedStderr() -> String {
        lock.lock(); defer { lock.unlock() }
        return stderrLines.joined(separator: "\n")
    }

    /// The ProxyCommand the host's ssh config sends it through, which is
    /// where sign-in proxies like cloudflared live, or nil when it has none.
    /// Logs only that there is one, never the command itself, which may hold a token.
    private func proxyCommand() async -> String? {
        let result = await Shell.run(Self.sshPath, base + ["-G", "--", host], timeout: 5)
        guard result.ok else {
            let why = result.status == -1 ? "timed out" : Self.lastLine(result.stderr.isEmpty ? "exit \(result.status)" : result.stderr)
            log.write("couldn't read the ssh config (\(why)); connecting without waiting for a sign-in", host: host)
            return nil
        }
        let command = QuietProxy.command(sshG: result.stdout)
        if command != nil {
            log.write("goes through a ProxyCommand; ssh may wait \(Int(signInTimeout))s for a sign-in", host: host)
        }
        return command
    }

    /// A sign-in proxy has opened a browser and is waiting for you.
    static func asksForBrowserSignIn(_ stderr: String) -> Bool {
        let phrases = ["open the following URL and log in", "should have opened at the following URL"]
        let lowered = stderr.lowercased()
        return phrases.contains { lowered.contains($0.lowercased()) }
    }

    static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
    }

    /// Sorts an ssh failure into "a person has to fix this" or "try again later".
    public static func classify(stderr: String) -> ConnectionError {
        // Phrases ssh itself (or a sign-in proxy) prints. Kept specific so a
        // server's login banner can't be mistaken for one of them.
        let needsHuman = [
            "Permission denied (", "Host key verification failed",
            "REMOTE HOST IDENTIFICATION HAS CHANGED", "Too many authentication failures",
            "No more authentication methods", "sign_and_send_pubkey",
            "Bad configuration option", "Bad owner or permissions",
        ]
        // A sign-in proxy that opened a browser and wasn't answered in time.
        // Retrying by itself would open another tab.
        if asksForBrowserSignIn(stderr) {
            return .needsAttention(ConnectionError.signInTimedOut)
        }
        let lowered = stderr.lowercased()
        let message = stderr.isEmpty ? "ssh exited without a message" : lastLine(stderr)
        if needsHuman.contains(where: { lowered.contains($0.lowercased()) }) {
            return .needsAttention(message)
        }
        return .unreachable(proxyFailure(stderr) ?? message)
    }

    /// What to show when the host's ProxyCommand died before ssh got through
    /// it, or nil when that isn't what happened. ssh's own last line is then
    /// "Connection closed by UNKNOWN port 65535", which says nothing; the
    /// proxy's complaint is on the line before it (#13).
    static func proxyFailure(_ stderr: String) -> String? {
        // With a proxy in between ssh doesn't know the address, so it names
        // the peer UNKNOWN port 65535. It never says that about a real host.
        let sshOwn = ["UNKNOWN port 65535", "kex_exchange_identification:", "banner exchange"]
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = lines.last, last.contains("UNKNOWN port 65535") else { return nil }
        guard let proxy = lines.last(where: { line in !sshOwn.contains { line.contains($0) } }) else {
            return "The ssh proxy (ProxyCommand) didn't get a connection through. Plain ssh will fail the same way."
        }
        // Go proxies (cloudflared, tsh) say `read tcp a->b: read: connection
        // reset by peer`: they connected, then something cut the connection.
        if proxy.lowercased().contains("connection reset by peer") {
            return "The ssh proxy connected, then the network reset it. "
                + "This network may be blocking it; plain ssh will fail too."
        }
        return "The ssh proxy failed: \(proxy)"
    }

    /// Asks the master to add or drop one forward. The target is `localhost`
    /// rather than 127.0.0.1 so a server listening only on IPv6 is reached
    /// too; the remote sshd tries both. This is the one call that
    /// can't carry `ClearAllForwardings`, since that would also clear the
    /// `-L` being requested. It reads no config file instead (`-F none`), so
    /// there are no config forwards for it to drag along; the socket is all
    /// it needs.
    private func forwardRequest(_ verb: String, local: Int, remote: Int) async -> ShellResult {
        await Shell.run(Self.sshPath, [
            "-F", "none", "-o", "BatchMode=yes", "-S", socketPath,
            "-O", verb, "-L", "127.0.0.1:\(local):localhost:\(remote)", "--", host,
        ], timeout: 15)
    }

    public func isAlive() async -> Bool {
        guard masterPID != nil else { return false }
        return await control(["-O", "check"], timeout: 5).ok
    }

    public func stop() async {
        let (process, standIn) = lock.withLock { () -> (Process?, URL?) in
            stopping = true
            ready = false
            signInPending = false
            defer { standInDir = nil }
            return (self.process, standInDir)
        }
        if let standIn { try? FileManager.default.removeItem(at: standIn) }
        guard let process else { return }
        if process.isRunning {
            _ = await control(["-O", "exit"], timeout: 5)
        }
        if process.isRunning {
            process.terminate()
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func requireMaster() throws {
        guard masterPID != nil else { throw ConnectionError.failed("Not connected") }
    }

    public func addForward(local: Int, remote: Int) async throws {
        try requireMaster()
        let result = await forwardRequest("forward", local: local, remote: remote)
        guard result.ok else {
            throw ConnectionError.failed(Self.lastLine(result.stderr.isEmpty ? "forward failed" : result.stderr))
        }
    }

    public func cancelForward(local: Int, remote: Int) async throws {
        try requireMaster()
        let result = await forwardRequest("cancel", local: local, remote: remote)
        guard result.ok else {
            throw ConnectionError.failed(Self.lastLine(result.stderr.isEmpty ? "cancel failed" : result.stderr))
        }
    }

    public func run(_ command: String) async throws -> String {
        // Without a master, `ssh -S` would quietly open a fresh connection.
        try requireMaster()
        let result = await Shell.run(
            Self.sshPath, base + ["-S", socketPath, "--", host, command], timeout: 15)
        guard result.ok else {
            throw ConnectionError.failed(Self.lastLine(result.stderr.isEmpty ? "command failed" : result.stderr))
        }
        return result.stdout
    }
}
