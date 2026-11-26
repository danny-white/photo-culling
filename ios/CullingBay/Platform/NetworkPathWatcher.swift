import Foundation
import Network

/// Tells the app's `ServerLink` when the phone's network changes (`NWPathMonitor`): no network at
/// all makes the PC out of reach at once, and a new one is probed. The first report, which comes as
/// the watcher starts, only says something if there is no network, since the launch probes anyway.
@MainActor
final class NetworkPathWatcher {
    /// Whether the phone has a network now.
    private(set) var hasPath = true
    private let monitor = NWPathMonitor()
    private var lastPath: String?
    private var onChange: ((Bool) -> Void)?

    /// Starts watching. `onChange` gets whether there is a network, each time it changes.
    func start(_ onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        // Sendable, so the handler is not tied to the main actor: the monitor calls it on its queue.
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let satisfied = path.status == .satisfied
            // The interfaces and gateways tell one Wi-Fi network from the next.
            let signature = "\(path.status) \(path.availableInterfaces.map(\.name)) \(path.gateways.map { "\($0)" })"
            Task { @MainActor in self?.update(satisfied: satisfied, signature: signature) }
        }
        monitor.start(queue: DispatchQueue(label: "co.dannywhite.cullingbay.path"))
    }

    private func update(satisfied: Bool, signature: String) {
        let first = lastPath == nil
        guard signature != lastPath else { return }
        lastPath = signature
        hasPath = satisfied
        if first && satisfied { return }
        onChange?(satisfied)
    }
}
