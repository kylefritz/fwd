import Foundation

/// A named forward's address, like `web.localhost`. `*.localhost` already
/// points at this Mac, so naming one needs no DNS or password; only the proxy
/// on port 80 (`NameProxy`) is new.
public struct ForwardAddress: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case off
        case notConnected
        case connecting
        /// Connected, nothing listening on the remote port yet. `local` is
        /// the laptop port, if the forward is up anyway.
        case waiting(local: Int?)
        case ready(local: Int)
        /// ssh needs a person, with its message.
        case needsPerson(String)
        case blocked(String)
    }

    public static let domain = "localhost"

    public let address: String
    public let name: String
    public let host: String
    /// The entry's text in ports.yaml.
    public let text: String
    public let remote: Int
    public let status: Status
    /// Another entry on this host has the same address. Only the first, by
    /// remote port, gets it.
    public let duplicate: Bool
    public var id: String { "\(host)|\(text)" }

    public init(address: String, name: String, host: String, text: String, remote: Int, status: Status,
                duplicate: Bool = false) {
        self.address = address
        self.name = name
        self.host = host
        self.text = text
        self.remote = remote
        self.status = status
        self.duplicate = duplicate
    }

    /// `name` as it can appear in an address, or nil if nothing is left of it.
    /// Names may have spaces and capitals; addresses can't.
    public static func slug(_ name: String) -> String? {
        let folded = name.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US")).lowercased()
        let words = folded.split { !("a"..."z").contains($0) && !("0"..."9").contains($0) }
        return words.isEmpty ? nil : String(words.joined(separator: "-").prefix(63))
    }

    fileprivate static func status(of pill: Pill, on state: HostState) -> Status? {
        switch pill.state {
        case .off: return .off
        case .invalid: return nil
        case .blocked(let reason): return .blocked(reason)
        case .waiting: return .waiting(local: pill.local)
        case .live, .active: return pill.local.map { .ready(local: $0) } ?? .connecting
        case .pending:
            switch state {
            case .idle, .standby, .paused: return .notConnected
            case .connecting, .retrying, .connected: return .connecting
            case .needsAttention(let message): return .needsPerson(message)
            }
        }
    }
}

/// Where a request for an address goes.
public enum NameRoute: Equatable, Sendable {
    case forward(ForwardAddress, port: Int)
    case page(NamePage)
}

/// What fwd answers itself when it can't pass a request through.
public enum NamePage: Equatable, Sendable {
    /// The forward isn't up; `status` says why.
    case down(ForwardAddress)
    /// The forward looked up, but its laptop port refused.
    case unreachable(ForwardAddress)
    /// A name on more than one host.
    case several(String, [ForwardAddress])
    case unknown(String)
}

/// The addresses for the forwards the panel shows. A value, rebuilt from the
/// cards, so what the proxy answers always matches what the window lists.
public struct AddressBook: Sendable {
    /// Sorted by address, then host.
    public let addresses: [ForwardAddress]
    private let byAddress: [String: ForwardAddress]
    private let shared: [String: [ForwardAddress]]

    public init(cards: [HostCard]) {
        struct Named {
            let slug: String
            let pill: Pill
            let remote: Int
            let card: HostCard
            let status: ForwardAddress.Status
        }
        var found: [Named] = []
        for card in cards {
            for pill in card.pills {
                // A name has to mean one port, and Screen Sharing isn't a web app.
                guard let remote = pill.remote, !pill.isScreenSharing, let name = pill.name,
                      let slug = ForwardAddress.slug(name),
                      let status = ForwardAddress.status(of: pill, on: card.state) else { continue }
                found.append(Named(slug: slug, pill: pill, remote: remote, card: card, status: status))
            }
        }

        var built: [ForwardAddress] = []
        var taken: [String: ForwardAddress] = [:]
        var several: [String: [ForwardAddress]] = [:]
        // Off entries count and remote ports decide, so an address doesn't
        // move when something is switched on or off.
        for (slug, group) in Dictionary(grouping: found, by: \.slug) {
            let onHosts = Set(group.map(\.card.name))
            for item in group.sorted(by: { ($0.card.name, $0.remote) < ($1.card.name, $1.remote) }) {
                let address = onHosts.count > 1
                    ? "\(slug).\(ForwardAddress.slug(item.card.name) ?? "host").\(ForwardAddress.domain)"
                    : "\(slug).\(ForwardAddress.domain)"
                let forward = ForwardAddress(address: address, name: item.pill.name ?? slug, host: item.card.name,
                                             text: item.pill.text, remote: item.remote, status: item.status,
                                             duplicate: taken[address] != nil)
                built.append(forward)
                if !forward.duplicate {
                    taken[address] = forward
                    if onHosts.count > 1 { several[slug, default: []].append(forward) }
                }
            }
        }
        addresses = built.sorted { ($0.address, $0.host, $0.remote) < ($1.address, $1.host, $1.remote) }
        byAddress = taken
        shared = several
    }

    /// Where a request with this `Host` header goes.
    public func route(hostHeader: String) -> NameRoute {
        var name = hostHeader.lowercased()
        if let colon = name.lastIndex(of: ":"), !name.hasSuffix("]") { name = String(name[..<colon]) }
        if name.hasSuffix(".") { name.removeLast() }
        if let forward = byAddress[name] {
            if case .ready(let local) = forward.status { return .forward(forward, port: local) }
            return .page(.down(forward))
        }
        let suffix = ".\(ForwardAddress.domain)"
        if name.hasSuffix(suffix), let found = shared[String(name.dropLast(suffix.count))] {
            return .page(.several(String(name.dropLast(suffix.count)), found))
        }
        return .page(.unknown(hostHeader))
    }
}
