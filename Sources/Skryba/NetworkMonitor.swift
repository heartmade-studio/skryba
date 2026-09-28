import Network
import Observation

/// Knows whether the Mac has a network path at all, so Skryba can say "offline" the moment you
/// start dictating instead of after a failed upload.
///
/// It only catches hard offline (Wi-Fi off, no cable). A weak or captive network still looks
/// "online" here; `Retry` and the cancellable HUD handle that case.
@MainActor @Observable
final class NetworkMonitor {
    private(set) var isOnline = true

    /// Called when the path comes back after being down.
    @ObservationIgnored var onReconnect: (() -> Void)?

    @ObservationIgnored private let monitor = NWPathMonitor()

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "pl.heartmade.skryba.network"))
    }

    private func update(online: Bool) {
        let reconnected = online && !isOnline
        isOnline = online
        if reconnected { onReconnect?() }
    }
}
