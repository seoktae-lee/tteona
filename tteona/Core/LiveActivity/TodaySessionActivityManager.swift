import ActivityKit
import Foundation

final class TodaySessionActivityManager: @unchecked Sendable {
    static let shared = TodaySessionActivityManager()

    private var activity: Activity<TodaySessionAttributes>?

    func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activity == nil else { return }

        let initialState = TodaySessionAttributes.ContentState(
            placesCount: 0,
            lastPlaceName: "기록 시작",
            startedAt: Date()
        )
        let content = ActivityContent(state: initialState, staleDate: nil)

        do {
            activity = try Activity.request(
                attributes: TodaySessionAttributes(),
                content: content,
                pushType: nil
            )
        } catch {
            print("[LiveActivity] start failed: \(error)")
        }
    }

    func update(placesCount: Int, lastPlaceName: String) {
        guard let activity else { return }
        let newState = TodaySessionAttributes.ContentState(
            placesCount: placesCount,
            lastPlaceName: lastPlaceName,
            startedAt: activity.content.state.startedAt
        )
        Task {
            await activity.update(ActivityContent(state: newState, staleDate: nil))
        }
    }

    func end() {
        guard let activity else { return }
        let current = activity
        self.activity = nil
        Task {
            await current.end(nil, dismissalPolicy: .immediate)
        }
    }
}
