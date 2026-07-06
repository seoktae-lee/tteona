import SwiftUI

/// 설정 > 언어 — 국기와 원어 표기로 언어를 고르면 앱 전체에 즉시 반영된다.
struct LanguageSettingsView: View {
    @ObservedObject private var languageManager = LanguageManager.shared

    var body: some View {
        List {
            Section {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        guard language != languageManager.language else { return }
                        Haptics.light()
                        languageManager.setLanguage(language)
                    } label: {
                        HStack(spacing: 12) {
                            Text(language.flag)
                                .font(.system(size: 26))
                            Text(language.nativeName)
                                .font(.tte(16, .medium))
                                .foregroundColor(.tteDarkGray)
                            Spacer()
                            if language == languageManager.language {
                                Image(systemName: "checkmark")
                                    .font(.tte(15, .semibold))
                                    .foregroundColor(.tteOrange)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text(L("settings.language.footer"))
                    .font(.tte(12))
                    .foregroundColor(.tteMediumGray)
            }
        }
        .navigationTitle(L("settings.language"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
