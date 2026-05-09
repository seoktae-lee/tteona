import Foundation
import Combine

struct SavedActiveSession: Codable {
    let date: Date
    let course: Course
    var orderedPlaces: [Place]
    var visitedPlaceOrders: [Int]
    var skippedPlaceOrders: [Int]
    var currentPlaceIndex: Int
    var roomIds: [String]
}

class ActiveSessionStore: ObservableObject {
    static let shared = ActiveSessionStore()
    private let key = "savedActiveSession"

    @Published var hasTodaySession: Bool = false

    private init() {
        hasTodaySession = loadTodaySession() != nil
    }

    func save(_ session: SavedActiveSession) {
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: key)
        }
        hasTodaySession = true
    }

    func load() -> SavedActiveSession? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let session = try? JSONDecoder().decode(SavedActiveSession.self, from: data)
        else { return nil }
        return session
    }

    func loadTodaySession() -> SavedActiveSession? {
        guard let session = load() else { return nil }
        return Calendar.current.isDateInToday(session.date) ? session : nil
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        hasTodaySession = false
    }
}
