import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
}

public enum Shell {
    /// Runs a program directly (no shell), collecting its output. The process
    /// is terminated if it outlives `timeout`, and then reports status -1.
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

            let group = DispatchGroup()
            let box = OutputBox()
            for (pipe, isOut) in [(out, true), (err, false)] {
                group.enter()
                DispatchQueue.global().async {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    box.set(String(decoding: data, as: UTF8.self), isOut: isOut)
                    group.leave()
                }
            }

            do {
                try process.run()
            } catch {
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                group.notify(queue: .global()) {
                    continuation.resume(returning: ShellResult(status: -1, stdout: "", stderr: "\(error.localizedDescription)"))
                }
                return
            }

            let timer = DispatchWorkItem {
                if process.isRunning {
                    box.timedOut = true
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

            DispatchQueue.global().async {
                process.waitUntilExit()
                timer.cancel()
                group.notify(queue: .global()) {
                    let status = box.timedOut ? -1 : process.terminationStatus
                    continuation.resume(returning: ShellResult(status: status, stdout: box.out, stderr: box.err))
                }
            }
        }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = ""
    private var _err = ""
    private var _timedOut = false

    func set(_ text: String, isOut: Bool) {
        lock.lock()
        if isOut { _out = text } else { _err = text }
        lock.unlock()
    }
    var out: String { lock.lock(); defer { lock.unlock() }; return _out }
    var err: String { lock.lock(); defer { lock.unlock() }; return _err }
    var timedOut: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _timedOut }
        set { lock.lock(); _timedOut = newValue; lock.unlock() }
    }
}
