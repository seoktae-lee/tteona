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

/// 동행 세션 실시간 위치 공유.
/// 한 번의 나들이를 여러 그룹 방에 동시에 공유할 수 있도록, 방마다 독립 WebSocket 연결을
/// 열고(RoomConnection) 위치를 모두에게 브로드캐스트한다. 여러 방의 멤버 위치는 userId
/// 기준으로 합쳐(최신 우선) 지도에 한 번만 찍는다. (서버 프로토콜은 그대로 — 방당 join.)
@MainActor
class LocationSocketService: ObservableObject {
    static let shared = LocationSocketService()

    @Published var memberLocations: [WSMemberLocation] = []

    private var connections: [String: RoomConnection] = [:]   // roomId → 연결
    private var userId: String = ""
    private var nickname: String = ""

    private let wsURL = URL(string: "wss://tteona.kr/ws/location")!

    // MARK: - 연결

    /// 여러 방에 동시에 실시간 위치를 공유한다. 이미 연결된 방은 유지, 빠진 방은 정리한다.
    func connect(roomIds: Set<String>, userId: String, nickname: String) {
        self.userId = userId
        self.nickname = nickname

        // 더 이상 공유하지 않는 방 연결 정리
        for (rid, conn) in connections where !roomIds.contains(rid) {
            conn.close()
            connections[rid] = nil
        }
        // 새로 공유할 방 연결
        for rid in roomIds where connections[rid] == nil {
            let conn = RoomConnection(roomId: rid, userId: userId, nickname: nickname, wsURL: wsURL) { [weak self] in
                self?.rebuildMemberLocations()
            }
            connections[rid] = conn
            conn.open()
        }
        rebuildMemberLocations()
    }

    /// 하위호환 단일 방 연결
    func connect(roomId: String, userId: String, nickname: String) {
        connect(roomIds: [roomId], userId: userId, nickname: nickname)
    }

    // MARK: - 위치 전송 (모든 공유 방에)

    func sendLocation(latitude: Double, longitude: Double) {
        for conn in connections.values {
            conn.sendLocation(latitude: latitude, longitude: longitude)
        }
    }

    // MARK: - 연결 해제

    func disconnect() {
        for conn in connections.values { conn.close() }
        connections.removeAll()
        memberLocations = []
    }

    /// 여러 방의 멤버 위치를 합친다 — 같은 유저가 여러 방에 있으면 최신 위치 하나만 남긴다.
    private func rebuildMemberLocations() {
        var merged: [String: WSMemberLocation] = [:]
        for conn in connections.values {
            for m in conn.members {
                if let existing = merged[m.userId], existing.updatedAt >= m.updatedAt { continue }
                merged[m.userId] = m
            }
        }
        memberLocations = Array(merged.values)
    }
}

// MARK: - 방 단위 WebSocket 연결

@MainActor
final class RoomConnection {
    let roomId: String
    private let userId: String
    private let nickname: String
    private let wsURL: URL
    private let onUpdate: () -> Void

    private(set) var members: [WSMemberLocation] = []

    private var wsTask: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var isClosed = false

    init(roomId: String, userId: String, nickname: String, wsURL: URL,
         onUpdate: @escaping () -> Void) {
        self.roomId = roomId
        self.userId = userId
        self.nickname = nickname
        self.wsURL = wsURL
        self.onUpdate = onUpdate
    }

    func open() {
        guard !isClosed else { return }
        let session = URLSession(configuration: .default)
        wsTask = session.webSocketTask(with: wsURL)
        wsTask?.resume()
        listen()
        startPing()
        // 서버가 join 시 Firebase ID 토큰으로 본인·방 멤버십을 검증한다
        Task { [weak self] in
            guard let self else { return }
            let token = await APIAuth.bearerToken()
            self.send(["type": "join",
                       "roomId": self.roomId,
                       "userId": self.userId,
                       "nickname": self.nickname,
                       "idToken": token ?? ""])
        }
    }

    func sendLocation(latitude: Double, longitude: Double) {
        send(["type": "location", "latitude": latitude, "longitude": longitude])
    }

    func close() {
        isClosed = true
        reconnectTask?.cancel(); reconnectTask = nil
        send(["type": "leave", "roomId": roomId, "userId": userId])
        cleanup()
        members = []
        onUpdate()
    }

    private func cleanup() {
        pingTimer?.invalidate(); pingTimer = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

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
            guard let uid = json["userId"] as? String,
                  let nick = json["nickname"] as? String,
                  let lat = json["latitude"] as? Double,
                  let lng = json["longitude"] as? Double else { return }
            let loc = WSMemberLocation(userId: uid, nickname: nick,
                                       latitude: lat, longitude: lng, updatedAt: Date())
            if let idx = members.firstIndex(where: { $0.userId == uid }) {
                members[idx] = loc
            } else {
                members.append(loc)
            }
            onUpdate()
        case "left":
            if let uid = json["userId"] as? String {
                members.removeAll { $0.userId == uid }
                onUpdate()
            }
        default:
            break
        }
    }

    private func scheduleReconnect() {
        guard !isClosed else { return }
        cleanup()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !self.isClosed, !Task.isCancelled else { return }
            await MainActor.run { self.open() }
        }
    }

    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            self?.wsTask?.sendPing { _ in }
        }
    }

    private func send(_ dict: [String: Any]) {
        guard let wsTask,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        wsTask.send(.string(str)) { _ in }
    }
}
