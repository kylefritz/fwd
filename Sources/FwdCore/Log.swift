import Foundation

/// Plain timestamped lines in one file, rolled to `<name>.1` when it grows
/// past `maxBytes`.
public final class Log: @unchecked Sendable {
    public let file: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "fwd.log")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    public init(file: URL, maxBytes: Int = 5_000_000) {
        self.file = file
        self.maxBytes = maxBytes
    }

    public func write(_ message: String, host: String? = nil) {
        let stamp = formatter.string(from: Date())
        let tag = host.map { "[\($0)] " } ?? ""
        let line = "\(stamp) \(tag)\(message)\n"
        queue.async { self.append(line) }
    }

    /// Blocks until everything written so far is on disk.
    public func flush() {
        queue.sync {}
    }

    private func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size >= maxBytes {
            let rolled = file.appendingPathExtension("1")
            try? fm.removeItem(at: rolled)
            try? fm.moveItem(at: file, to: rolled)
        }
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
