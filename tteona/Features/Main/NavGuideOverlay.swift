import SwiftUI

// MARK: - 첫 실행 내비게이션 가이드
// 온보딩 직후 메인 화면 위에서 나루가 탭 구성을 스포트라이트로 안내하는 코치마크.
// 스텝이 넘어가면 실제로 해당 탭으로 전환해 화면을 직접 보여준다.
struct NavGuideOverlay: View {
    @Binding var selectedTab: Int
    let onFinish: () -> Void

    @State private var stepIndex = 0

    init(selectedTab: Binding<Int>, onFinish: @escaping () -> Void) {
        self._selectedTab = selectedTab
        self.onFinish = onFinish
        #if DEBUG
        // 시각 검증용: -previewGuideStep N 런치 아규먼트로 특정 스텝 바로 진입
        let preview = UserDefaults.standard.integer(forKey: "previewGuideStep")
        if preview > 0 { _stepIndex = State(initialValue: min(preview, 4)) }
        #endif
    }

    private struct GuideStep {
        let mascot: String
        let title: String
        let message: String
        let tabIndex: Int?   // nil이면 중앙 카드 (환영/마무리)
    }

    private let steps: [GuideStep] = [
        GuideStep(
            mascot: "tteoni-guide",
            title: "안녕하세요, 나루예요!",
            message: "떠나를 30초만에 둘러볼까요?\n제가 안내해드릴게요",
            tabIndex: nil
        ),
        GuideStep(
            mascot: "tteoni-travel",
            title: "홈 — 지도에서 떠나기",
            message: "지도에서 마음에 드는 코스를 골라\n'떠나기'를 누르면 여행이 시작돼요",
            tabIndex: 0
        ),
        GuideStep(
            mascot: "tteoni-wink",
            title: "탐색 — 코스 모아보기",
            message: "전 세계 코스를 카드로 넘겨보고\n인기 코스를 발견해보세요",
            tabIndex: 1
        ),
        GuideStep(
            mascot: "tteoni-jump",
            title: "채팅 — 함께 떠나기",
            message: "그룹을 만들어 친구·가족과\n코스와 '나의 오늘'을 공유해요",
            tabIndex: 2
        ),
        GuideStep(
            mascot: "tteoni-thumbsup",
            title: "준비 완료!",
            message: "이제 지도에서 첫 코스를 골라\n떠나볼 일만 남았어요",
            tabIndex: nil
        ),
    ]

    private var step: GuideStep { steps[stepIndex] }
    private var isLast: Bool { stepIndex == steps.count - 1 }

    // 스포트라이트 크기 — 탭 아이콘+라벨을 감싸는 캡슐
    private let spotSize = CGSize(width: 84, height: 58)

    /// 탭 아이템 중심 X.
    /// iOS 26 플로팅(리퀴드 글래스) 탭바는 아이템이 중앙으로 모여 있어
    /// 화면 4등분 좌표가 실제 아이콘과 어긋난다 — 실측 기반 간격(폭×0.21) 사용.
    private func tabCenterX(_ tab: Int, width: CGFloat) -> CGFloat {
        if #available(iOS 26.0, *) {
            return width / 2 + (CGFloat(tab) - 1.5) * width * 0.21
        } else {
            return (CGFloat(tab) + 0.5) * width / 4
        }
    }

    var body: some View {
        GeometryReader { geo in
            let spotlightY = geo.size.height - 25

            ZStack {
                // 딤 배경 + 탭 스포트라이트 컷아웃
                ZStack {
                    Rectangle()
                        .fill(Color.black.opacity(0.6))
                        .ignoresSafeArea()

                    if let tab = step.tabIndex {
                        Capsule()
                            .frame(width: spotSize.width, height: spotSize.height)
                            .position(x: tabCenterX(tab, width: geo.size.width), y: spotlightY)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
                .contentShape(Rectangle())
                .onTapGesture { advance() }

                // 스포트라이트 링
                if let tab = step.tabIndex {
                    Capsule()
                        .stroke(Color.white.opacity(0.9), lineWidth: 2)
                        .frame(width: spotSize.width, height: spotSize.height)
                        .position(x: tabCenterX(tab, width: geo.size.width), y: spotlightY)
                        .shadow(color: .tteOrange.opacity(0.6), radius: 10)
                }

                // 가이드 카드
                guideCard(geo: geo)
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: stepIndex)
        }
        .onAppear {
            if let tab = step.tabIndex { selectedTab = tab }
        }
        .onChange(of: stepIndex) { _, newValue in
            // 스포트라이트 대상 탭으로 실제 전환해 화면을 함께 보여준다
            if let tab = steps[newValue].tabIndex {
                withAnimation { selectedTab = tab }
            } else if newValue == steps.count - 1 {
                withAnimation { selectedTab = 0 }
            }
        }
    }

    // MARK: 가이드 카드 (나루 + 말풍선)
    private func guideCard(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            if step.tabIndex != nil { Spacer() }

            VStack(spacing: 16) {
                Image(step.mascot)
                    .resizable()
                    .scaledToFit()
                    .frame(width: step.tabIndex == nil ? 150 : 100,
                           height: step.tabIndex == nil ? 150 : 100)
                    .floating(amplitude: 6, speed: 1.3)

                VStack(spacing: 8) {
                    Text(step.title)
                        .font(.tte(20, .bold))
                        .foregroundColor(.tteDarkGray)
                    Text(step.message)
                        .font(.tte(15))
                        .foregroundColor(.tteMediumGray)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    if !isLast {
                        Button {
                            Haptics.light()
                            onFinish()
                        } label: {
                            Text("건너뛰기")
                                .font(.tte(15, .medium))
                                .foregroundColor(.tteMediumGray)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(UIColor.secondarySystemBackground))
                                )
                        }
                    }

                    Button { advance() } label: {
                        Text(isLast ? "떠나볼까요!" : "다음 \(stepIndex + 1)/\(steps.count)")
                            .font(.tte(15, .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.tteOrange)
                            )
                    }
                }
            }
            .padding(24)
            .background(
                GuideCardBackground()
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
            )
            .padding(.horizontal, 32)
            .id(stepIndex)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))

            if let tab = step.tabIndex {
                // 스포트라이트를 가리키는 화살표 — 꼬리 끝이 스포트라이트 바로 위에 닿도록
                Triangle()
                    .fill(Color.tteBackground)
                    .frame(width: 22, height: 12)
                    .rotationEffect(.degrees(180))
                    .offset(x: tabCenterX(tab, width: geo.size.width) - geo.size.width / 2)
                    .padding(.top, -1)

                // 화면 하단(안전영역)부터 스포트라이트 상단까지의 간격
                Spacer().frame(height: 25 + spotSize.height / 2 + 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: step.tabIndex == nil ? .center : .bottom)
    }

    private func advance() {
        if isLast {
            Haptics.success()
            onFinish()
        } else {
            Haptics.light()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                stepIndex += 1
            }
        }
    }
}

// MARK: - 가이드 카드 배경 — 흰 바탕 위 주황 글로우가 천천히 일렁임 (로그인 화면과 동일한 무드)
private struct GuideCardBackground: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Color.tteBackground

            Circle()
                .fill(Color.tteOrange.opacity(0.32))
                .frame(width: 220, height: 220)
                .blur(radius: 40)
                .offset(x: animate ? -90 : 70, y: animate ? -80 : -20)
            Circle()
                .fill(Color(red: 1.0, green: 0.63, blue: 0.35).opacity(0.26))
                .frame(width: 190, height: 190)
                .blur(radius: 36)
                .offset(x: animate ? 100 : -60, y: animate ? 90 : 140)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}

// MARK: - 말풍선 꼬리 삼각형
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    ZStack {
        Color.gray.ignoresSafeArea()
        NavGuideOverlay(selectedTab: .constant(0), onFinish: {})
    }
}
