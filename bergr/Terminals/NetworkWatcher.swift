import Foundation
import Network

/// Tells the sessions when the network path changes (Wi-Fi ↔ cellular, a VPN coming up, Wi-Fi
/// back): their SSH lines may be dead without knowing it, and the 40 s silence limit is far too
/// slow to notice. Each session checks its line at once instead (`HostSession.probe`).
@MainActor
final class NetworkWatcher {
    static let shared = NetworkWatcher()

    private let monitor = NWPathMonitor()
    private var last: String?
    private var onChange: (() -> Void)?

    /// What identifies a path for our purpose: usable or not, over which interfaces.
    nonisolated static func signature(satisfied: Bool, interfaces: [String]) -> String {
        "\(satisfied)|" + interfaces.sorted().joined(separator: ",")
    }

    func start(onChange: @escaping () -> Void) {
        guard self.onChange == nil else { self.onChange = onChange; return }
        self.onChange = onChange
        monitor.pathUpdateHandler = { path in
            let signature = Self.signature(
                satisfied: path.status == .satisfied,
                interfaces: path.availableInterfaces.map { "\($0.type)-\($0.name)" })
            let usable = path.status == .satisfied
            Task { @MainActor in NetworkWatcher.shared.pathChanged(signature, usable: usable) }
        }
        monitor.start(queue: DispatchQueue(label: "bergr.network"))
    }

    private func pathChanged(_ signature: String, usable: Bool) {
        defer { last = signature }
        // The first report is the current path, not a change; an unusable path has nothing to check.
        guard let last, last != signature, usable else { return }
        onChange?()
    }
}
