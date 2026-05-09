//
//  SavedActiveSession.swift
//  tteona
//
//  Created by 이석태 on 5/9/26.
//


import Foundation
import Combine

struct SavedCourse: Codable {
    var courseId: String
    var authorId: String
    var courseName: String
    var tag: CourseTag
    var region: String
    var likeCount: Int
    var createdAt: Date
    var places: [Place]

    init(from course: Course) {
        self.courseId = course.courseId
        self.authorId = course.authorId
        self.courseName = course.courseName
        self.tag = course.tag
        self.region = course.region
        self.likeCount = course.likeCount
        self.createdAt = course.createdAt
        self.places = course.places
    }

    func toCourse() -> Course {
        Course(
            id: nil,
            courseId: courseId,
            authorId: authorId,
            courseName: courseName,
            tag: tag,
            region: region,
            likeCount: likeCount,
            createdAt: createdAt,
            places: places
        )
    }
}

struct SavedActiveSession: Codable {
    let date: Date
    let course: SavedCourse
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
        do {
            let data = try JSONEncoder().encode(session)
            UserDefaults.standard.set(data, forKey: key)
            hasTodaySession = true
        } catch {
            UserDefaults.standard.removeObject(forKey: key)
            hasTodaySession = false
        }
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
