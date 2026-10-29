import Foundation

public enum HostState: Equatable, Sendable {
    /// Nothing enabled, so no connection.
    case idle
    /// Ports are on but nothing asks for a connection: no ssh session of
    /// yours, no keep-connected entry, no recent click.
    case standby
    case connecting
    case connected
    /// Link is down; another attempt is scheduled.
    case retrying
    /// Asleep or no network. Nothing is polling.
    case paused(String)
    /// ssh needs a person. Not retrying.
    case needsAttention(String)
}

/// Intervals, in seconds. Tests shrink them.
public struct Timing: Sendable {
    public var retrySchedule: [Double]
    public var steadyRetry: Double
    public var scanInterval: Double
    public var settle: Double
    /// How long a Screen Sharing forward the button opened stays on with no
    /// viewer: after one has been seen, and if none ever connects.
    public var screenSharingIdle: Double
    public var screenSharingUnused: Double

    public init(retrySchedule: [Double] = [2, 5, 15, 30], steadyRetry: Double = 60,
                scanInterval: Double = 5, settle: Double = 1,
                screenSharingIdle: Double = 30, screenSharingUnused: Double = 120) {
        self.retrySchedule = retrySchedule
        self.steadyRetry = steadyRetry
        self.scanInterval = scanInterval
        self.settle = settle
        self.screenSharingIdle = screenSharingIdle
        self.screenSharingUnused = screenSharingUnused
    }
}

/// Keeps one host's forwards matching its entries while something asks for
/// a connection: your own ssh session to the host, an entry marked keep
/// connected, or a click. Only the first two reconnect after a drop, sleep
/// or network change; a click connects once.
@MainActor
public final class HostSession {
    public let host: String
    public private(set) var state: HostState = .idle
    public private(set) var entries: [Entry] = []
    /// Live forwards, by remote port.
    public private(set) var active: [Int: Forward] = [:]
    /// Remote ports that should be forwarded but couldn't be, with the reason.
    public private(set) var blocked: [Int: String] = [:]
    /// Remote listening ports from the last scan; nil before the first scan
    /// or when the remote can't be scanned.
    public private(set) var listening: Set<Int>?
    public private(set) var scanUnavailable = false
    public private(set) var lastError: String?
    public var onChange: (() -> Void)?

    public var masterPID: Int32? { connection?.masterPID }

    private let makeConnection: () -> Connection
    private let allocator: PortAllocator
    private let timing: Timing
    private let log: Log
    private let power: PowerEvents

    private var connection: Connection?
    private var generation = 0
    private var napTask: Task<Void, Never>?
    private var reconcileTail: Task<Void, Never>?
    private var asleep = false
    private var linkAlive = false
    private var running = false
    /// You have your own ssh session to this host open.
    private var userSession = false
    /// You clicked something that connects. Lasts until the link drops, a
    /// first attempt gives up, or the laptop sleeps.
    private var clicked = false

    public init(host: String, makeConnection: @escaping () -> Connection, allocator: PortAllocator,
                power: PowerEvents, timing: Timing = Timing(), log: Log) {
        self.host = host
        self.makeConnection = makeConnection
        self.allocator = allocator
        self.power = power
        self.timing = timing
        self.log = log
    }

    private var patterns: [PortPattern] {
        entries.filter(\.on).compactMap { try? PortPattern.parse($0.port) }
    }

    private var keeps: Bool {
        entries.contains { $0.on && $0.keep && (try? PortPattern.parse($0.port)) != nil }
    }

    /// Reasons that survive a drop, so the session reconnects on its own.
    private var reconnects: Bool { keeps || userSession }

    private var wantsConnection: Bool { !patterns.isEmpty && (reconnects || clicked) }

    /// Some valid entry is on, so a connection could be wanted.
    public var hasEnabledEntries: Bool { !patterns.isEmpty }

    public static func stickyKey(host: String, entry: String, remote: Int) -> String {
        "\(host)|\(entry)|\(remote)"
    }

    // MARK: Inputs

    public func setEntries(_ new: [Entry]) async {
        guard new != entries else { return }
        entries = new
        await settle()
    }

    /// Whether you have your own ssh session to this host open right now.
    public func setUserSession(_ open: Bool) async {
        guard open != userSession else { return }
        userSession = open
        if !patterns.isEmpty {
            log.write(open ? "your ssh session opened" : "your ssh session closed", host: host)
        }
        await settle()
    }

    /// Runs `command` over the live connection, or returns nil when there
    /// isn't one. Never connects.
    public func runIfConnected(_ command: String) async throws -> String? {
        guard state == .connected, let connection else { return nil }
        return try await connection.run(command)
    }

    /// Connects now because you clicked: turned a port on, Screen Sharing,
    /// Connect or Retry. Leaves a working connection alone.
    public func connect() async {
        guard !patterns.isEmpty else { return }
        clicked = true
        if running, state == .connected || state == .connecting || state == .retrying { return }
        log.write("connecting (clicked)", host: host)
        await halt()
        start()
    }

    /// Treats a live connection as clicked, so an edit that removes its only
    /// reason (unchecking or turning off the kept port) doesn't drop the
    /// other forwards mid-use. It still ends at the next drop.
    public func holdWhileConnected() {
        if state == .connected { clicked = true }
    }

    /// Starts or stops the connection to match the entries and the reasons
    /// to be connected.
    private func settle() async {
        if patterns.isEmpty {
            clicked = false
            if running || state != .idle {
                await halt()
                set(.idle)
            } else {
                changed()
            }
        } else if !wantsConnection {
            if running {
                log.write("nothing asks for a connection now; disconnecting", host: host)
                await halt()
            }
            if case .needsAttention = state { return changed() }
            set(.standby)
        } else if !running {
            if case .needsAttention = state {
                changed()
            } else if asleep {
                set(.paused("asleep"))
            } else {
                log.write("connecting (\(keeps ? "keep connected" : "your ssh session"))", host: host)
                start()
            }
        } else {
            changed()
            if state == .connected { await reconcile() }
        }
    }

    public func handle(_ event: PowerEvent) async {
        switch event {
        case .willSleep:
            asleep = true
            // A click connects once; sleeping ends it.
            clicked = false
            // Waiting for a person stays that way, or waking would retry.
            if case .needsAttention = state { return }
            guard !patterns.isEmpty, running || state != .standby else { return }
            log.write("sleeping; pausing", host: host)
            await halt()
            set(.paused("asleep"))
        case .networkDown:
            guard wantsConnection, !asleep else { return }
            if case .needsAttention = state { return }
            clicked = false
            log.write("network lost; pausing", host: host)
            await halt()
            set(.paused("no network"))
        case .didWake:
            asleep = false
            log.write("woke", host: host)
            await resume()
        case .networkUp:
            await resume()
        }
    }

    public func shutdown() async {
        await halt()
        set(.idle)
    }

    // MARK: Lifecycle

    private func resume() async {
        guard !patterns.isEmpty, !asleep, power.networkUp else { return }
        if case .needsAttention = state { return }
        guard reconnects else {
            // Paused by sleep or the network, and nothing asks to come back.
            if case .paused = state { set(.standby) }
            return
        }
        if state == .connected, let connection, await connection.isAlive() { return }
        log.write("resuming", host: host)
        await halt()
        start(after: timing.settle)
    }

    private func start(after delay: Double = 0) {
        generation += 1
        running = true
        // Right away, so nobody sees the old state while the task spins up.
        set(.connecting)
        let gen = generation
        Task { await self.loop(gen, initialDelay: delay) }
    }

    /// Stops everything and forgets the connection. Any loop still running
    /// notices the generation change and exits.
    private func halt() async {
        generation += 1
        running = false
        napTask?.cancel()
        let old = connection
        connection = nil
        linkAlive = false
        releaseAll()
        await old?.stop()
    }

    private func releaseAll() {
        for forward in active.values { allocator.release(forward.local) }
        active = [:]
        blocked = [:]
        listening = nil
        scanUnavailable = false
    }

    private func retryDelay(_ attempt: Int) -> Double {
        // With the lid shut nobody is waiting; go straight to the slow loop.
        if power.lidClosed { return timing.steadyRetry }
        return attempt < timing.retrySchedule.count ? timing.retrySchedule[attempt] : timing.steadyRetry
    }

    private func loop(_ gen: Int, initialDelay: Double) async {
        if initialDelay > 0 {
            set(.connecting)
            await nap(initialDelay)
        }
        var attempt = 0
        while gen == generation {
            guard power.networkUp else {
                running = false
                set(.paused("no network"))
                return
            }
            set(.connecting)
            let conn = makeConnection()
            conn.onExit = { [weak self] in
                Task { @MainActor in self?.linkDied(gen) }
            }
            connection = conn
            do {
                try await conn.start()
            } catch {
                guard gen == generation else {
                    await conn.stop()
                    return
                }
                connection = nil
                let failure = (error as? ConnectionError) ?? .unreachable("\(error)")
                lastError = failure.message
                if case .needsAttention(let message) = failure {
                    log.write("needs attention: \(message)", host: host)
                    running = false
                    set(.needsAttention(message))
                    return
                }
                if !reconnects, attempt >= timing.retrySchedule.count {
                    log.write("connect failed (\(failure.message)); giving up until you ssh in or click Connect", host: host)
                    stand()
                    return
                }
                let delay = retryDelay(attempt)
                log.write("connect failed (\(failure.message)); retrying in \(Int(delay))s", host: host)
                set(.retrying)
                await nap(delay)
                attempt += 1
                continue
            }
            guard gen == generation else {
                await conn.stop()
                return
            }
            attempt = 0
            lastError = nil
            linkAlive = true
            log.write("connected", host: host)
            set(.connected)

            while gen == generation, linkAlive {
                await scan(conn, gen)
                guard gen == generation, linkAlive else { break }
                await reconcile()
                guard gen == generation, linkAlive else { break }
                await nap(timing.scanInterval)
            }
            guard gen == generation else { return }

            // The link died by itself. Let any reconcile pass still in flight
            // finish first, so it can't record a forward after the cleanup.
            await reconcileTail?.value
            guard gen == generation else { return }
            releaseAll()
            connection = nil
            await conn.stop()
            guard gen == generation else { return }
            guard reconnects else {
                log.write("link down; not reconnecting (no ssh session of yours, nothing kept connected)", host: host)
                stand()
                return
            }
            let delay = retryDelay(0)
            log.write("link down; retrying in \(Int(delay))s", host: host)
            set(.retrying)
            await nap(delay)
            attempt = 1
        }
    }

    /// Stops the loop and waits for a reason to connect again.
    private func stand() {
        clicked = false
        running = false
        set(.standby)
    }

    private func linkDied(_ gen: Int) {
        guard gen == generation, linkAlive else { return }
        linkAlive = false
        napTask?.cancel()
    }

    private func nap(_ seconds: Double) async {
        let task = Task {
            _ = try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
        }
        napTask = task
        await task.value
    }

    // MARK: Scan and reconcile

    private func scan(_ conn: Connection, _ gen: Int) async {
        do {
            let result = try await RemoteScanner.scan(conn)
            guard gen == generation else { return }
            if result != listening {
                if let result {
                    // Only what changed: a busy remote has dozens of listeners.
                    let before = listening ?? []
                    let appeared = result.subtracting(before).sorted().map { "+\($0)" }
                    let gone = before.subtracting(result).sorted().map { "-\($0)" }
                    let summary = listening == nil
                        ? "\(result.count) ports listening on the remote"
                        : "remote listeners changed: " + (appeared + gone).joined(separator: " ")
                    log.write(summary, host: host)
                } else if !scanUnavailable {
                    log.write("can't scan this host (no ss, netstat or lsof)", host: host)
                }
            }
            listening = result
            scanUnavailable = (result == nil)
        } catch {
            guard gen == generation else { return }
            if !(await conn.isAlive()) {
                linkDied(gen)
            } else {
                log.write("scan failed: \((error as? ConnectionError)?.message ?? "\(error)")", host: host)
            }
        }
    }

    /// Runs one reconcile pass after any already queued, so passes never overlap.
    private func reconcile() async {
        let previous = reconcileTail
        let task = Task { @MainActor in
            await previous?.value
            await self.reconcilePass()
        }
        reconcileTail = task
        await task.value
    }

    private func reconcilePass() async {
        guard linkAlive, let conn = connection else { return }
        let gen = generation
        let desired = Reconciler.desired(patterns: patterns, listening: listening)
        let plan = Reconciler.plan(desired: desired, active: Array(active.values))
        var stillBlocked: [Int: String] = [:]

        for forward in plan.cancel {
            try? await conn.cancelForward(local: forward.local, remote: forward.remote)
            guard gen == generation, linkAlive else { return }
            allocator.release(forward.local)
            active[forward.remote] = nil
            log.write("cancelled \(forward.remote) (laptop \(forward.local))", host: host)
        }

        for want in plan.add {
            guard gen == generation, linkAlive else { return }
            let key = Self.stickyKey(host: host, entry: want.entry, remote: want.remote)
            guard let local = allocator.allocate(wanted: want.wantedLocal, key: key) else {
                stillBlocked[want.remote] = "No free laptop port near \(want.wantedLocal)"
                continue
            }
            do {
                try await conn.addForward(local: local, remote: want.remote)
                // The link may have died while that call was in flight.
                guard gen == generation, linkAlive else {
                    allocator.release(local)
                    return
                }
                active[want.remote] = Forward(remote: want.remote, local: local, entry: want.entry)
                let moved = local == want.wantedLocal ? "" : " (moved from \(want.wantedLocal))"
                log.write("forwarding \(want.remote) on laptop \(local)\(moved)", host: host)
            } catch {
                allocator.release(local)
                guard gen == generation else { return }
                stillBlocked[want.remote] = (error as? ConnectionError)?.message ?? "\(error)"
            }
        }

        for (remote, reason) in stillBlocked where blocked[remote] != reason {
            log.write("blocked \(remote): \(reason)", host: host)
        }
        blocked = stillBlocked
        changed()
    }

    // MARK: Output

    private func set(_ new: HostState) {
        // A click connects once. Once the host is waiting or paused, it has
        // been used up, and must not start a connection later on its own.
        switch new {
        case .standby, .paused: clicked = false
        default: break
        }
        state = new
        changed()
    }

    private func changed() {
        onChange?()
    }
}
