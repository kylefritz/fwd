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
}

/// `Connection` built on the system ssh client and a ControlMaster socket.
public final class SSHConnection: Connection, @unchecked Sendable {
    public static let sshPath = "/usr/bin/ssh"

    public let host: String
    public var onExit: (() -> Void)?
    private let paths: Paths
    private let log: Log
    private let connectTimeout: Int
    private let socketPath: String

    private let lock = NSLock()
    private var process: Process?
    private var stderrLines: [String] = []
    private var ready = false
    private var stopping = false

    public init(host: String, paths: Paths, log: Log, connectTimeout: Int = 8) {
        self.host = host
        self.paths = paths
        self.log = log
        self.connectTimeout = connectTimeout
        let name = Paths.shortHash(host + "\u{0}" + paths.configDir.path)
        self.socketPath = paths.socketDir.appendingPathComponent(name).path
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

    private func control(_ arguments: [String], timeout: TimeInterval = 15) async -> ShellResult {
        await Shell.run(Self.sshPath, base + ["-S", socketPath] + arguments + ["--", host], timeout: timeout)
    }

    public func start() async throws {
        try? FileManager.default.createDirectory(
            at: paths.socketDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard socketPath.utf8.count < 100 else {
            throw ConnectionError.failed("Control socket path is too long: \(socketPath)")
        }
        // A master left over from a crashed run would make ours fail to bind.
        if FileManager.default.fileExists(atPath: socketPath) {
            _ = await control(["-O", "exit"], timeout: 5)
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sshPath)
        process.arguments = base + [
            "-M", "-N", "-S", socketPath,
            "-o", "ExitOnForwardFailure=no",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "ControlPersist=no",
            "--", host,
        ]
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

        lock.lock()
        self.process = process
        stderrLines = []
        ready = false
        stopping = false
        lock.unlock()

        do {
            try process.run()
        } catch {
            throw ConnectionError.unreachable("Couldn't start ssh: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(TimeInterval(connectTimeout) + 6)
        while Date() < deadline {
            if !process.isRunning {
                // Give the pipe a moment to deliver the last lines.
                try? await Task.sleep(nanoseconds: 50_000_000)
                throw Self.classify(stderr: collectedStderr())
            }
            if FileManager.default.fileExists(atPath: socketPath),
               await control(["-O", "check"], timeout: 5).ok {
                lock.lock()
                ready = true
                lock.unlock()
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let stderr = collectedStderr()
        await stop()
        let reason = Self.classify(stderr: stderr)
        if case .needsAttention = reason { throw reason }
        throw ConnectionError.unreachable(stderr.isEmpty ? "Timed out connecting" : Self.lastLine(stderr))
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

    static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
    }

    /// Sorts an ssh failure into "a person has to fix this" or "try again later".
    public static func classify(stderr: String) -> ConnectionError {
        let needsHuman = [
            "Permission denied", "Host key verification failed",
            "REMOTE HOST IDENTIFICATION HAS CHANGED", "Too many authentication failures",
            "No more authentication methods", "passphrase", "sign_and_send_pubkey",
            "open the following URL", "Please open", "browser",
            "Bad configuration option", "Bad owner or permissions",
        ]
        let message = stderr.isEmpty ? "ssh exited without a message" : lastLine(stderr)
        let lowered = stderr.lowercased()
        if needsHuman.contains(where: { lowered.contains($0.lowercased()) }) {
            return .needsAttention(message)
        }
        return .unreachable(message)
    }

    /// Asks the master to add or drop one forward. This is the one call that
    /// can't carry `ClearAllForwardings`, since that would also clear the
    /// `-L` being requested. It reads no config file instead (`-F none`), so
    /// there are no config forwards for it to drag along; the socket is all
    /// it needs.
    private func forwardRequest(_ verb: String, local: Int, remote: Int) async -> ShellResult {
        await Shell.run(Self.sshPath, [
            "-F", "none", "-o", "BatchMode=yes", "-S", socketPath,
            "-O", verb, "-L", "127.0.0.1:\(local):127.0.0.1:\(remote)", "--", host,
        ], timeout: 15)
    }

    public func isAlive() async -> Bool {
        guard masterPID != nil else { return false }
        return await control(["-O", "check"], timeout: 5).ok
    }

    public func stop() async {
        lock.lock()
        stopping = true
        ready = false
        let process = self.process
        lock.unlock()
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
