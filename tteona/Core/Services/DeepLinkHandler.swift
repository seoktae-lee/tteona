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
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        if host == "course" {
            if let courseId = components?.queryItems?.first(where: { $0.name == "id" })?.value {
                pendingCourseId = courseId
            } else if let courseId = url.pathComponents.filter({ $0 != "/" }).first {
                pendingCourseId = courseId
            }
        } else if host == "room" {
            if let code = components?.queryItems?.first(where: { $0.name == "code" })?.value {
                pendingRoomCode = code
            }
        } else if host == "capture" {
            // 잠금화면 Live Activity·다이나믹 아일랜드의 "촬영" 버튼 →
            // 기존 알림 경로(shouldOpenTodaySession)를 재사용해 '나의 오늘' 세션을 연다
            Task { @MainActor in
                AppNotificationManager.shared.shouldOpenTodaySession = true
            }
        }
    }

    private func handleUniversalLink(url: URL) {
        let path = url.path
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        if path == "/course" || path.hasPrefix("/course/") {
            if let courseId = components.queryItems?.first(where: { $0.name == "id" })?.value {
                pendingCourseId = courseId
            } else if path.hasPrefix("/course/") {
                // 경로형 /course/{UUID} (서버 OG canonical) — 쿼리 id가 없으므로 경로에서 추출
                let id = String(path.dropFirst("/course/".count))
                if !id.isEmpty { pendingCourseId = id }
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
