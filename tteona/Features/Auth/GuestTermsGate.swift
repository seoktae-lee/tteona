import SwiftUI

/// 게스트가 앱을 처음 열었을 때 받는 약관 동의.
///
/// 계정 온보딩(닉네임·스타일·권한·약관)은 가입한 사람만 거치는데, 게스트도 촬영하고
/// 브이로그를 만들고 앨범에 저장까지 한다 — 서비스를 온전히 쓰면서 동의만 없는 상태였다.
///
/// **내비 가이드의 한 단계로 넣지 않은 이유**: 그 가이드에는 '건너뛰기'가 있다.
/// 건너뛸 수 있으면 동의가 아니고, 투어의 한 장면으로 보이면 동의를 받았다는 근거도 약하다.
/// 그래서 가이드보다 앞에, 넘어갈 수 없는 화면으로 세운다.
struct GuestTermsGate: View {
    let onAgree: () -> Void

    @State private var agreedTerms = false
    @State private var agreedPrivacy = false
    @State private var appeared = false
    /// 환영 문구가 다 찍혔는가 — 축하 파티클과 부제 등장을 여기에 맞춘다
    @State private var welcomeTyped = false

    private var allAgreed: Bool { agreedTerms && agreedPrivacy }

    var body: some View {
        ZStack {
            TteonaSplashBackground()

            VStack(spacing: 0) {
                // 언어를 여기서도 바꿀 수 있어야 한다 — 약관은 읽고 동의하는 화면이라
                // 읽을 수 없는 언어로 떠 있으면 동의를 받는 의미가 없다.
                HStack {
                    Spacer()
                    languagePicker
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Spacer(minLength: 12)

                Image("tteoni-guide")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 132, height: 132)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)

                // 받을 것(동의)보다 줄 것(브이로그)을 먼저 말한다.
                // 인사 없이 동의부터 요구하면 첫 화면이 요구로 시작해 방어적으로 읽힌다.
                VStack(spacing: 12) {
                    // 이 화면에서 가장 먼저 읽혀야 할 한 줄 — 동의를 요구하기 전에
                    // 무엇을 받는지부터 보여준다
                    Text(L("guestTerms.badge"))
                        .font(.tte(13, .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Capsule().fill(Color.tteOrange))
                        .shadow(color: Color.tteOrange.opacity(0.3), radius: 8, y: 3)
                        .opacity(appeared ? 1 : 0)
                        .scaleEffect(appeared ? 1 : 0.9)

                    // 한 글자씩 찍히고, 마지막 '!'에서 양옆으로 팡
                    TypewriterText(text: L("guestTerms.title"),
                                   font: .tte(27, .bold),
                                   color: .tteDarkGray,
                                   speed: 0.11) {
                        Haptics.success()
                        withAnimation(.easeOut(duration: 0.35)) { welcomeTyped = true }
                    }
                    .overlay(alignment: .leading) {
                        if welcomeTyped {
                            ConfettiBurst(baseAngle: 180, spread: 90,
                                          pieceCount: 16, distance: 130)
                                .offset(x: -10)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if welcomeTyped {
                            ConfettiBurst(baseAngle: 0, spread: 90,
                                          pieceCount: 16, distance: 130)
                                .offset(x: 10)
                        }
                    }

                    Text(L("guestTerms.subtitle"))
                        .font(.tte(16))
                        .foregroundColor(.tteDarkGray.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                        // 문구가 다 찍힌 뒤에 이어서 나타난다
                        .opacity(welcomeTyped ? 1 : 0)
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)

                Spacer(minLength: 20)

                VStack(spacing: 12) {
                    Text(L("guestTerms.consentNote"))
                        .font(.tte(12.5))
                        .foregroundColor(.tteMediumGray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                        .padding(.bottom, 2)

                    Button {
                        let newValue = !allAgreed
                        withAnimation { agreedTerms = newValue; agreedPrivacy = newValue }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: allAgreed ? "checkmark.circle.fill" : "circle")
                                .font(.tte(24))
                                .foregroundColor(allAgreed ? .tteOrange : Color(UIColor.tertiaryLabel))
                            Text(L("onboarding.terms.agreeAll"))
                                .font(.tte(16, .semibold))
                                .foregroundColor(.tteDarkGray)
                            Spacer()
                        }
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(allAgreed ? Color.tteOrange.opacity(0.06)
                                                : Color(UIColor.secondarySystemBackground))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(allAgreed ? Color.tteOrange.opacity(0.3) : Color.clear,
                                                lineWidth: 1.5)
                                )
                        )
                    }

                    Divider().padding(.horizontal, 8)

                    TermsRow(title: L("onboarding.terms.service"), isRequired: true,
                             url: URL(string: "https://tteona.kr/terms.html")!,
                             isChecked: $agreedTerms)
                    TermsRow(title: L("onboarding.terms.privacy"), isRequired: true,
                             url: URL(string: "https://tteona.kr/privacy.html")!,
                             isChecked: $agreedPrivacy)
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 20)

                Button {
                    Haptics.light()
                    onAgree()
                } label: {
                    Text(L("guestTerms.start"))
                        .font(.tte(17, .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.tteOrange))
                }
                .disabled(!allAgreed)
                .opacity(allAgreed ? 1 : 0.4)
                .scaleEffect(allAgreed ? 1 : 0.95)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: allAgreed)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(0.05)) {
                appeared = true
            }
        }
    }

    private var languagePicker: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    guard language != LanguageManager.shared.language else { return }
                    Haptics.light()
                    LanguageManager.shared.setLanguage(language)
                } label: {
                    if language == LanguageManager.shared.language {
                        Label("\(language.flag) \(language.nativeName)", systemImage: "checkmark")
                    } else {
                        Text("\(language.flag) \(language.nativeName)")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.tte(13, .medium))
                Text(LanguageManager.shared.language.nativeName).font(.tte(13, .medium))
                Image(systemName: "chevron.down").font(.tte(10, .semibold))
            }
            .foregroundColor(.tteMediumGray)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color(UIColor.secondarySystemBackground)))
        }
    }
}

/// 게스트 약관 동의 기록. 기기 단위로 남긴다 —
/// 익명 uid는 재설치·카카오 로그인 등으로 바뀔 수 있어서 그걸 키로 쓰면 다시 물어보게 된다.
enum GuestTermsConsent {
    private static let key = "guestTermsAgreedAt"

    static var isAgreed: Bool { UserDefaults.standard.object(forKey: key) != nil }

    static func record() {
        UserDefaults.standard.set(Date(), forKey: key)
    }
}
