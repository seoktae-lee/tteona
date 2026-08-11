import Foundation
import Combine
import UserNotifications

struct SavedImpromptuSession: Codable {
    let date: Date
    let places: [Place]
    var roomIds: [String]
}

class ImpromptuSessionStore: ObservableObject {
    static let shared = ImpromptuSessionStore()
    private let key = "savedImpromptuSession"
    private let reminderID = "tteona.today.session.reminder"

    @Published var hasTodaySession: Bool = false

    private init() {
        hasTodaySession = loadTodaySession() != nil
    }

    func save(places: [Place], roomIds: [String] = []) {
        guard !places.isEmpty else { return }
        let existing = load()
        let ids = roomIds.isEmpty ? (existing?.roomIds ?? []) : roomIds
        let session = SavedImpromptuSession(date: Date(), places: places, roomIds: ids)
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: key)
        }
        hasTodaySession = true
        scheduleReminderIfNeeded(placesCount: places.count)
    }

    func load() -> SavedImpromptuSession? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let session = try? JSONDecoder().decode(SavedImpromptuSession.self, from: data)
        else { return nil }
        return session
    }

    func loadTodaySession() -> SavedImpromptuSession? {
        guard let session = load() else { return nil }
        // 자정을 넘겨도 밤샘 나들이를 잃지 않도록, 마지막 활동으로부터 18시간 이내면 이어한다.
        return Date().timeIntervalSince(session.date) < 18 * 3600 ? session : nil
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        hasTodaySession = false
        cancelReminder()
    }

    // MARK: - 리마인더 알림
    private func scheduleReminderIfNeeded(placesCount: Int) {
        let center = UNUserNotificationCenter.current()

        // 기존 예약된 리마인더 취소 후 재예약 (장소 수 업데이트 반영)
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])

        // 오늘 오후 8시 계산
        let calendar = Calendar.current
        let now = Date()
        guard var fireDate = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now) else { return }

        // 이미 오후 8시가 지났으면 알림 예약 안 함
        guard fireDate > now else { return }

        let content = UNMutableNotificationContent()
        content.title = L("impromptu.reminder.title")
        content.body = L("impromptu.reminder.body", placesCount)
        content.sound = .default
        content.userInfo = ["action": "openTodaySession"]

        let components = calendar.dateComponents([.hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: reminderID, content: content, trigger: trigger)

        center.add(request)
    }

    private func cancelReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [reminderID])
    }
}

/// 촬영 클립이 담긴 세션 폴더의 뒷정리.
///
/// 세션은 두 조각으로 나뉘어 산다 — **목록**은 UserDefaults에(신원과 무관하게 한 벌),
/// **영상 파일**은 `Sessions/free_{uid}/`에(신원별로). 이 비대칭이 새는 지점이다.
/// uid가 바뀌는 길 중 가입·승계는 `migrateGuestSession`이 파일을 옮겨 주지만,
/// **로그아웃과 회원 탈퇴**는 새 익명 신원을 발급받으면서 옛 폴더를 그대로 두고 간다.
/// 목록은 지워지니 데이터가 깨지진 않지만, 아무도 다시 열지 않을 영상이 계속 쌓인다
/// (한 번에 무료 30초분, PRO는 5분분).
enum SessionFileHousekeeping {
    private static var sessionsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tteona/Sessions")
    }

    /// 지금 신원의 것이 아닌 게스트 세션 폴더를 지운다.
    ///
    /// **신원이 확정된 뒤에만** 부를 것 — uid가 비어 있을 때 돌리면 살아 있는 오늘치까지
    /// 남의 것으로 판정해 지운다. 그래서 빈 uid는 스스로 거른다.
    ///
    /// 코스 따라가기 세션 폴더는 이름이 `courseId`(UUID)라 여기서 건드리지 않는다 —
    /// 진행 중인 코스의 클립이 거기 있고, 그 정리는 코스 흐름이 따로 책임진다.
    static func purgeOrphanedGuestSessions(currentUid: String) {
        guard !currentUid.isEmpty else { return }
        let fm = FileManager.default
        let root = sessionsRoot
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return }

        let keep = "free_\(currentUid)"
        // 지금 목록이 가리키고 있는 클립은 어느 폴더에 있든 남긴다.
        // 목록만 살아남고 파일이 다른 폴더에 있는 어긋난 상태에서, 지워버리면
        // 복구할 길까지 끊는다 — 새는 것보다 나쁜 결과다.
        let referenced = Set((ImpromptuSessionStore.shared.load()?.places ?? [])
            .compactMap(\.clipFileName))

        for name in entries where name.hasPrefix("free_") && name != keep {
            let dir = root.appendingPathComponent(name)
            if !referenced.isEmpty,
               let files = try? fm.contentsOfDirectory(atPath: dir.path),
               files.contains(where: { referenced.contains($0) }) {
                dlog("[SessionFiles] \(name) 는 현재 목록이 참조 중 — 보존")
                continue
            }
            try? fm.removeItem(at: dir)
            dlog("[SessionFiles] 고아 세션 폴더 정리: \(name)")
        }
    }
}
