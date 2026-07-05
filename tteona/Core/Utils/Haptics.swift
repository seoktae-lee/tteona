import UIKit

/// 앱 공통 햅틱 — 보상·확정 순간에만 절제해서 사용한다.
/// (버튼 탭마다 울리면 피로하므로 목록: 도착, 촬영 완료, 좋아요, 코스 시작, Vlog 완성, 결제 성공)
enum Haptics {
    /// 가벼운 톡 — 좋아요, 선택 확정 같은 작은 상호작용
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 중간 임팩트 — 코스 시작 등 화면이 크게 전환되는 확정 액션
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 성공 노티 — 도착, 촬영 완료, Vlog 완성, 결제 성공
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// 경고 노티 — 되돌릴 수 없는 삭제/차단 직전
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
