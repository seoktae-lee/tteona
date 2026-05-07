import SwiftUI
import Combine

class DeepLinkHandler: ObservableObject {
    @Published var pendingCourseId: String? = nil
    @Published var pendingRoomCode: String? = nil

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
        } else if host == "room" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
                pendingRoomCode = code
            }
        }
        // capture는 ImpromptuSessionView에서 처리
    }

    private func handleUniversalLink(url: URL) {
        let path = url.path
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        if path == "/course" || path.hasPrefix("/course/") {
            if let courseId = components.queryItems?.first(where: { $0.name == "id" })?.value {
                pendingCourseId = courseId
            }
        } else if path == "/room" {
            if let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
                pendingRoomCode = code
            }
        }
    }

    func clearPendingCourse() {
        pendingCourseId = nil
    }

    func clearPendingRoom() {
        pendingRoomCode = nil
    }
}
