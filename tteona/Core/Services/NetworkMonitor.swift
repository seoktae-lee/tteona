import Foundation
import Network
import Combine

/// 앱 전역 네트워크 연결 상태 모니터. 오프라인이면 상단 배너를 띄워
/// "왜 아무것도 안 되는지"를 사용자가 알 수 있게 한다(그동안은 조용히 실패했음).
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "tteona.network.monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }
}
