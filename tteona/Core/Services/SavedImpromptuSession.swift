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
        return Calendar.current.isDateInToday(session.date) ? session : nil
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
        content.title = "오늘 기록, Vlog로 남겨볼까요? 🎬"
        content.body = "오늘 방문한 \(placesCount)곳으로 추억 영상을 만들어보세요"
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
