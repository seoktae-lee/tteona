import SwiftUI

/// 지도(MainView)와 목록(ExploreGridView)을 한 탭으로 묶는 컨테이너.
///
/// 둘 다 코스를 "찾는" 화면이라 탭을 나눠 둘 이유가 없었다. 상단 토글로 전환한다.
///
/// 전환할 때 활성인 쪽만 그린다. 둘 다 살려두고 opacity로 감추는 방식은 전환이 빠른 대신
/// 감춘 화면이 터치를 가로채고 SwiftUI 갱신 사이클을 깨뜨렸다 — 재조회 비용이 훨씬 싸다.
struct DiscoverTabView: View {
    enum Mode: String { case map, grid }

    @AppStorage("discover.mode") private var modeRaw = Mode.map.rawValue
    private var mode: Mode { Mode(rawValue: modeRaw) ?? .map }

    /// 토글이 차지하는 높이 — 두 화면의 상단 콘텐츠를 이만큼 내려 겹치지 않게 한다
    private static let toggleHeight: CGFloat = 34
    private static let contentInset: CGFloat = toggleHeight + 12

    var body: some View {
        ZStack(alignment: .bottom) {
            // 활성인 쪽만 그린다.
            //
            // 처음엔 전환 시 상태를 잃지 않으려고 둘 다 살려두고 opacity로 감췄는데,
            // 그 구조가 버그를 두 개 만들었다 — 감춘 쪽이 터치를 가로챘고(필터 버튼 먹통),
            // SwiftUI 갱신 사이클이 깨져 지도 마커가 영영 갱신되지 않았다.
            // 전환할 때 다시 불러오는 비용이 그 대가보다 훨씬 싸다.
            if mode == .map {
                MainView()
            } else {
                ExploreGridView(topInset: 8)
            }

            // 지도를 가리지 않도록 하단 플로팅 — '나의 오늘' CTA가 촬영 탭으로 가며 빈 자리다
            modeToggle
        }
    }

    // MARK: - 지도 / 목록 토글

    private var modeToggle: some View {
        HStack(spacing: 0) {
            segment(.map,  icon: "map.fill",              label: L("discover.mode.map"))
            segment(.grid, icon: "square.grid.2x2.fill",  label: L("discover.mode.grid"))
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.bottom, 12)
        .zIndex(10)
    }

    private func segment(_ target: Mode, icon: String, label: String) -> some View {
        let selected = mode == target
        return Button {
            guard !selected else { return }
            Haptics.light()
            withAnimation(.easeInOut(duration: 0.2)) { modeRaw = target.rawValue }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.tte(12, .semibold))
                Text(label)
                    .font(.tte(13, .bold))
            }
            .foregroundColor(selected ? .white : .tteDarkGray)
            .padding(.horizontal, 16)
            .frame(height: Self.toggleHeight - 6)
            .background(
                Capsule().fill(selected ? Color.tteOrange : Color.clear)
            )
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
