import Foundation

/// One port entry as typed by the user: `3000`, `3000 -> 4000`, `31**`,
/// `3*** -> 4***`. The left side is the remote port, the right the laptop port.
public struct PortPattern: Equatable, Hashable, Sendable {
    public let remoteRange: ClosedRange<Int>
    /// Added to a remote port to get the wanted laptop port.
    public let offset: Int
    /// Canonical spelling, used as the entry's identity.
    public let text: String

    public var isWildcard: Bool { remoteRange.count > 1 }

    public static let lowestLaptopPort = 1024
    public static let highestPort = 65535

    /// The wanted laptop port for a remote port, or nil when it would fall
    /// outside what an unprivileged process can bind.
    public func laptopPort(for remote: Int) -> Int? {
        guard remoteRange.contains(remote) else { return nil }
        let port = remote + offset
        guard (Self.lowestLaptopPort...Self.highestPort).contains(port) else { return nil }
        return port
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case notAPort(String)
        case outOfRange(String)
        case wildcardNotAtEnd(String)
        case wildcardMismatch
        case laptopPortTooLow(Int)
        case tooManyArrows

        public var description: String {
            switch self {
            case .empty: return "Type a port, like 3000"
            case .notAPort(let s): return "\"\(s)\" isn't a port"
            case .outOfRange(let s): return "\(s) is outside 1 to 65535"
            case .wildcardNotAtEnd(let s): return "In \"\(s)\" the *s must come last, like 31**"
            case .wildcardMismatch: return "Both sides need the same number of *s"
            case .laptopPortTooLow(let p): return "Laptop port \(p) is below 1024; try \(p) -> \(p + 8000)"
            case .tooManyArrows: return "Use one -> at most"
            }
        }
    }

    private struct Side {
        let low: Int
        let high: Int
        let stars: Int
        let text: String
    }

    private static func parseSide(_ raw: String) throws -> Side {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { throw ParseError.empty }
        guard s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "*") }) else {
            throw ParseError.notAPort(s)
        }
        let digits = s.prefix { $0 != "*" }
        let stars = s.count - digits.count
        guard s.dropFirst(digits.count).allSatisfy({ $0 == "*" }) else {
            throw ParseError.wildcardNotAtEnd(s)
        }
        guard !digits.isEmpty else { throw ParseError.wildcardNotAtEnd(s) }
        guard s.count <= 5, let prefix = Int(digits) else { throw ParseError.outOfRange(s) }
        var scale = 1
        for _ in 0..<stars { scale *= 10 }
        let low = prefix * scale
        let high = min(low + scale - 1, highestPort)
        guard low <= highestPort, high >= 1 else { throw ParseError.outOfRange(s) }
        // Drop leading zeros so "03000" and "3000" are the same entry.
        let text = String(prefix) + String(repeating: "*", count: stars)
        return Side(low: max(low, 1), high: high, stars: stars, text: text)
    }

    public static func parse(_ raw: String) throws -> PortPattern {
        let normalized = raw.replacingOccurrences(of: "→", with: "->")
        let parts = normalized.components(separatedBy: "->")
        guard parts.count <= 2 else { throw ParseError.tooManyArrows }
        let remote = try parseSide(parts[0])
        let laptop = parts.count == 2 ? try parseSide(parts[1]) : remote
        guard remote.stars == laptop.stars else { throw ParseError.wildcardMismatch }

        if remote.stars == 0 {
            guard laptop.low >= lowestLaptopPort else { throw ParseError.laptopPortTooLow(laptop.low) }
        } else {
            guard laptop.high >= lowestLaptopPort else { throw ParseError.laptopPortTooLow(laptop.high) }
        }

        let text = remote.text == laptop.text ? remote.text : "\(remote.text) -> \(laptop.text)"
        return PortPattern(
            remoteRange: remote.low...remote.high,
            offset: laptop.low - remote.low,
            text: text
        )
    }
}
