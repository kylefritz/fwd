import Combine
import Foundation

public enum PillState: Equatable, Sendable {
    case off
    /// Host isn't connected yet; the host's own status explains why.
    case pending
    /// Forwarded, nothing listening on the remote yet.
    case waiting
    /// A server is listening on the remote port.
    case live
    /// Live, with a connection open through it right now.
    case active
    case blocked(String)
    case invalid(String)
}

/// One forwarded port under a wildcard entry.
public struct PillPort: Identifiable, Equatable, Sendable {
    public let remote: Int
    /// Nil when no laptop port could be found for it.
    public let local: Int?
    public let state: PillState
    public var id: Int { remote }
    public var openURL: URL? { local.map { ScreenSharing.url(remote: remote, local: $0) } }
}

/// One entry in a host's history, as the UI shows it.
public struct Pill: Identifiable, Equatable, Sendable {
    public let text: String
    public let on: Bool
    public let state: PillState
    public let isWildcard: Bool
    /// The laptop port to open in a browser, for a single-port entry that is up.
    public let local: Int?
    /// What to display: the entry text, or the real mapping if it was moved.
    public let label: String
    public let moved: Bool
    public let ports: [PillPort]
    /// The remote port of a single-port entry.
    public let remote: Int?
    public let name: String?
    /// Keeps the host connected while on.
    public let keep: Bool
    public var id: String { text }
    public var openURL: URL? {
        guard let remote, let local else { return nil }
        return ScreenSharing.url(remote: remote, local: local)
    }
    public var isScreenSharing: Bool { remote.map(ScreenSharing.vncPorts.contains) ?? false }
}

public struct ConfigPill: Identifiable, Equatable, Sendable {
    public let forward: ConfigForward
    public let status: ConfigForwardStatus
    public var id: String { "\(forward.kind.rawValue)-\(forward.listenPort)-\(forward.target)" }
}

public struct HostCard: Identifiable, Equatable, Sendable {
    public let name: String
    public let state: HostState
    public let statusLine: String
    public let pills: [Pill]
    public let configPills: [ConfigPill]
    public let lastError: String?
    /// False when the host has history but is no longer in the ssh config.
    public let inConfig: Bool
    public var id: String { name }
    /// Hosts with nothing to show are listed compactly instead of as a card.
    public var isProminent: Bool { !pills.isEmpty || !configPills.isEmpty }
}

public enum OverallState: Equatable, Sendable {
    case idle
    case forwarding
    case attention
}

public enum AppModelError: Error, CustomStringConvertible {
    case portsFileBroken

    public var description: String {
        "ports.yaml has an error. Fix or delete it, then try again."
    }
}

/// Everything the views show and every action they can take. Owns the
/// sessions, the files and the shared port allocator.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var cards: [HostCard] = []
    /// Set while ports.yaml can't be parsed; the app keeps its last good state.
    @Published public private(set) var fileError: String?
    @Published public private(set) var sshConfigMissing = false
    /// ssh's own complaint when it can't parse the config, if any.
    @Published public private(set) var sshConfigError: String?
    @Published public private(set) var overall: OverallState = .idle

    public let paths: Paths
    public let log: Log
    public let store: Store
    public let allocator: PortAllocator

    private let power: PowerEvents
    private let timing: Timing
    private let makeConnection: (String) -> Connection
    private let cleansLeftovers: Bool
    private let userSessions: () async -> Set<String>
    private let busyPorts: (Int32) async -> Set<Int>

    /// Hosts you have your own ssh session to, from the last look.
    private var openSessions: Set<String> = []
    private var lookingForSessions = false

    struct ScreenSharingUse {
        let port: String
        let started: Date
        var lastUsed: Date?
    }
    /// Screen Sharing entries the button turned on, by host.
    private var screenSharing: [String: ScreenSharingUse] = [:]

    private var file = PortsFile()
    private var sessions: [String: HostSession] = [:]
    private var configHosts: [String] = []
    private var configForwards: [String: [ConfigForward]] = [:]
    private var configStatus: [String: [ConfigForward: ConfigForwardStatus]] = [:]
    private var busy: [String: Set<Int>] = [:]

    private var portsStamp: Date?
    private var sshConfigStamp: [Date?] = []
    private var visible = false
    private var ticks = 0
    private var timer: Timer?
    private var rebuildQueued = false
    private var forwardsLoad: Task<Void, Never>?

    public init(paths: Paths = .fromEnvironment(), power: PowerEvents, timing: Timing = Timing(),
                log: Log? = nil, makeConnection: ((String) -> Connection)? = nil,
                isPortFree: @escaping (Int) -> Bool = PortAllocator.systemIsFree,
                userSessions: (() async -> Set<String>)? = nil,
                busyPorts: @escaping (Int32) async -> Set<Int> = TrafficSampler.busyPorts) {
        self.paths = paths
        self.userSessions = userSessions ?? { await UserSessions.current(paths: paths) }
        self.busyPorts = busyPorts
        self.power = power
        self.timing = timing
        let log = log ?? Log(file: paths.logFile)
        self.log = log
        self.store = Store(paths: paths)
        self.allocator = PortAllocator(sticky: Store(paths: paths).loadSticky(), isFree: isPortFree)
        self.cleansLeftovers = (makeConnection == nil)
        self.makeConnection = makeConnection ?? { host in SSHConnection(host: host, paths: paths, log: log) }
        allocator.onStickyChange = { [weak self] in
            guard let self else { return }
            self.store.saveSticky(self.allocator.sticky)
        }
    }

    // MARK: Lifecycle

    /// Loads files and begins forwarding. `runTimer` is off in tests, which
    /// call `tick()` themselves.
    public func start(runTimer: Bool = true) async {
        log.write("fwd started")
        if cleansLeftovers { await SSHConnection.closeLeftovers(paths: paths, log: log) }
        power.onEvent = { [weak self] event in
            Task { @MainActor in await self?.handle(event) }
        }
        reloadSSHConfig()
        openSessions = await userSessions()
        await reloadPorts(initial: true)
        if runTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.tick() }
            }
        }
    }

    public func shutdown() async {
        timer?.invalidate()
        forwardsLoad?.cancel()
        for session in sessions.values { await session.shutdown() }
        log.write("fwd stopped")
        log.flush()
    }

    private func handle(_ event: PowerEvent) async {
        log.write("event: \(event)")
        for session in sessions.values { await session.handle(event) }
    }

    /// Tells the model whether a panel or window is showing, so it only
    /// samples traffic and config-forward status while someone is looking.
    public func setVisible(_ visible: Bool) {
        self.visible = visible
        if visible {
            reloadSSHConfigIfChanged()
            Task { await refreshLiveStatus() }
        }
    }

    /// One second of housekeeping: pick up file edits, refresh live status.
    public func tick() async {
        ticks += 1
        if store.portsModified() != portsStamp { await reloadPorts(initial: false) }
        reloadSSHConfigIfChanged()
        if ticks % 2 == 0 { await refreshUserSessions() }
        if ticks % 5 == 0, !screenSharing.isEmpty { await checkScreenSharing() }
        if visible, ticks % 3 == 0 { await refreshLiveStatus() }
    }

    /// Looks for your own ssh sessions and tells each host whether it has one.
    /// Skipped while no host has a port on, since then nothing depends on it.
    func refreshUserSessions() async {
        guard !lookingForSessions else { return }
        guard sessions.values.contains(where: \.hasEnabledEntries) else {
            // Not looked at, so not trusted when a port is turned on later.
            openSessions = []
            return
        }
        lookingForSessions = true
        defer { lookingForSessions = false }
        openSessions = await userSessions()
        for (host, session) in sessions { await session.setUserSession(hasUserSession(host)) }
    }

    /// ssh matches host names case-insensitively, and so does this.
    private func hasUserSession(_ host: String) -> Bool { openSessions.contains(host.lowercased()) }

    // MARK: Files

    private func reloadPorts(initial: Bool) async {
        portsStamp = store.portsModified()
        do {
            let loaded = try store.loadPorts()
            if fileError != nil { log.write("ports.yaml is readable again") }
            fileError = nil
            if loaded != file || initial {
                if !initial { log.write("ports.yaml changed on disk; reloading") }
                file = loaded
                await apply()
            }
        } catch {
            let message = "\(error)".split(whereSeparator: \.isNewline).first.map(String.init) ?? "unreadable"
            if fileError != message { log.write("ports.yaml can't be read: \(message)") }
            fileError = message
            if initial { await apply() }
        }
        rebuild()
    }

    private func save() throws {
        guard fileError == nil else { throw AppModelError.portsFileBroken }
        try store.savePorts(file)
        portsStamp = store.portsModified()
    }

    private func sshConfigStamps() -> [Date?] {
        SSHConfig.files(configPath: paths.sshConfig).map {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
    }

    private func reloadSSHConfigIfChanged() {
        if sshConfigStamps() != sshConfigStamp { reloadSSHConfig() }
    }

    private func reloadSSHConfig() {
        sshConfigStamp = sshConfigStamps()
        sshConfigMissing = !FileManager.default.fileExists(atPath: paths.sshConfig.path)
        let hosts = SSHConfig.hosts(configPath: paths.sshConfig)
        if hosts != configHosts { log.write("ssh config: \(hosts.count) hosts") }
        configHosts = hosts
        queueRebuild()

        // `ssh -G` per host is slow for big configs, so it runs off to the side.
        forwardsLoad?.cancel()
        let paths = self.paths
        forwardsLoad = Task { [weak self] in
            let problem = await ConfigForwards.configProblem(paths: paths)
            if Task.isCancelled { return }
            self?.noteConfigProblem(problem)
            var found: [String: [ConfigForward]] = [:]
            for host in hosts {
                if Task.isCancelled { return }
                let forwards = await ConfigForwards.load(host: host, paths: paths)
                if !forwards.isEmpty { found[host] = forwards }
            }
            if Task.isCancelled { return }
            guard let self else { return }
            self.configForwards = found
            await self.refreshLiveStatus()
        }
    }

    private func noteConfigProblem(_ problem: String?) {
        if let problem, problem != sshConfigError { log.write("ssh config problem: \(problem)") }
        sshConfigError = problem
    }

    // MARK: Actions

    /// Adds `text` (a port pattern, optionally followed by a name) and turns
    /// it on. An entry that's already there is turned on, and renamed if a
    /// name was given.
    public func add(host: String, text: String) async throws {
        let (portText, name) = EntryName.split(text)
        let pattern = try PortPattern.parse(portText)
        await syncFromDisk()
        var entries = file.hosts[host] ?? []
        if let index = entries.firstIndex(where: { $0.port == pattern.text }) {
            entries[index].on = true
            if let name { entries[index].name = name }
        } else {
            entries.append(Entry(port: pattern.text, on: true, name: name))
        }
        try await update(host: host, entries: entries)
        await sessions[host]?.connect()
    }

    /// Sets or clears (with an empty string) an entry's name.
    public func rename(host: String, text: String, to name: String) async throws {
        await syncFromDisk()
        var entries = file.hosts[host] ?? []
        guard let index = entries.firstIndex(where: { $0.port == text }) else { return }
        entries[index].name = EntryName.clean(name)
        try await update(host: host, entries: entries)
    }

    public func toggle(host: String, text: String) async throws {
        await syncFromDisk()
        var entries = file.hosts[host] ?? []
        guard let index = entries.firstIndex(where: { $0.port == text }) else { return }
        entries[index].on.toggle()
        let turnedOn = entries[index].on
        if !turnedOn {
            forget(host: host, text: text)
            if entries[index].port == screenSharing[host]?.port { screenSharing[host] = nil }
        }
        try await update(host: host, entries: entries)
        if turnedOn { await sessions[host]?.connect() }
    }

    /// Marks an entry keep connected, or not.
    public func setKeep(host: String, text: String, keep: Bool) async throws {
        await syncFromDisk()
        var entries = file.hosts[host] ?? []
        guard let index = entries.firstIndex(where: { $0.port == text }) else { return }
        entries[index].keep = keep
        if keep, entries[index].port == screenSharing[host]?.port { screenSharing[host] = nil }
        try await update(host: host, entries: entries)
    }

    public func remove(host: String, text: String) async throws {
        await syncFromDisk()
        let entries = (file.hosts[host] ?? []).filter { $0.port != text }
        forget(host: host, text: text)
        try await update(host: host, entries: entries)
    }

    public func clearAll(host: String) async throws {
        await syncFromDisk()
        allocator.forget(keyPrefix: "\(host)|")
        try await update(host: host, entries: [])
    }

    public func turnAllOff() async throws {
        await syncFromDisk()
        guard fileError == nil else { throw AppModelError.portsFileBroken }
        for (host, entries) in file.hosts {
            var off = entries
            for i in off.indices { off[i].on = false }
            file.hosts[host] = off
            allocator.forget(keyPrefix: "\(host)|")
        }
        try save()
        log.write("turned all off")
        screenSharing = [:]
        await apply()
    }

    /// Makes sure the host's Screen Sharing port is forwarded, adding or
    /// turning on its entry, and returns the `vnc://` URL once it's up.
    public func screenSharingURL(host: String, timeout: Double = 30) async throws -> URL {
        await syncFromDisk()
        func vncEntry() -> Entry? {
            (file.hosts[host] ?? []).first {
                guard let pattern = try? PortPattern.parse($0.port) else { return false }
                return !pattern.isWildcard && pattern.remoteRange.lowerBound == ScreenSharing.remotePort
            }
        }
        // Only a forward this click turns on is turned off again afterwards;
        // one you had on already is yours.
        let turningOn = vncEntry()?.on != true
        if let existing = vncEntry() {
            if !existing.on { try await toggle(host: host, text: existing.port) }
        } else {
            try await add(host: host, text: "\(ScreenSharing.entryText) \(ScreenSharing.entryName)")
        }
        await sessions[host]?.connect()
        let user = await ScreenSharing.user(host: host, paths: paths)
        let remote = ScreenSharing.remotePort
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let session = sessions[host] {
                if case .needsAttention(let message) = session.state {
                    throw ScreenSharingError.hostProblem(message)
                }
                if let reason = session.blocked[remote] { throw ScreenSharingError.blocked(reason) }
                // The scan runs before forwards are added, so by now it has
                // answered whether anything listens on 5900.
                if session.state == .connected, let forward = session.active[remote] {
                    if let listening = session.listening, !listening.contains(remote) {
                        throw ScreenSharingError.notSharing(host)
                    }
                    log.write("opening Screen Sharing on localhost:\(forward.local)", host: host)
                    if turningOn, let entry = vncEntry(), !entry.keep {
                        screenSharing[host] = ScreenSharingUse(port: entry.port, started: Date())
                    }
                    return ScreenSharing.url(local: forward.local, user: user)
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw ScreenSharingError.timedOut(host)
    }

    /// The Retry and Connect buttons.
    public func connect(host: String) async {
        await sessions[host]?.connect()
    }

    /// Turns a Screen Sharing entry the button turned on back off once the
    /// viewer has gone: no connection through it for a while after one was
    /// seen, or none at all for longer. A kept entry is left alone.
    func checkScreenSharing() async {
        let now = Date()
        for (host, use) in screenSharing {
            var use = use
            let session = sessions[host]
            if let session, session.state == .connected, let pid = session.masterPID,
               let forward = session.active[ScreenSharing.remotePort],
               await busyPorts(pid).contains(forward.local) {
                use.lastUsed = now
            }
            let idleFor = now.timeIntervalSince(use.lastUsed ?? use.started)
            let limit = use.lastUsed == nil ? timing.screenSharingUnused : timing.screenSharingIdle
            guard screenSharing[host] != nil else { continue }
            guard idleFor >= limit else {
                screenSharing[host] = use
                continue
            }
            screenSharing[host] = nil
            await syncFromDisk()
            guard var entries = file.hosts[host],
                  let index = entries.firstIndex(where: { $0.port == use.port && $0.on && !$0.keep }) else { continue }
            log.write("Screen Sharing not in use; turning \(use.port) off", host: host)
            entries[index].on = false
            try? await update(host: host, entries: entries)
        }
    }

    private func forget(host: String, text: String) {
        allocator.forget(keyPrefix: "\(host)|\(text)|")
    }

    /// A hand edit made a moment ago may not have been noticed yet. Load it
    /// before changing anything, so an action never overwrites it.
    private func syncFromDisk() async {
        if store.portsModified() != portsStamp { await reloadPorts(initial: false) }
    }

    private func update(host: String, entries: [Entry]) async throws {
        guard fileError == nil else { throw AppModelError.portsFileBroken }
        let previous = file
        // Losing the last kept port (unchecked, turned off or removed) counts
        // as a click, so the host's other forwards don't drop mid-use.
        func keeps(_ list: [Entry]?) -> Bool { list?.contains { $0.on && $0.keep } ?? false }
        if keeps(file.hosts[host]), !keeps(entries) { sessions[host]?.holdWhileConnected() }
        if entries.isEmpty { file.hosts[host] = nil } else { file.hosts[host] = entries }
        do {
            try save()
        } catch {
            file = previous
            throw error
        }
        let described = entries.map { "\($0.port)\($0.on ? "" : " (off)")\($0.keep ? " (keep)" : "")" }
        log.write("entries now: \(described.joined(separator: ", "))", host: host)
        await apply()
    }

    /// Pushes the desired entries into the sessions.
    private func apply() async {
        // Each step awaits, and another action can change `file` meanwhile,
        // so read the current entries at every step instead of a snapshot.
        for host in Array(file.hosts.keys) {
            guard let entries = file.hosts[host] else { continue }
            let session = session(for: host)
            await session.setUserSession(hasUserSession(host))
            await session.setEntries(entries)
        }
        for (host, session) in sessions where file.hosts[host] == nil {
            guard file.hosts[host] == nil else { continue }
            await session.setEntries([])
        }
        rebuild()
    }

    private func session(for host: String) -> HostSession {
        if let existing = sessions[host] { return existing }
        let make = makeConnection
        let session = HostSession(host: host, makeConnection: { make(host) }, allocator: allocator,
                                  power: power, timing: timing, log: log)
        session.onChange = { [weak self] in self?.queueRebuild() }
        sessions[host] = session
        return session
    }

    // MARK: Live status

    private func refreshLiveStatus() async {
        let masters = Set(sessions.values.compactMap(\.masterPID))
        var status: [String: [ConfigForward: ConfigForwardStatus]] = [:]
        for (host, forwards) in configForwards {
            for forward in forwards {
                switch forward.kind {
                case .local:
                    status[host, default: [:]][forward] =
                        await ConfigForwards.localStatus(port: forward.listenPort, fwdMasters: masters)
                case .remote:
                    if let session = sessions[host], session.state == .connected, let listening = session.listening {
                        status[host, default: [:]][forward] = listening.contains(forward.listenPort) ? .on : .notForwarded
                    } else {
                        status[host, default: [:]][forward] = .unknown
                    }
                }
            }
        }
        configStatus = status

        var nowBusy: [String: Set<Int>] = [:]
        for (host, session) in sessions where session.state == .connected {
            if let pid = session.masterPID, !session.active.isEmpty {
                nowBusy[host] = await TrafficSampler.busyPorts(masterPID: pid)
            }
        }
        busy = nowBusy
        rebuild()
    }

    // MARK: Building what the views show

    private func queueRebuild() {
        guard !rebuildQueued else { return }
        rebuildQueued = true
        Task { @MainActor in
            self.rebuildQueued = false
            self.rebuild()
        }
    }

    private func rebuild() {
        var names = configHosts
        for host in file.hosts.keys.sorted() where !names.contains(host) { names.append(host) }
        let inConfig = Set(configHosts)

        var built = names.map { name -> HostCard in
            let session = sessions[name]
            let state = session?.state ?? .idle
            let pills = (file.hosts[name] ?? []).map { pill(for: $0, host: name, session: session) }
            let configPills = (configForwards[name] ?? []).map {
                ConfigPill(forward: $0, status: configStatus[name]?[$0] ?? .unknown)
            }
            return HostCard(name: name, state: state,
                            statusLine: statusLine(state, session: session),
                            pills: pills, configPills: configPills,
                            lastError: session?.lastError, inConfig: inConfig.contains(name))
        }
        // Hosts in use first, in config order; the stable sort keeps that order.
        built.sort { rank($0) < rank($1) }
        if built != cards { cards = built }

        let states = sessions.values.map(\.state)
        let newOverall: OverallState
        if fileError != nil || states.contains(where: {
            if case .needsAttention = $0 { return true }
            return $0 == .retrying || $0 == .connecting
        }) {
            newOverall = .attention
        } else if states.contains(.connected) {
            newOverall = .forwarding
        } else {
            newOverall = .idle
        }
        if newOverall != overall { overall = newOverall }
    }

    private func rank(_ card: HostCard) -> Int {
        if !card.pills.isEmpty { return 0 }
        if !card.configPills.isEmpty { return 1 }
        return 2
    }

    private func statusLine(_ state: HostState, session: HostSession?) -> String {
        switch state {
        case .idle: return ""
        case .standby: return "Not connected · starts when you ssh in"
        case .connecting: return "Connecting…"
        case .connected:
            let count = session?.active.count ?? 0
            return count == 0 ? "Connected" : "Connected · \(count) forwarded"
        case .retrying:
            return "Reconnecting…" + (session?.lastError.map { " \($0)" } ?? "")
        case .paused(let why): return "Paused (\(why))"
        case .needsAttention(let message): return message
        }
    }

    private func portState(remote: Int, local: Int, host: String, session: HostSession) -> PillState {
        guard session.listening?.contains(remote) == true else { return .waiting }
        return busy[host]?.contains(local) == true ? .active : .live
    }

    private func pill(for entry: Entry, host: String, session: HostSession?) -> Pill {
        var remote: Int?
        func make(_ state: PillState, wildcard: Bool = false, local: Int? = nil, label: String? = nil,
                  moved: Bool = false, ports: [PillPort] = []) -> Pill {
            Pill(text: entry.port, on: entry.on, state: state, isWildcard: wildcard, local: local,
                 label: label ?? entry.port, moved: moved, ports: ports, remote: remote, name: entry.name, keep: entry.keep)
        }
        let pattern: PortPattern
        do {
            pattern = try PortPattern.parse(entry.port)
        } catch {
            return make(.invalid("\(error)"))
        }
        remote = pattern.isWildcard ? nil : pattern.remoteRange.lowerBound
        guard entry.on else { return make(.off, wildcard: pattern.isWildcard) }
        guard let session, session.state == .connected else {
            return make(.pending, wildcard: pattern.isWildcard)
        }

        if pattern.isWildcard {
            if session.scanUnavailable {
                return make(.blocked("Can't scan this host for listening ports"), wildcard: true)
            }
            var ports = session.active.values
                .filter { $0.entry == pattern.text }
                .map { PillPort(remote: $0.remote, local: $0.local,
                                state: portState(remote: $0.remote, local: $0.local, host: host, session: session)) }
            for (remote, reason) in session.blocked
            where pattern.remoteRange.contains(remote) && session.active[remote] == nil {
                ports.append(PillPort(remote: remote, local: nil, state: .blocked(reason)))
            }
            ports.sort { $0.remote < $1.remote }
            let up = ports.filter { $0.local != nil }
            let state: PillState
            if ports.isEmpty {
                state = .waiting
            } else if up.isEmpty, case .blocked(let reason)? = ports.first?.state {
                state = .blocked(reason)
            } else {
                state = up.contains { $0.state == .active } ? .active : .live
            }
            return make(state, wildcard: true, ports: ports)
        }

        let remotePort = pattern.remoteRange.lowerBound
        if let reason = session.blocked[remotePort] { return make(.blocked(reason)) }
        guard let forward = session.active[remotePort], forward.entry == pattern.text else {
            return make(.pending)
        }
        let wanted = pattern.laptopPort(for: remotePort)
        let moved = forward.local != wanted
        let label = (forward.local == remotePort) ? "\(remotePort)" : "\(remotePort) → \(forward.local)"
        return make(portState(remote: remotePort, local: forward.local, host: host, session: session),
                    local: forward.local, label: label, moved: moved)
    }
}
