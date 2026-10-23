import Foundation

/// Runs command-line requests against the app, through the same actions the
/// panel uses, and answers with the hosts and ports as the panel shows them.
@MainActor
public final class ControlHandler {
    private let model: AppModel
    private let open: (URL) -> Void
    private let openInVSCode: (String) async throws -> Void
    private let switchBuild: (SwitchTarget, Double) async throws -> String
    private let pollInterval: Double

    public init(model: AppModel, open: @escaping (URL) -> Void,
                openInVSCode: @escaping (String) async throws -> Void = { _ in throw VSCodeError.notInstalled },
                switchBuild: @escaping (SwitchTarget, Double) async throws -> String = { _, _ in
                    throw SwitchError.failed("this copy of fwd can't switch builds")
                },
                pollInterval: Double = 0.2) {
        self.model = model
        self.open = open
        self.openInVSCode = openInVSCode
        self.switchBuild = switchBuild
        self.pollInterval = pollInterval
    }

    public func handle(_ request: ControlRequest) async -> ControlReply {
        guard request.v == ControlRequest.version else { return .failure(.versionMismatch) }
        model.log.write("cli: \(([request.cmd] + request.args).joined(separator: " "))")
        do {
            switch request.cmd {
            case "status": return try status(request)
            case "forward": return try await forward(request)
            case "wait": return try await wait(request)
            case "off": return try await off(request)
            case "remove": return try await remove(request)
            case "keep": return try await keep(request)
            case "connect": return try await connect(request)
            case "screen": return try await screen(request)
            case "code": return try await code(request)
            case "try": return try await tryBuild(request)
            default: throw ControlError.usage("unknown command \(request.cmd) (try fwd --help)")
            }
        } catch let error as ControlError {
            return .failure(error)
        } catch let error as PortPattern.ParseError {
            return .failure(.usage("\(error)"))
        } catch {
            return .failure(.failed("\(error)"))
        }
    }

    // MARK: Reading the cards

    private var cards: [HostCard] { model.cards }
    private func card(_ host: String) -> HostCard? { cards.first { $0.name == host } }
    private var connected: [String] { cards.filter { $0.state == .connected }.map(\.name) }

    private func target(_ request: ControlRequest, needsPorts: Bool) throws -> ControlTarget {
        let target = try ControlTarget.resolve(request.args, hosts: cards.map(\.name),
                                               defaultHosts: connected, noun: "connected")
        if needsPorts, target.ports.isEmpty {
            throw ControlError.usage("say which port, like: fwd \(target.host) 3000")
        }
        return target
    }

    /// The host with only the named ports, or an empty one if it has no card.
    private func info(_ host: String, ports: [String]? = nil) -> HostInfo {
        guard let card = card(host) else {
            return HostInfo(host: host, state: "idle", status: "", inSSHConfig: false, ports: [])
        }
        return HostInfo(card: card, only: ports.map { Set($0.compactMap(ControlTarget.canonical)) })
    }

    /// Lets queued card rebuilds run, then checks `done` every poll until it
    /// gives an answer or the time runs out. It sleeps before the first
    /// check: right after a click the cards still show the moment before.
    private func until(_ timeout: Double, what: String,
                       _ done: () -> ControlReply?) async throws -> ControlReply {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if let reply = done() { return reply }
            if Date() >= deadline {
                throw ControlError.timedOut("timed out after \(Int(timeout.rounded(.up)))s waiting for \(what)")
            }
        }
    }

    /// Why a host can't get anywhere right now, if it can't.
    private func stuck(_ card: HostCard) -> ControlError? {
        switch card.state {
        case .needsAttention(let message):
            return .failed("\(card.name) needs you: \(message) Run: fwd connect \(card.name) after fixing it")
        case .standby:
            return .failed("couldn't connect to \(card.name)" + (card.lastError.map { ": \($0)" } ?? ""))
        default:
            return nil
        }
    }

    /// A command on ports that aren't in the host's list does nothing, so
    /// it says so instead of answering with an empty success.
    private func requireListed(_ target: ControlTarget) throws {
        let listed = Set(card(target.host)?.pills.map(\.text) ?? [])
        for port in target.ports {
            guard let text = ControlTarget.canonical(port), listed.contains(text) else {
                throw ControlError.failed("\(ControlTarget.canonical(port) ?? port) isn't in \(target.host)'s list")
            }
        }
    }

    // MARK: Commands

    private func status(_ request: ControlRequest) throws -> ControlReply {
        let host = request.args.first
        let shown = cards.filter { card in
            if let host { return card.name == host }
            return request.all || !card.pills.isEmpty || card.state == .connected
        }
        if let host, shown.isEmpty { throw ControlError.usage("\"\(host)\" isn't a host fwd knows") }
        return .success(hosts: shown.map { HostInfo(card: $0) })
    }

    private func forward(_ request: ControlRequest) async throws -> ControlReply {
        let target = try target(request, needsPorts: true)
        for port in target.ports {
            try await model.add(host: target.host, text: port)
            if request.keep, let text = ControlTarget.canonical(port) {
                try await model.setKeep(host: target.host, text: text, keep: true)
            }
        }
        let wanted = Set(target.ports.compactMap(ControlTarget.canonical))
        let what = request.wait ? "a server on \(target.host)" : "\(target.host) to forward"
        return try await until(request.timeout ?? 30, what: what) {
            guard let card = card(target.host) else { return nil }
            let host = HostInfo(card: card, only: wanted)
            if let error = stuck(card) { return .failure(error, host: host) }
            if let blocked = host.ports.first(where: { $0.state == "blocked" }) {
                return .failure(.failed("\(blocked.port) is blocked: \(blocked.reason ?? "")"), host: host)
            }
            guard card.state == .connected else { return nil }
            let done = host.ports.allSatisfy { port in
                if request.wait { return port.isLive }
                // A range is forwarded once the host is, whatever it matches yet.
                if port.port.contains("*") { return true }
                return port.isForwarded
            }
            return done ? .success(host: host) : nil
        }
    }

    private func wait(_ request: ControlRequest) async throws -> ControlReply {
        let target = try target(request, needsPorts: true)
        guard target.ports.count == 1, let text = ControlTarget.canonical(target.ports[0]) else {
            throw ControlError.usage("wait takes one port, like: fwd wait \(target.host) 3000")
        }
        guard card(target.host)?.pills.first(where: { $0.text == text })?.on == true else {
            throw ControlError.failed("\(text) isn't on for \(target.host); run: fwd \(target.host) \(text)")
        }
        return try await until(request.timeout ?? 60, what: "a server on \(target.host) \(text)") {
            guard let card = card(target.host) else { return nil }
            let host = HostInfo(card: card, only: [text])
            if case .needsAttention = card.state, let error = stuck(card) { return .failure(error, host: host) }
            return host.ports.first?.isLive == true ? .success(host: host) : nil
        }
    }

    private func off(_ request: ControlRequest) async throws -> ControlReply {
        let target = try target(request, needsPorts: true)
        try requireListed(target)
        for port in target.ports {
            guard let text = ControlTarget.canonical(port) else { continue }
            if card(target.host)?.pills.first(where: { $0.text == text })?.on == true {
                try await model.toggle(host: target.host, text: text)
            }
        }
        return .success(host: info(target.host, ports: target.ports))
    }

    private func remove(_ request: ControlRequest) async throws -> ControlReply {
        let target = try target(request, needsPorts: true)
        try requireListed(target)
        for port in target.ports {
            if let text = ControlTarget.canonical(port) { try await model.remove(host: target.host, text: text) }
        }
        return .success(host: info(target.host, ports: target.ports))
    }

    private func keep(_ request: ControlRequest) async throws -> ControlReply {
        let target = try target(request, needsPorts: true)
        try requireListed(target)
        for port in target.ports {
            if let text = ControlTarget.canonical(port) {
                try await model.setKeep(host: target.host, text: text, keep: !request.off)
            }
        }
        return .success(host: info(target.host, ports: target.ports))
    }

    private func connect(_ request: ControlRequest) async throws -> ControlReply {
        // Here the host left out is the one host waiting to connect.
        let waiting = cards.filter { $0.state != .connected && $0.pills.contains(where: \.on) }.map(\.name)
        let target = try ControlTarget.resolve(request.args, hosts: cards.map(\.name),
                                               defaultHosts: waiting, noun: "waiting to connect")
        guard card(target.host)?.pills.contains(where: \.on) == true else {
            throw ControlError.failed("\(target.host) has no ports on; forward one first, like: fwd \(target.host) 3000")
        }
        await model.connect(host: target.host)
        return try await until(request.timeout ?? 30, what: "\(target.host) to connect") {
            guard let card = card(target.host) else { return nil }
            if let error = stuck(card) { return .failure(error, host: HostInfo(card: card)) }
            return card.state == .connected ? .success(host: HostInfo(card: card)) : nil
        }
    }

    private func screen(_ request: ControlRequest) async throws -> ControlReply {
        let target = try target(request, needsPorts: false)
        let url = try await model.screenSharingURL(host: target.host)
        open(url)
        return .success(host: info(target.host), url: url.absoluteString)
    }

    private func code(_ request: ControlRequest) async throws -> ControlReply {
        let target = try target(request, needsPorts: false)
        guard card(target.host)?.inConfig == true else {
            throw ControlError.failed("\(target.host) isn't in your ssh config, so VS Code can't reach it")
        }
        try await openInVSCode(target.host)
        return .success(host: info(target.host))
    }

    /// Readies another build; the app restarts into it after answering.
    private func tryBuild(_ request: ControlRequest) async throws -> ControlReply {
        guard request.args.count == 1, let target = SwitchTarget(request.args[0]) else {
            throw ControlError.usage("say which build, like: fwd try 42 (a pull request), fwd try beta, fwd try stable")
        }
        let version: String
        do {
            // The command line waits 10s longer than this, so it hears either way.
            version = try await switchBuild(target, request.timeout ?? 60)
        } catch let error as SwitchError {
            if case .timedOut = error { throw ControlError.timedOut("\(error)") }
            throw ControlError.failed("\(error)")
        }
        let what: String
        switch target {
        case .pullRequest(let n): what = "PR #\(n)'s preview (\(version))"
        case .beta: what = "the newest beta (\(version))"
        case .stable: what = "the newest release (\(version))"
        }
        return .success(message: "fwd is restarting into \(what).")
    }
}
