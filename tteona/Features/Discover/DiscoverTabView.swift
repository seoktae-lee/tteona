import SwiftUI

/// 지도(MainView)와 목록(ExploreGridView)을 한 탭으로 묶는 컨테이너.
///
/// 둘 다 코스를 "찾는" 화면이라 탭을 나눠 둘 이유가 없었다. 상단 토글로 전환한다.
///
/// 전환 시 두 화면을 파괴하지 않고 opacity로 감춘다 — 재생성하면 `.task`가 다시 돌아
/// 코스를 재조회하고 지도 카메라가 초기 위치로 튄다. 대신 목록은 처음 켤 때까지
/// 만들지 않아(`gridActivated`) 지도만 쓰는 유저는 그리드 로딩 비용을 내지 않는다.
struct DiscoverTabView: View {
    enum Mode: String { case map, grid }

    @AppStorage("discover.mode") private var modeRaw = Mode.map.rawValue
    /// 목록을 한 번이라도 열었는가 — 열기 전엔 뷰 자체를 만들지 않는다
    @State private var gridActivated = false

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .map }

    /// 토글이 차지하는 높이 — 두 화면의 상단 콘텐츠를 이만큼 내려 겹치지 않게 한다
    private static let toggleHeight: CGFloat = 34
    private static let contentInset: CGFloat = toggleHeight + 12

    var body: some View {
        ZStack(alignment: .bottom) {
            MainView()
                .opacity(mode == .map ? 1 : 0)
                .allowsHitTesting(mode == .map)

            if gridActivated {
                ExploreGridView(topInset: 8)
                    .opacity(mode == .grid ? 1 : 0)
                    .allowsHitTesting(mode == .grid)
            }

            // 지도를 가리지 않도록 하단 플로팅 — '나의 오늘' CTA가 촬영 탭으로 가며 빈 자리다
            modeToggle
        }
        .onAppear {
            // 마지막에 목록을 보고 있었다면 복귀 시 바로 만들어 둔다
            if mode == .grid { gridActivated = true }
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
            if target == .grid { gridActivated = true }
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
