import Foundation

/// Picks laptop ports. If the wanted port is unavailable it takes the next
/// free one upward, and remembers that choice so URLs stay stable.
public final class PortAllocator {
    public static let searchSpan = 50

    /// key -> laptop port, only for entries that were moved off their wanted port.
    public private(set) var sticky: [String: Int]
    /// Ports currently handed out by this allocator.
    public private(set) var held = Set<Int>()
    private let isFree: (Int) -> Bool
    public var onStickyChange: (() -> Void)?

    public init(sticky: [String: Int] = [:], isFree: @escaping (Int) -> Bool = PortAllocator.systemIsFree) {
        self.sticky = sticky
        self.isFree = isFree
    }

    private func usable(_ port: Int) -> Bool {
        (PortPattern.lowestLaptopPort...PortPattern.highestPort).contains(port)
            && !held.contains(port) && isFree(port)
    }

    /// Returns a laptop port for `wanted` and marks it held, or nil when
    /// nothing is free within `searchSpan` ports.
    public func allocate(wanted: Int, key: String) -> Int? {
        if let remembered = sticky[key], usable(remembered) {
            held.insert(remembered)
            return remembered
        }
        for port in wanted..<(wanted + Self.searchSpan) where usable(port) {
            held.insert(port)
            let previous = sticky[key]
            if port == wanted { sticky[key] = nil } else { sticky[key] = port }
            if sticky[key] != previous { onStickyChange?() }
            return port
        }
        return nil
    }

    public func release(_ port: Int) {
        held.remove(port)
    }

    /// Drops remembered assignments, so the next allocation starts from the
    /// wanted port again. Used when an entry is toggled off or removed.
    public func forget(keyPrefix: String) {
        let before = sticky.count
        sticky = sticky.filter { !$0.key.hasPrefix(keyPrefix) }
        if sticky.count != before { onStickyChange?() }
    }

    /// True if nothing answers on localhost:port and ssh could bind it.
    ///
    /// Binding alone isn't enough: a server listening on all interfaces, or
    /// only on IPv6, still lets 127.0.0.1 be bound, and a forward there
    /// would shadow it. So this also tries to connect over both IPv4 and
    /// IPv6 and treats any answer as "taken".
    public static func systemIsFree(_ port: Int) -> Bool {
        canBind(port) && !answers(port, family: AF_INET) && !answers(port, family: AF_INET6)
    }

    private static func answers(_ port: Int, family: Int32) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            } == 0
        }
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(port).bigEndian
        addr.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        } == 0
    }

    private static func canBind(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // Match ssh's own listener options so the answer predicts its bind.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
