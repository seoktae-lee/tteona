import SwiftUI

class DeepLinkHandler: ObservableObject {
    @Published var pendingCourseId: String? = nil

    func handle(url: URL) {
        if url.scheme == "tteona" {
            handleCustomScheme(url: url)
        } else if url.host == "tteona.kr" {
            handleUniversalLink(url: url)
        }
    }

    private func handleCustomScheme(url: URL) {
        let host = url.host
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        if host == "course", let courseId = pathComponents.first {
            pendingCourseId = courseId
        }
        // capture는 ImpromptuSessionView에서 처리
    }

    private func handleUniversalLink(url: URL) {
        let path = url.path
        guard path == "/course" || path.hasPrefix("/course/") else { return }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let courseId = components.queryItems?.first(where: { $0.name == "id" })?.value {
            pendingCourseId = courseId
        }
    }

    func clearPendingCourse() {
        pendingCourseId = nil
    }
}
