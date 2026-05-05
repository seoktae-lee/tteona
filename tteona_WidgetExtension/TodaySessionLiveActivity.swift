import ActivityKit
import WidgetKit
import SwiftUI

// TodaySessionAttributes는 앱 타겟과 공유되는 파일이므로 여기서도 같은 정의 필요
// Xcode에서 해당 파일의 Target Membership에 Widget Extension을 추가하면 됩니다.

struct TodaySessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TodaySessionAttributes.self) { context in
            // 잠금화면 / 알림 센터 배너
            LockScreenLiveActivityView(context: context)
                .activityBackgroundTint(Color(red: 1, green: 0.42, blue: 0.21))
                .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                // 확장 영역
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("나의 오늘", systemImage: "figure.walk")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text("\(context.state.placesCount)곳 기록됨")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Link(destination: URL(string: "tteona://capture")!) {
                        VStack(spacing: 3) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 18, weight: .semibold))
                            Text("촬영")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.white.opacity(0.25)))
                    }
                    .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundColor(.white.opacity(0.7))
                            .font(.system(size: 12))
                        Text(context.state.lastPlaceName)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(1)
                        Spacer()
                        Text(context.state.startedAt, style: .timer)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }

            } compactLeading: {
                Image(systemName: "figure.walk")
                    .foregroundColor(.orange)
                    .font(.system(size: 14, weight: .semibold))

            } compactTrailing: {
                Text("\(context.state.placesCount)곳")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.orange)

            } minimal: {
                Image(systemName: "figure.walk")
                    .foregroundColor(.orange)
                    .font(.system(size: 13))
            }
            .keylineTint(.orange)
        }
    }
}

// MARK: - 잠금화면 뷰
private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<TodaySessionAttributes>

    var body: some View {
        HStack(spacing: 14) {
            // 왼쪽: 상태 정보
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 7, height: 7)
                    Text("나의 오늘 기록 중")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }

                Text("\(context.state.placesCount)곳 방문")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.75))
                    Text(context.state.lastPlaceName)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }

            Spacer()

            // 오른쪽: 촬영 버튼
            Link(destination: URL(string: "tteona://capture")!) {
                VStack(spacing: 5) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(Color(red: 1, green: 0.42, blue: 0.21))
                    Text("여기서 촬영")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(red: 1, green: 0.42, blue: 0.21))
                }
                .frame(width: 76, height: 76)
                .background(Circle().fill(Color.white))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
