import Combine
import Darwin
import Foundation

/// Who ran a `fwd` command: the command's own process and the processes
/// above it, read while the command is still waiting for its answer. This
/// is how a script or agent that runs `fwd` over and over gets a name.
public struct Caller: Equatable, Sendable {
    public struct Step: Equatable, Sendable, Identifiable {
        public let pid: Int32
        /// The program's file name, like `zsh` or `node`.
        public let name: String
        /// The full command line. Shown on this Mac only, never logged: it
        /// can hold tokens.
        public let arguments: [String]
        public var id: Int32 { pid }

        public init(pid: Int32, name: String, arguments: [String] = []) {
            self.pid = pid
            self.name = name
            self.arguments = arguments
        }
    }

    /// The `fwd` command first, then what started it, and so on up.
    public let chain: [Step]

    public init(chain: [Step]) {
        self.chain = chain
    }

    /// What's above the `fwd` command, nearest first: `zsh ← node ← launchd`.
    /// Program names only, so it's safe in the log.
    public var summary: String {
        let above = chain.dropFirst().map(\.name)
        return above.isEmpty ? "unknown" : above.joined(separator: " ← ")
    }

    static let maxDepth = 12

    /// The process at the other end of a connected Unix socket.
    public static func peer(of fd: Int32) -> Caller? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return of(pid: pid)
    }

    /// `pid` and its ancestors, up to launchd.
    public static func of(pid: Int32) -> Caller {
        var steps: [Step] = []
        var seen = Set<Int32>()
        var current = pid
        while current > 0, steps.count < maxDepth, seen.insert(current).inserted {
            let arguments = UserSessions.arguments(pid: current) ?? []
            steps.append(Step(pid: current, name: name(pid: current, arguments: arguments), arguments: arguments))
            // launchd is the top; what it starts is a launch agent or an app.
            guard current != 1, let above = parent(of: current) else { break }
            current = above
        }
        return Caller(chain: steps)
    }

    static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func name(pid: Int32, arguments: [String]) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            if !path.isEmpty { return (path as NSString).lastPathComponent }
        }
        if let first = arguments.first, !first.isEmpty { return (first as NSString).lastPathComponent }
        return "pid \(pid)"
    }
}

/// The `fwd` commands run since the app started, grouped by what was asked
/// and who asked, so a loop shows as one row with a count.
@MainActor
public final class CommandLog: ObservableObject {
    public struct Entry: Identifiable, Equatable, Sendable {
        /// The command and the caller's program names.
        public let id: String
        /// As typed after `fwd`, like `forward devbox 3000`.
        public let command: String
        /// From the most recent run. Nil when the caller couldn't be read.
        public var caller: Caller?
        public var count: Int
        public let first: Date
        public var last: Date
    }

    /// Newest first.
    @Published public private(set) var entries: [Entry] = []

    public static let limit = 50
    /// A count worth a line in the log: the first time it's clearly a loop.
    public static let loopAt = 10

    public init() {}

    /// Adds one run and returns its row.
    @discardableResult
    public func record(command: String, caller: Caller?, at now: Date = Date()) -> Entry {
        let id = command + "\n" + (caller?.summary ?? "unknown")
        var entry: Entry
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entry = entries.remove(at: index)
            entry.count += 1
            entry.last = now
            entry.caller = caller ?? entry.caller
        } else {
            entry = Entry(id: id, command: command, caller: caller, count: 1, first: now, last: now)
        }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        return entry
    }
}
