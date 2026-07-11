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
        // 달력상 '오늘'로 판정하면 밤 11시에 하던 여행이 자정을 넘기는 순간 사라진다.
        // session.date는 저장할 때마다 갱신되는 '마지막 활동 시각'이므로, 그로부터 18시간
        // 이내면 같은 나들이로 보고 이어할 수 있게 한다(자정 교차 커버, 며칠 전 세션은 제외).
        return Date().timeIntervalSince(session.date) < 18 * 3600 ? session : nil
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        hasTodaySession = false
    }
}
