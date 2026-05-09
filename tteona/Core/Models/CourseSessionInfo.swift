import Foundation

struct CourseSessionInfo: Identifiable {
    let id = UUID()
    let course: Course
    let roomIds: Set<String>
}
