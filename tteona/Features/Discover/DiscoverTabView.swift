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

    /// 지도의 코스 선택 상태. MainView가 아니라 여기서 들고 있는다 —
    /// 미리보기 카드가 뜨면 아래 토글과 겹치므로 토글을 접어야 하는데,
    /// 그 판단을 하려면 토글 주인이 선택 상태를 알아야 한다.
    @StateObject private var mapSelection = MapSelection()

    /// 토글이 차지하는 높이 — 두 화면의 상단 콘텐츠를 이만큼 내려 겹치지 않게 한다
    private static let toggleHeight: CGFloat = 34
    private static let contentInset: CGFloat = toggleHeight + 12

    var body: some View {
        // 토글을 ZStack 형제로 두지 않고 **오버레이**로 얹는다.
        //
        // 지도(UIViewRepresentable)를 ZStack에 형제와 나란히 두면 SwiftUI 갱신 사이클이
        // 깨진다. **실측으로 확인했다** — 핀을 눌러 선택 상태를 바꿔도 카드가 만들어지지
        // 않았고(값은 들어가는데 뷰가 안 생김), 오버레이로 바꾸자 즉시 정상 동작했다.
        // 예전에 둘 다 살려두고 opacity로 감췄을 때 "지도 마커가 영영 갱신되지 않던" 것도
        // 같은 계열이다. 이 파일에서 두 번 반복된 함정이니 형제로 되돌리지 말 것.
        //
        // 촬영 탭이 생기기 전에는 MainView가 TabView의 직접 자식이라 형제가 없었고,
        // 그때는 카드가 곧바로 떴다. 그 구조에 최대한 가깝게 되돌린다.
        content
            .overlay(alignment: .bottom) {
                // 지도를 가리지 않도록 하단 플로팅 — '나의 오늘' CTA가 촬영 탭으로 가며 빈 자리다
                // 코스 카드가 떠 있는 동안은 접는다. 카드를 보는 사람은 그 코스를 판단하는
                // 중이지 화면을 갈아탈 생각이 없고, 그대로 두면 CTA 위에 겹쳐 앉는다.
                if mapSelection.course == nil && mapSelection.place == nil {
                    modeToggle
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
    }

    /// 활성인 쪽만 그린다. 전환할 때 다시 불러오는 비용이, 감춘 화면이 터치를 가로채고
    /// 갱신 사이클을 깨뜨리는 대가보다 훨씬 싸다.
    @ViewBuilder
    private var content: some View {
        if mode == .map {
            MainView(selection: mapSelection)
        } else {
            ExploreGridView(topInset: 8)
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
