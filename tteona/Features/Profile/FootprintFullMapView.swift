import SwiftUI

// MARK: - 발자취 지도 전체화면
/// 프로필의 임베드 지도는 페이지 스크롤과 충돌해 팬/핀치를 껐다.
/// 이 전체화면에서만 팬·핀치·탭이 모두 살아나 세계지도를 자유롭게 탐색한다.
struct FootprintFullMapView: View {
    let summary: FootprintSummary
    var routes: [[FootprintPoint]] = []
    var initialFocus: FootprintMapFocus = .korea
    var subtitle: String? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            Color(hex: "#FBF8F3").ignoresSafeArea()

            FootprintMapView(
                summary: summary,
                routes: routes,
                interactive: true,
                panZoom: true,          // 전체화면에서는 팬/핀치 활성 — 이 뷰의 존재 이유
                initialFocus: initialFocus
            )
            .ignoresSafeArea(edges: .bottom)

            // 상단 바 — 제목 + 진행 텍스트 + 닫기
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("footprint.title"))
                        .font(.tte(18, .bold))
                        .foregroundColor(.tteDarkGray)
                    if let subtitle {
                        Text(subtitle)
                            .font(.tte(12, .semibold))
                            .foregroundColor(.tteOrange)
                    }
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 36, height: 36)
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        Image(systemName: "xmark")
                            .font(.tte(15, .semibold))
                            .foregroundColor(.tteDarkGray)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }
}
