#if canImport(Network)
import Foundation
import Network

/// Watches the network path of this Client device and reports each meaningful change once.
/// It never decides whether a Host is reachable — only that the route this device would use has
/// appeared, disappeared or been replaced, which is when a waiting retry is worth anticipating.
public final class NetworkPathObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "it.ambiens.northpane.network-path")
    private let lock = NSLock()
    private var latest: NetworkPath?
    private var isRunning = false

    public init() {}

    /// Starts watching. The handler runs off the main thread for every path update, with the
    /// observation and what it means for a retry that is currently waiting.
    public func start(_ handler: @escaping @Sendable (NetworkPath, NetworkPathReaction) -> Void) {
        let shouldStart = lock.withLock {
            guard !isRunning else { return false }
            isRunning = true
            return true
        }
        guard shouldStart else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let observed = NetworkPath(path)
            let reaction: NetworkPathReaction? = self.lock.withLock {
                guard observed != self.latest else { return nil }
                let reaction = observed.reaction(after: self.latest)
                self.latest = observed
                return reaction
            }
            guard let reaction else { return }
            handler(observed, reaction)
        }
        monitor.start(queue: queue)
    }

    public func cancel() {
        let shouldCancel = lock.withLock {
            guard isRunning else { return false }
            isRunning = false
            return true
        }
        guard shouldCancel else { return }
        monitor.cancel()
    }

    deinit { if lock.withLock({ isRunning }) { monitor.cancel() } }
}

extension NetworkPath {
    init(_ path: NWPath) {
        // Interfaces alone do not change when a Mac joins a different Wi-Fi network, so the
        // gateways are part of the signature: together they identify the network, not just the
        // hardware carrying it.
        let interfaces = path.availableInterfaces.map(\.name)
        let gateways = path.gateways.map { String(describing: $0) }
        self.init(isSatisfied: path.status == .satisfied, routeSignature: (interfaces + gateways).sorted())
    }
}
#endif
