import SwiftUI

/// 게스트가 서버 기능(그룹·코스·발자취)에 닿았을 때 보여주는 안내.
///
/// 막는 게 목적이 아니라 **왜 계정이 필요한지**를 말하고 그 자리에서 가입하게 하는 화면이다.
/// 촬영과 첫 브이로그는 게스트로도 되므로, 여기까지 온 유저는 이미 결과물을 손에 쥔 상태다.
///
/// 화면 구성 원칙 두 가지:
/// - **떠니를 세운다.** SF Symbol을 원형 배경에 올리면 어느 앱에나 어울리는 화면이 된다.
///   우리 캐릭터가 탭마다 다른 표정으로 서 있어야 '떠나의 화면'이 된다.
/// - **가운데 정렬을 깬다.** 위아래 Spacer로 전부 가운데 띄우는 건 만들다 만 화면처럼 보인다.
///   설명은 위에, 버튼은 엄지가 닿는 아래에 고정한다.
struct GuestGateView: View {
    /// 탭마다 다른 떠니 포즈 (Assets: tteoni-*)
    let mascot: String
    let title: String
    let message: String
    /// 우상단 설정 통로를 둘지. 프로필 탭 게이트만 켠다 —
    /// 게스트도 언어·약관·개인정보처리방침에는 닿을 수 있어야 한다.
    var showsSettings: Bool = false

    @State private var showAuth = false
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            mascotArea

            VStack(spacing: 10) {
                Text(title)
                    .font(.tte(21, .bold))
                    .foregroundColor(.tteDarkGray)
                Text(message)
                    .font(.tte(14.5))
                    .foregroundColor(.tteMediumGray)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 44)
            .padding(.top, 26)

            Spacer(minLength: 28)

            VStack(spacing: 14) {
                Button {
                    Haptics.light()
                    showAuth = true
                } label: {
                    Text(L("guest.signUp"))
                        .font(.tte(16, .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.tteOrange)
                                .shadow(color: Color.tteOrange.opacity(0.28), radius: 12, y: 5)
                        )
                }

                // 촬영은 계정 없이도 된다는 걸 분명히 해 둔다 — 막힌 느낌을 줄인다
                Text(L("guest.captureStillFree"))
                    .font(.tte(12.5))
                    .foregroundColor(.tteMediumGray.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 로그인 화면(AuthView)과 같은 배경 — 버튼을 누르면 그 화면으로 넘어가므로
        // 배경이 이어져야 전환이 끊기지 않는다. 흰 바탕 고정이라 다크 모드에서도
        // 글자 대비가 흔들리지 않는다.
        .background(TteonaSplashBackground())
        .overlay(alignment: .topTrailing) {
            if showsSettings {
                NavigationLink { SettingsView() } label: {
                    Image(systemName: "gearshape")
                        .font(.tte(17, .medium))
                        .foregroundColor(.tteDarkGray.opacity(0.7))
                        .frame(width: 44, height: 44)
                }
                .padding(.trailing, 4)
            }
        }
        .fullScreenCover(isPresented: $showAuth) { AuthView(isDismissable: true) }
        .onAppear {
            guard !appeared else { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(0.05)) {
                appeared = true
            }
        }
    }

    // MARK: - 떠니

    private var mascotArea: some View {
        ZStack {
            // 캐릭터가 허공에 뜨지 않도록 바닥에 옅은 그림자를 깐다
            Ellipse()
                .fill(Color.tteOrange.opacity(0.10))
                .frame(width: 132, height: 18)
                .blur(radius: 8)
                .offset(y: 76)

            Image(mascot)
                .resizable()
                .scaledToFit()
                .frame(width: 168, height: 168)
                .offset(y: appeared ? 0 : 10)
                .opacity(appeared ? 1 : 0)
        }
    }

}
