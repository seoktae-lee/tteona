import SwiftUI

/// 게스트가 서버 기능(그룹·코스·발자취)에 닿았을 때 보여주는 안내.
///
/// 막는 게 목적이 아니라 **왜 계정이 필요한지**를 말하고 그 자리에서 가입하게 하는 화면이다.
/// 촬영·브이로그는 게스트로도 끝까지 되므로, 여기까지 온 유저는 이미 결과물을 손에 쥔 상태다.
struct GuestGateView: View {
    let icon: String
    let title: String
    let message: String

    @State private var showAuth = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.tteOrange.opacity(0.10))
                    .frame(width: 120, height: 120)
                Image(systemName: icon)
                    .font(.tte(40))
                    .foregroundColor(.tteOrange)
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.tte(19, .bold))
                    .foregroundColor(.tteDarkGray)
                Text(message)
                    .font(.tte(14))
                    .foregroundColor(.tteMediumGray)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .padding(.horizontal, 40)

            Button {
                Haptics.light()
                showAuth = true
            } label: {
                Text(L("guest.signUp"))
                    .font(.tte(16, .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 15).fill(Color.tteOrange))
            }
            .padding(.horizontal, 32)
            .padding(.top, 6)

            // 촬영은 계정 없이도 된다는 걸 분명히 해 둔다 — 막힌 느낌을 줄인다
            Text(L("guest.captureStillFree"))
                .font(.tte(12.5))
                .foregroundColor(.tteMediumGray.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .fullScreenCover(isPresented: $showAuth) { AuthView() }
    }
}
