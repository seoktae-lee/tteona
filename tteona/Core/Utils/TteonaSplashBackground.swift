import SwiftUI

/// 앱 진입·로딩·로그인 화면용 — 흰 바탕 위 주황색 글로우가 천천히 일렁이는 배경
struct TteonaSplashBackground: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            Circle()
                .fill(Color.tteOrange.opacity(0.16))
                .frame(width: 420, height: 420)
                .blur(radius: 90)
                .offset(x: animate ? -110 : 130, y: animate ? -200 : -80)
            Circle()
                .fill(Color(red: 1.0, green: 0.63, blue: 0.35).opacity(0.12))
                .frame(width: 360, height: 360)
                .blur(radius: 80)
                .offset(x: animate ? 130 : -100, y: animate ? 180 : 300)
            Circle()
                .fill(Color.tteOrange.opacity(0.09))
                .frame(width: 320, height: 320)
                .blur(radius: 85)
                .offset(x: animate ? -60 : 80, y: animate ? 300 : 70)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}

/// 워드마크 PNG(500×500)에서 실제 글자 높이 ≈52pt로 맞춘 로고
struct TteonaWordmarkLogo: View {
    var body: some View {
        Image("tteona-logo")
            .resizable()
            .scaledToFit()
            .frame(width: 268)
            .padding(.vertical, -108)
    }
}
