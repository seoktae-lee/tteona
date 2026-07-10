import SwiftUI
import Combine

// MARK: - 앱 지원 언어
enum AppLanguage: String, CaseIterable, Identifiable {
    case korean = "ko"
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    var flag: String {
        switch self {
        case .korean: return "🇰🇷"
        case .english: return "🇺🇸"
        case .japanese: return "🇯🇵"
        }
    }

    /// 해당 언어 자체 표기 — 언어 목록에서는 항상 원어로 보여준다
    var nativeName: String {
        switch self {
        case .korean: return "한국어"
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }
}

extension Notification.Name {
    /// 앱 언어가 바뀌었다 — 푸시 토큰의 lang 재등록 트리거
    static let appLanguageChanged = Notification.Name("appLanguageChanged")
}

// MARK: - 언어 관리자
/// 선택 언어를 UserDefaults에 저장하고, 해당 언어의 .lproj 번들에서 문자열을 찾는다.
/// 언어 변경 시 루트 뷰가 `.id(language)`로 전체 재구성되어 앱 전역에 즉시 반영된다.
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()
    private static let storageKey = "app.language"

    @Published private(set) var language: AppLanguage
    private(set) var bundle: Bundle

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.storageKey)
            .flatMap(AppLanguage.init(rawValue:))
        let initial = saved ?? Self.systemDefault()
        language = initial
        bundle = Self.bundle(for: initial)
        // 이전 버전에서 언어를 고른 유저는 AppleLanguages가 비어 있다 — 여기서 한 번 맞춰준다.
        if saved != nil { Self.syncProcessLocale(initial) }
    }

    /// 저장된 선택이 없으면 시스템 언어를 따른다 (ko/ja 외에는 영어)
    private static func systemDefault() -> AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("ko") { return .korean }
        if preferred.hasPrefix("ja") { return .japanese }
        return .english
    }

    func setLanguage(_ newLanguage: AppLanguage) {
        guard newLanguage != language else { return }
        bundle = Self.bundle(for: newLanguage)
        UserDefaults.standard.set(newLanguage.rawValue, forKey: Self.storageKey)
        Self.syncProcessLocale(newLanguage)
        language = newLanguage
        // 푸시 문구는 서버가 기기에 등록된 언어로 만든다 — 바뀐 언어를 다시 등록해야
        // 다음 알림부터 새 언어로 온다.
        NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
    }

    var locale: Locale { Locale(identifier: language.rawValue) }

    private static func bundle(for language: AppLanguage) -> Bundle {
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }

    /// GMSMapView는 타일 라벨을 프로세스 로케일(AppleLanguages)로 그리고, Google Maps iOS SDK에는
    /// 런타임 언어 오버라이드 API가 없다. AppleLanguages는 프로세스 시작 시 한 번만 읽히므로
    /// 여기서 써 둔 값은 다음 실행부터 적용된다 — 설정 화면이 재시작 안내를 띄우는 이유.
    private static func syncProcessLocale(_ language: AppLanguage) {
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }
}

// MARK: - 전역 문자열 헬퍼
/// 선택 언어 번들에서 키에 해당하는 문자열을 반환한다.
func L(_ key: String) -> String {
    LanguageManager.shared.bundle.localizedString(forKey: key, value: nil, table: nil)
}

/// 포맷 인자가 있는 문자열용 — 카탈로그 값은 %@, %d 등 포맷 지정자를 사용한다.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: LanguageManager.shared.locale, arguments: args)
}
