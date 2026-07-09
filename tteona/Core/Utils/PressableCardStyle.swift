import SwiftUI

/// 코스 카드처럼 스크롤 안에 놓인 탭 가능한 카드의 눌림 피드백.
///
/// DragGesture(minimumDistance: 0)로 눌림을 추적하면 ScrollView의 팬 제스처와 경쟁해
/// 카드 위에서 스크롤이 먹지 않는다. ButtonStyle의 isPressed는 스크롤이 시작되면
/// 자동으로 풀리므로 충돌이 없다.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
