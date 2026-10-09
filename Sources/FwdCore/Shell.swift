@preconcurrency import Dispatch
import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
}

public enum Shell {
    /// Runs a program directly (no shell) and collects its output.
    ///
    /// Always returns: if the program outlives `timeout` it is terminated,
    /// then killed, and the call reports status -1 whatever the child does.
    /// It also doesn't wait on output pipes once the program has exited, so
    /// a background process that inherited them can't hold the call open.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) async -> ShellResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let out = Pipe()
            let err = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = err

            let state = RunState(continuation)
            for (pipe, isOut) in [(out, true), (err, false)] {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        state.reachedEOF()
                    } else {
                        state.append(data, isOut: isOut)
                    }
                }
            }
            let stopReading: @Sendable () -> Void = {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
            }

            process.terminationHandler = { finished in
                // Normally both pipes hit EOF at once. Allow a moment for the
                // last bytes, then stop waiting regardless.
                state.whenDrained(orAfter: 0.5) {
                    stopReading()
                    state.finish(status: state.timedOut ? -1 : finished.terminationStatus)
                }
            }

            do {
                try process.run()
            } catch {
                stopReading()
                state.finish(status: -1, stderrOverride: error.localizedDescription)
                return
            }

            let queue = DispatchQueue.global()
            queue.asyncAfter(deadline: .now() + timeout) {
                guard !state.isFinished else { return }
                state.timedOut = true
                if process.isRunning { process.terminate() }
                queue.asyncAfter(deadline: .now() + 2) {
                    guard !state.isFinished else { return }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    stopReading()
                    state.finish(status: -1)
                }
            }
        }
    }
}

/// Collects output and makes sure the continuation is resumed exactly once.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ShellResult, Never>?
    private var out = Data()
    private var err = Data()
    private var eofCount = 0
    private var onDrained: (() -> Void)?
    private var _timedOut = false

    init(_ continuation: CheckedContinuation<ShellResult, Never>) {
        self.continuation = continuation
    }

    var isFinished: Bool { lock.withLock { continuation == nil } }

    var timedOut: Bool {
        get { lock.withLock { _timedOut } }
        set { lock.withLock { _timedOut = newValue } }
    }

    func append(_ data: Data, isOut: Bool) {
        lock.withLock {
            if isOut { out.append(data) } else { err.append(data) }
        }
    }

    func reachedEOF() {
        let ready: (() -> Void)? = lock.withLock {
            eofCount += 1
            guard eofCount >= 2 else { return nil }
            defer { onDrained = nil }
            return onDrained
        }
        ready?()
    }

    /// Runs `body` once both pipes have closed, or after `seconds`, whichever
    /// comes first.
    func whenDrained(orAfter seconds: TimeInterval, _ body: @escaping @Sendable () -> Void) {
        let once = Once(body)
        let already: Bool = lock.withLock {
            if eofCount >= 2 { return true }
            onDrained = { once.run() }
            return false
        }
        if already {
            once.run()
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.run() }
        }
    }

    func finish(status: Int32, stderrOverride: String? = nil) {
        let (pending, result): (CheckedContinuation<ShellResult, Never>?, ShellResult) = lock.withLock {
            let c = continuation
            continuation = nil
            return (c, ShellResult(
                status: status,
                stdout: String(decoding: out, as: UTF8.self),
                stderr: stderrOverride ?? String(decoding: err, as: UTF8.self)))
        }
        pending?.resume(returning: result)
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var body: (() -> Void)?

    init(_ body: @escaping () -> Void) {
        self.body = body
    }

    func run() {
        let pending: (() -> Void)? = lock.withLock {
            defer { body = nil }
            return body
        }
        pending?()
    }
}
