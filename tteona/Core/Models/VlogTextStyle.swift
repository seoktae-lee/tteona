import SwiftUI

/// 브이로그 장소 자막의 서체·크기 선택 모델.
/// 키(`key`)는 서버(server.js `VLOG_FONT_FILES`)·안드로이드와 공유한다 — 값을 바꾸면 세 곳을 함께 맞춰야 한다.
/// 실제 합성은 대부분 서버가 하고, 이 PostScript 이름은 서버 실패 시 로컬 폴백(VlogService) 렌더에 쓰인다.
enum VlogFont: String, CaseIterable, Identifiable {
    // 선택 화면 노출 순서 (rawValue는 그대로 — 저장값·기본값 호환 유지)
    case kkubulim      // 꾸불림 (배민, 구불구불 손맛)
    case gooltokki     // 굴토끼 (HS, 동글 손글씨)
    case blackhansans  // 검은고딕 (굵은 임팩트)
    case jua           // 주아 (동글 귀여움)
    case gowun         // 고운바탕 (기본·감성 명조)
    case pretendard    // 프리텐다드 (모던 산세)
    case nanumpen      // 나눔손글씨 펜 (손글씨)

    var id: String { rawValue }

    /// 선택 화면에 보일 이름 (로컬라이즈)
    var displayName: String { L("vlog.font.\(rawValue)") }

    /// 로컬 폴백 렌더용 iOS PostScript 이름 (Fonts/에 번들된 파일)
    var postScriptName: String {
        switch self {
        case .gowun:        return "GowunBatang-Regular"
        case .pretendard:   return "Pretendard-Bold"
        case .nanumpen:     return "NanumPen-Regular"
        case .jua:          return "Jua-Regular"
        case .blackhansans: return "BlackHanSans-Regular"
        case .kkubulim:     return "BMkkubulimTTF-Regular"
        case .gooltokki:    return "HSGooltokki"
        }
    }

    /// 미리보기 샘플 글자
    var sample: String { "가나 Ag" }
}

/// 자막 크기 3단 — 서버 `VLOG_FONT_SCALE`와 배율을 맞춘다.
enum VlogFontScale: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }
    var displayName: String { L("vlog.fontScale.\(rawValue)") }

    /// 기준 크기에 곱하는 배율 (등비 스텝, 보통을 기준으로 상향 조정됨)
    var multiplier: CGFloat {
        switch self {
        case .small:  return 1.0
        case .medium: return 1.28
        case .large:  return 1.64
        }
    }
}
