import Foundation

/// A forward that exists: remote port reachable on a laptop port.
public struct Forward: Equatable, Hashable, Sendable {
    public let remote: Int
    public let local: Int
    /// The entry that asked for it.
    public let entry: String

    public init(remote: Int, local: Int, entry: String) {
        self.remote = remote
        self.local = local
        self.entry = entry
    }
}

/// A forward that should exist, before a laptop port has been chosen.
public struct DesiredPort: Equatable, Hashable, Sendable {
    public let remote: Int
    public let wantedLocal: Int
    public let entry: String
}

public enum Reconciler {
    /// What should be forwarded right now. Single ports always are, so the
    /// first request works the moment a server starts. Wildcards only cover
    /// ports the last scan saw listening; with no scan they cover nothing.
    /// When two entries claim one remote port, the earlier entry wins.
    public static func desired(patterns: [PortPattern], listening: Set<Int>?) -> [DesiredPort] {
        var result: [DesiredPort] = []
        var claimed = Set<Int>()
        for pattern in patterns {
            let remotes: [Int]
            if pattern.isWildcard {
                remotes = (listening ?? []).filter { pattern.remoteRange.contains($0) }.sorted()
            } else {
                remotes = [pattern.remoteRange.lowerBound]
            }
            for remote in remotes {
                guard let wanted = pattern.laptopPort(for: remote), claimed.insert(remote).inserted else {
                    continue
                }
                result.append(DesiredPort(remote: remote, wantedLocal: wanted, entry: pattern.text))
            }
        }
        return result
    }

    public struct Plan: Equatable {
        public var cancel: [Forward]
        public var add: [DesiredPort]
    }

    /// The difference between what exists and what should. A forward whose
    /// owning entry changed is cancelled and re-added, so its laptop port
    /// follows the new entry.
    public static func plan(desired: [DesiredPort], active: [Forward]) -> Plan {
        let wanted = Dictionary(uniqueKeysWithValues: desired.map { ($0.remote, $0) })
        var keep = Set<Int>()
        var cancel: [Forward] = []
        for forward in active {
            if let d = wanted[forward.remote], d.entry == forward.entry {
                keep.insert(forward.remote)
            } else {
                cancel.append(forward)
            }
        }
        return Plan(cancel: cancel, add: desired.filter { !keep.contains($0.remote) })
    }
}
