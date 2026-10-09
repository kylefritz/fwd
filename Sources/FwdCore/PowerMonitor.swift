import AppKit
import Foundation
import IOKit
import Network

public enum PowerEvent: Equatable, Sendable {
    case willSleep
    case didWake
    case networkUp
    case networkDown
}

/// Where sleep, wake, network and lid information comes from. Tests supply
/// their own; the app uses `SystemPowerMonitor`.
public protocol PowerEvents: AnyObject {
    var onEvent: ((PowerEvent) -> Void)? { get set }
    var lidClosed: Bool { get }
    var networkUp: Bool { get }
}

public final class SystemPowerMonitor: PowerEvents, @unchecked Sendable {
    public var onEvent: ((PowerEvent) -> Void)?
    public private(set) var networkUp = true
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private var sawFirstPath = false

    public init() {}

    public func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onEvent?(.willSleep)
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onEvent?(.didWake)
        })
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let up = path.status == .satisfied
                let changed = up != self.networkUp
                self.networkUp = up
                // The first report only establishes the baseline. After that,
                // any update while up may mean a new network, so pass it on.
                if !self.sawFirstPath {
                    self.sawFirstPath = true
                    if !up { self.onEvent?(.networkDown) }
                } else if changed || up {
                    self.onEvent?(up ? .networkUp : .networkDown)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "fwd.network"))
    }

    /// True when a laptop's lid is shut. Always false on a desktop Mac.
    public var lidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }
}
