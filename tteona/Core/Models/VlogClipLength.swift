import Foundation

/// 한 장소당 촬영 길이 선택지.
///
/// 총 예산(무료 30초 / PRO 5분)이 실제 문지기이고, 길이는 그 예산을 어떻게 쪼갤지의 문제다.
/// 그래서 짧은 길이는 무료로 열어 둔다 — 2초를 고르면 15곳까지 찍을 수 있어 오히려
/// 앱을 더 오래 쓰게 되고, 10초를 고르면 3곳에서 예산이 끝나 PRO 필요를 빨리 체감한다.
enum VlogClipLength: String, CaseIterable, Identifiable {
    case s2, s3, s5, s10, s15, s20

    var id: String { rawValue }

    /// 자동 종료 시각(초).
    /// 모든 길이가 자동 종료다 — 수동 종료를 두면 한 장소에서 예산을 다 태우는 사고가 나고,
    /// "짧게 툭 찍으면 알아서 브이로그가 된다"는 컨셉과도 어긋난다.
    var seconds: Double? {
        switch self {
        case .s2:  return 2
        case .s3:  return 3
        case .s5:  return 5
        case .s10: return 10
        case .s15: return 15
        case .s20: return 20
        }
    }

    /// PRO 전용인가 — 10초 이상은 유료
    var requiresPro: Bool {
        switch self {
        case .s2, .s3, .s5:   return false
        case .s10, .s15, .s20: return true
        }
    }

    /// 칩에 표시할 짧은 라벨
    var shortLabel: String { L("camera.clipLength.seconds", Int(seconds ?? 0)) }

    /// 무료 기본값 — 5초(6곳)보다 3초(10곳)가 장소를 더 쌓게 해 브이로그가 좋아진다
    static let freeDefault: VlogClipLength = .s3
}
