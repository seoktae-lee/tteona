import Foundation
import Combine
import CoreLocation

struct WSMemberLocation: Identifiable {
    let userId: String
    let nickname: String
    let latitude: Double
    let longitude: Double
    let updatedAt: Date
    var id: String { userId }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@MainActor
class LocationSocketService: ObservableObject {
    static let shared = LocationSocketService()

    @Published var memberLocations: [WSMemberLocation] = []

    private var wsTask: URLSessionWebSocketTask?
    private var currentRoomId: String?
    private var currentUserId: String?
    private var currentNickname: String = ""
    private var pingTimer: Timer?
    private var reconnectTask: Task<Void, Never>?

    private let wsURL = URL(string: "wss://tteona.kr/ws/location")!

    // MARK: - 연결

    func connect(roomId: String, userId: String, nickname: String) {
        guard wsTask == nil || wsTask?.state != .running else { return }
        currentRoomId  = roomId
        currentUserId  = userId
        currentNickname = nickname
        openSocket()
    }

    private func openSocket() {
        let session = URLSession(configuration: .default)
        wsTask = session.webSocketTask(with: wsURL)
        wsTask?.resume()

        send(["type": "join",
              "roomId":   currentRoomId ?? "",
              "userId":   currentUserId ?? "",
              "nickname": currentNickname])
        listen()
        startPing()
    }

    // MARK: - 위치 전송

    func sendLocation(latitude: Double, longitude: Double) {
        send(["type":      "location",
              "latitude":  latitude,
              "longitude": longitude])
    }

    // MARK: - 연결 해제

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        if let roomId = currentRoomId, let userId = currentUserId {
            send(["type": "leave", "roomId": roomId, "userId": userId])
        }
        cleanup()
    }

    private func cleanup() {
        pingTimer?.invalidate()
        pingTimer = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        memberLocations = []
    }

    // MARK: - 수신 루프

    private func listen() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                if case .string(let text) = msg,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    Task { @MainActor in self.handle(json) }
                }
                self.listen()
            case .failure:
                Task { @MainActor in self.scheduleReconnect() }
            }
        }
    }

    private func handle(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }

        switch type {
        case "location":
            guard let userId   = json["userId"]    as? String,
                  let nickname = json["nickname"]  as? String,
                  let lat      = json["latitude"]  as? Double,
                  let lng      = json["longitude"] as? Double else { return }

            let loc = WSMemberLocation(userId: userId, nickname: nickname,
                                       latitude: lat, longitude: lng, updatedAt: Date())
            if let idx = memberLocations.firstIndex(where: { $0.userId == userId }) {
                memberLocations[idx] = loc
            } else {
                memberLocations.append(loc)
            }

        case "left":
            if let userId = json["userId"] as? String {
                memberLocations.removeAll { $0.userId == userId }
            }

        default: break
        }
    }

    // MARK: - 자동 재연결 (3초 후)

    private func scheduleReconnect() {
        guard currentRoomId != nil else { return }
        cleanup()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run { self.openSocket() }
        }
    }

    // MARK: - Ping (25초)

    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            self?.wsTask?.sendPing { _ in }
        }
    }

    // MARK: - 전송 헬퍼

    private func send(_ dict: [String: Any]) {
        guard let wsTask,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let str  = String(data: data, encoding: .utf8) else { return }
        wsTask.send(.string(str)) { _ in }
    }
}
