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

    // 아래 둘은 글자 입력처럼 연달아 울리는 자리용이다.
    // 매번 생성기를 새로 만들면 첫 반응이 늦고 비용도 들어 생성기를 재사용한다.
    private static let typingGenerator = UISelectionFeedbackGenerator()
    private static let limitGenerator = UIImpactFeedbackGenerator(style: .rigid)

    /// 타이핑 틱 — 글자가 하나 늘고 줄 때의 아주 작은 반응.
    /// 임팩트가 아니라 셀렉션인 이유: 연타 상황에서 가장 가볍게 느껴진다.
    static func typing() {
        typingGenerator.selectionChanged()
        typingGenerator.prepare()   // 다음 글자를 위해 미리 준비해 둔다
    }

    /// 한도에 닿아 더 들어가지 않을 때 — 벽에 닿는 단단한 감촉.
    /// 입력이 막혔는데 아무 반응이 없으면 고장으로 읽힌다.
    static func limitReached() {
        limitGenerator.impactOccurred()
        limitGenerator.prepare()
    }
}
