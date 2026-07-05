import SwiftUI

extension Font {
    /// 떠나 기본 서체 — Pretendard + Dynamic Type.
    /// 디자인 기준 크기를 그대로 넘기면 시스템 글자 크기 설정에 비례해 스케일된다.
    /// 폰트 로드 실패 시 시스템 폰트로 자동 폴백된다(custom은 설치 안 된 이름이면 시스템 폰트 사용).
    static func tte(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(pretendardName(for: weight), size: size, relativeTo: textStyle(for: size))
    }

    private static func pretendardName(for weight: Font.Weight) -> String {
        switch weight {
        case .heavy, .black:    return "Pretendard-ExtraBold"
        case .bold:             return "Pretendard-Bold"
        case .semibold:         return "Pretendard-SemiBold"
        case .medium:           return "Pretendard-Medium"
        default:                return "Pretendard-Regular"
        }
    }

    // Dynamic Type 스케일 기준 — 크기대별로 가장 가까운 시스템 텍스트 스타일에 연동
    private static func textStyle(for size: CGFloat) -> TextStyle {
        switch size {
        case 28...:     return .largeTitle
        case 22..<28:   return .title2
        case 19..<22:   return .title3
        case 16..<19:   return .body
        case 14..<16:   return .subheadline
        case 12..<14:   return .footnote
        case 11..<12:   return .caption
        default:        return .caption2
        }
    }
}
