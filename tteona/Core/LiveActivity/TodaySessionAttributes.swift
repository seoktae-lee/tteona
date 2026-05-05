import ActivityKit
import Foundation

struct TodaySessionAttributes: ActivityAttributes {
    public typealias TodaySessionStatus = ContentState

    public struct ContentState: Codable, Hashable {
        var placesCount: Int
        var lastPlaceName: String
        var startedAt: Date
    }
}
