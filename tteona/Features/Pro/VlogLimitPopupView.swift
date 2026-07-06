import SwiftUI

/// 촬영 한도 도달 팝업 — 시스템 알림 대신 tteona 분위기의 카드형 팝업.
/// 무료 유저에게는 PRO 업그레이드 CTA, PRO 유저에게는 안내만 표시한다.
struct VlogLimitPopupView: View {
    let isPro: Bool
    var onUpgrade: () -> Void = {}
    var onDismiss: () -> Void = {}

    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                // 아이콘 + 타이틀
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(colors: [Color.tteOrange.opacity(0.35), Color.tteOrange.opacity(0.1)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 72, height: 72)
                    Image(systemName: isPro ? "checkmark.seal.fill" : "timer")
                        .font(.tte(30, .semibold))
                        .foregroundStyle(
                            LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.45), .tteOrange],
                                           startPoint: .top, endPoint: .bottom)
                        )
                }
                .padding(.top, 28)

                Text(L("vloglimit.title"))
                    .font(.tte(20, .bold))
                    .foregroundColor(.white)
                    .padding(.top, 16)

                Text(isPro
                     ? L("vloglimit.durationMsg")
                     : L("vloglimit.freeMsg"))
                    .font(.tte(14))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 8)
                    .padding(.horizontal, 24)

                if !isPro {
                    // PRO 혜택 하이라이트
                    VStack(alignment: .leading, spacing: 8) {
                        Image("tteona-pro-logo")
                            .resizable()
                            .renderingMode(.original)
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 20)
                        Text(L("vloglimit.proFeature"))
                            .font(.tte(12))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.tteOrange.opacity(0.35), lineWidth: 1)
                    )
                    .padding(.top, 18)
                    .padding(.horizontal, 20)

                    Button(action: onUpgrade) {
                        Text(L("vloglimit.learnPro"))
                            .font(.tte(16, .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(RoundedRectangle(cornerRadius: 15).fill(Color.tteOrange))
                    }
                    .padding(.top, 18)
                    .padding(.horizontal, 20)
                }

                Button(action: onDismiss) {
                    Text(L("common.ok"))
                        .font(.tte(15, .medium))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .padding(.top, isPro ? 20 : 6)
                .padding(.bottom, 14)
                .padding(.horizontal, 20)
            }
            .frame(maxWidth: 330)
            .background(
                RoundedRectangle(cornerRadius: 26)
                    .fill(
                        LinearGradient(colors: [Color(red: 0.12, green: 0.11, blue: 0.16),
                                                Color(red: 0.07, green: 0.06, blue: 0.1)],
                                       startPoint: .top, endPoint: .bottom)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .scaleEffect(appeared ? 1 : 0.92)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { appeared = true }
        }
    }
}
