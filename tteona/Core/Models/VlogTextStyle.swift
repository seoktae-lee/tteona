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

/// 자막에 무엇을 보여줄지. 키는 서버(job options.subtitleFields)·안드로이드와 공유한다.
enum VlogSubtitleFields: String, CaseIterable, Identifiable {
    case both    // 장소 + 시각
    case place   // 장소만
    case time    // 시각만

    var id: String { rawValue }
    var displayName: String { L("vlog.subtitleFields.\(rawValue)") }

    var showsPlace: Bool { self != .time }
    var showsTime: Bool { self != .place }
}

/// 자막 강조색 프리셋.
///
/// **서버로는 키(`rawValue`)만 보내고 실제 색값은 서버가 자기 표에서 찾는다.**
/// 색값을 그대로 넘기면 사용자 입력이 ffmpeg 필터 문자열에 직접 섞여 들어가는 통로가 된다
/// (`fontcolor=` 뒤는 필터 인자로 파싱되므로 `:`·`,` 한 글자로 체인을 조작할 수 있다).
enum VlogSubtitleColor: String, CaseIterable, Identifiable {
    case orange   // 기본 — tteOrange
    case white
    case yellow
    case mint
    case sky
    case pink
    case ink      // 밝은 영상용 먹색

    var id: String { rawValue }
    var displayName: String { L("vlog.subtitleColor.\(rawValue)") }

    /// 로컬 폴백 렌더용. 서버 `VLOG_SUBTITLE_COLORS`와 같은 값을 유지해야 한다.
    var uiColor: UIColor {
        switch self {
        case .orange: return UIColor(red: 1.00, green: 0.42, blue: 0.21, alpha: 1)  // FF6B35
        case .white:  return UIColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1)  // FFFFFF
        case .yellow: return UIColor(red: 1.00, green: 0.83, blue: 0.00, alpha: 1)  // FFD400
        case .mint:   return UIColor(red: 0.24, green: 0.86, blue: 0.59, alpha: 1)  // 3DDC97
        case .sky:    return UIColor(red: 0.31, green: 0.76, blue: 0.97, alpha: 1)  // 4FC3F7
        case .pink:   return UIColor(red: 1.00, green: 0.48, blue: 0.71, alpha: 1)  // FF7AB6
        case .ink:    return UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)  // 1A1A1F
        }
    }

    var color: Color { Color(uiColor) }
}

/// 브이로그 자막 설정 한 묶음.
///
/// 서체·크기만 있던 시절엔 파라미터 두 개를 그대로 넘겼는데, 표시항목·색·캡션이 붙으면서
/// `generateVlog → buildComposition → makeTextLayer` 세 단계 시그니처가 함께 부풀었다.
/// 한 덩어리로 넘겨 호출부가 옵션 개수를 신경 쓰지 않게 한다.
struct VlogSubtitleStyle: Equatable {
    var font: VlogFont = .gowun
    var scale: VlogFontScale = .medium
    var fields: VlogSubtitleFields = .both
    var color: VlogSubtitleColor = .orange
    /// 자막을 클립이 끝날 때까지 띄워 둘지.
    /// 꺼두면 지금처럼 2.5초만 보이고 사라진다 — 장면을 가리지 않는 대신 놓치기도 쉽다.
    var holdsSubtitle: Bool = false

    /// 장소별 한 줄 문구. 키는 클립 파일명 — 순번은 재정렬로 바뀔 수 있어 파일명에 묶는다.
    ///
    /// 서체·크기·표시항목·색은 브이로그 전체에 공통이고, **이 문구만 장소마다 다르다.**
    /// (예전엔 한 줄을 브이로그 하나에 하나만 두어 모든 클립에 같은 말이 반복됐다)
    var captions: [String: String] = [:]

    static let `default` = VlogSubtitleStyle()

    /// 한 줄이라는 약속을 지키기 위한 정리 — 줄바꿈·제어문자를 걷어내고 길이를 자른다.
    /// 서버도 같은 상한을 다시 적용한다(클라이언트를 믿지 않는다).
    static let captionMaxLength = 20

    /// 한 줄이라는 약속을 지키기 위한 정리 — 줄바꿈·앞뒤 공백을 걷어내고 길이를 자른다.
    static func sanitize(_ raw: String) -> String {
        let oneLine = raw
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(oneLine.prefix(captionMaxLength))
    }

    /// 해당 클립에 적힌 문구 (없으면 빈 문자열)
    func caption(for clipFileName: String?) -> String {
        guard let clipFileName else { return "" }
        return Self.sanitize(captions[clipFileName] ?? "")
    }
}

/// 자막이 화면 폭을 넘지 않게 크기를 낮추고, 그래도 넘치면 말줄임으로 자르는 규칙.
///
/// ffmpeg `drawtext`는 줄바꿈도 축소도 하지 않는다. `x=(w-text_w)/2`로 가운데를 맞추므로
/// 글자 폭이 화면보다 크면 x가 음수가 되어 양쪽 끝이 그대로 잘려 나간다.
/// 그래서 그리기 전에 미리 계산해 담기는 크기로 낮춘다.
///
/// **미리보기·로컬 렌더·서버가 모두 이 규칙을 따라야 한다.** 규칙이 서로 다르면
/// 미리보기에서 본 모습과 결과물이 어긋난다 (실제로 그런 상태였다 — 미리보기만 몰래 줄였다).
/// 서버 쪽 같은 구현은 server.js `fitSubtitle`.
enum VlogSubtitleFit {
    /// 화면 폭 중 실제로 쓰는 비율 — 가장자리에 여백을 남긴다
    static let usableRatio: Double = 0.90
    /// 고른 크기 대비 여기까지만 줄인다.
    /// 바닥이 없으면 긴 이름에서 '보통'과 '크게'가 똑같은 크기로 수렴해 단계 구분이 사라진다.
    /// 0.72는 한 단계(28%)만큼만 물러선다는 뜻이다.
    static let floorRatio: Double = 0.72

    /// 글자 폭 어림값. 한글·한자·가나는 한 칸(1em), 나머지는 대략 절반으로 본다.
    /// 폰트마다 실제 자폭이 달라 정확한 계산이 아니라 '넘치지 않게' 하는 보수적 추정이다.
    static func estimatedWidth(_ text: String, fontSize: Double) -> Double {
        var em = 0.0
        for scalar in text.unicodeScalars {
            em += isWide(scalar) ? 1.0 : 0.55
        }
        return em * fontSize
    }

    private static func isWide(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x1100...0x11FF, 0x3040...0x30FF, 0x3130...0x318F,
             0x4E00...0x9FFF, 0xAC00...0xD7A3, 0xFF00...0xFF60:
            return true
        default:
            return false
        }
    }

    /// 담기는 크기와 (필요하면 잘린) 글자를 돌려준다.
    /// 넘치지 않으면 고른 크기를 그대로 쓴다 — 짧은 이름은 아무 영향이 없다.
    static func fit(_ text: String, wanted: Double, frameWidth: Double) -> (size: Double, text: String) {
        let maxW = frameWidth * usableRatio
        guard maxW > 0, !text.isEmpty, wanted > 0 else { return (wanted, text) }

        let needed = estimatedWidth(text, fontSize: wanted)
        if needed <= maxW { return (wanted, text) }

        let size = max(wanted * maxW / needed, wanted * floorRatio)
        if estimatedWidth(text, fontSize: size) <= maxW { return (size, text) }

        // 바닥까지 줄여도 넘친다 — 말줄임으로 자른다
        var truncated = text
        while !truncated.isEmpty,
              estimatedWidth(truncated + "…", fontSize: size) > maxW {
            truncated.removeLast()
        }
        return (size, truncated.isEmpty ? "…" : truncated + "…")
    }
}
