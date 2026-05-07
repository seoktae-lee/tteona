import UIKit

enum CourseShareHelper {
    static func share(course: Course) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "tteona.kr"
        components.path = "/course"
        components.queryItems = [
            URLQueryItem(name: "id", value: course.courseId),
            URLQueryItem(name: "name", value: course.courseName),
            URLQueryItem(name: "places", value: "\(course.places.count)")
        ]
        guard let url = components.url else { return }

        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }
        var topVC = rootVC
        while let presented = topVC.presentedViewController { topVC = presented }
        topVC.present(activityVC, animated: true)
    }
}
