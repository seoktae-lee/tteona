import SwiftUI

/// 마스코트(뜨오니)가 등장하는 공용 빈 화면 뷰.
/// SF Symbol 회색 아이콘 대신 브랜드 캐릭터를 노출해 빈 화면에서도 앱의 개성을 유지한다.
/// - 사용처: 탐색 탭 빈 목록, 그룹 탭 빈 목록, 홈 검색 결과 없음 등
struct TteEmptyState: View {
    /// 에셋 카탈로그의 뜨오니 이미지 이름 (tteoni-front / guide / jump / thumbsup / travel / wink)
    var image: String = "tteoni-front"
    let title: String
    var subtitle: String? = nil
    var imageSize: CGFloat = 130

    @State private var bounce = false

    var body: some View {
        VStack(spacing: 14) {
            Image(image)
                .resizable()
                .scaledToFit()
                .frame(width: imageSize, height: imageSize)
                .offset(y: bounce ? -6 : 0)
                // 암시적 .animation(_:value:)은 같은 트랜잭션의 레이아웃 이동까지 물고 repeatForever로
                // 되풀이해 캐릭터가 사선으로 흔들렸다. withAnimation으로 offset 변화만 애니메이션한다.
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        bounce = true
                    }
                }
                .accessibilityHidden(true)

            Text(title)
                .font(.tte(17, .bold))
                .foregroundColor(.tteDarkGray)
                .multilineTextAlignment(.center)

            if let subtitle {
                Text(subtitle)
                    .font(.tte(14))
                    .foregroundColor(.tteMediumGray)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 32)
    }
}

#Preview {
    VStack(spacing: 60) {
        TteEmptyState(image: "tteoni-guide", title: "아직 코스가 없어요", subtitle: "첫 코스를 만들어보세요")
        TteEmptyState(image: "tteoni-wink", title: "검색 결과가 없어요")
    }
}
