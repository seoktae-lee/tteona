import SwiftUI

// MARK: - 온보딩 히어로 공통 컴포넌트
// 스플래시·기능 소개 단계의 프리미엄 비주얼 (아우라 배경, 플로팅 마스코트, 3D 틸트 카드)

// MARK: 아우라 배경 — 느리게 흐르는 블러 그라디언트 블롭
struct AuroraBackground: View {
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            blobs(t: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                blobs(t: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func blobs(t: TimeInterval) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: w * 0.9)
                    .blur(radius: 60)
                    .position(
                        x: w * 0.25 + CGFloat(sin(t * 0.23)) * 40,
                        y: h * 0.18 + CGFloat(cos(t * 0.31)) * 30
                    )
                Circle()
                    .fill(tint.opacity(0.10))
                    .frame(width: w * 0.8)
                    .blur(radius: 70)
                    .position(
                        x: w * 0.85 + CGFloat(cos(t * 0.19)) * 35,
                        y: h * 0.45 + CGFloat(sin(t * 0.27)) * 40
                    )
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: w * 0.7)
                    .blur(radius: 55)
                    .position(
                        x: w * 0.4 + CGFloat(sin(t * 0.17 + 2)) * 45,
                        y: h * 0.85 + CGFloat(cos(t * 0.22)) * 30
                    )
            }
            .animation(.easeInOut(duration: 0.8), value: tint)
        }
        .allowsHitTesting(false)
    }
}

// MARK: 플로팅 모디파이어 — 둥실둥실 떠 있는 느낌
struct FloatingEffect: ViewModifier {
    var amplitude: CGFloat = 7
    var speed: Double = 1.3
    var phase: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate * speed + phase
                content
                    .offset(y: CGFloat(sin(t)) * amplitude)
                    .rotationEffect(.degrees(sin(t * 0.7) * 1.2))
            }
        }
    }
}

extension View {
    func floating(amplitude: CGFloat = 7, speed: Double = 1.3, phase: Double = 0) -> some View {
        modifier(FloatingEffect(amplitude: amplitude, speed: speed, phase: phase))
    }
}

// MARK: - 스플래시 히어로 (Step 0 비주얼)
struct SplashHeroView: View {
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // 마스코트 뒤 글로우
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.tteOrange.opacity(0.22), .clear],
                            center: .center, startRadius: 10, endRadius: 150
                        )
                    )
                    .frame(width: 300, height: 300)
                    .scaleEffect(appeared ? 1 : 0.5)

                Image("tteoni-front")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .floating(amplitude: 8, speed: 1.1)
                    .scaleEffect(appeared ? 1 : 0.55)
                    .opacity(appeared ? 1 : 0)
            }

            VStack(spacing: 18) {
                Image("tteona-logo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 42)
                    .shadow(color: .tteOrange.opacity(0.25), radius: 16, y: 6)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)

                Text("특별한 순간을 영상으로 기록하세요")
                    .font(.tte(16))
                    .foregroundColor(.tteMediumGray)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
            }
            .padding(.top, 8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.68)) {
                appeared = true
            }
        }
    }
}

// MARK: - 기능 소개 쇼케이스 (Step 1 전체)
struct OnboardingFeatureShowcase: View {
    let onFinish: () -> Void

    @State private var slideIndex = 0
    @State private var dragOffset: CGSize = .zero
    @State private var goingForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        #if DEBUG
        // 시각 검증용: -previewSlide N 런치 아규먼트로 특정 슬라이드 바로 진입
        let preview = UserDefaults.standard.integer(forKey: "previewSlide")
        if preview > 0 { _slideIndex = State(initialValue: min(preview, 3)) }
        #endif
    }

    private struct HeroSlide: Identifiable {
        let id: Int
        let mascot: String
        let title: String
        let subtitle: String
        let tint: Color
        let chips: [(icon: String, angle: Double)]
    }

    private let slides: [HeroSlide] = [
        HeroSlide(
            id: 0, mascot: "tteoni-travel",
            title: "지도에서 코스 발견",
            subtitle: "전 세계 여행 코스를 지도에서 한눈에.\n마음에 드는 코스로 바로 떠나보세요",
            tint: Color(hex: "#FF6B35"),
            chips: [("map.fill", -140), ("mappin.and.ellipse", -40), ("airplane.departure", 95)]
        ),
        HeroSlide(
            id: 1, mascot: "tteoni-wink",
            title: "도착하면, 딱 5초 촬영",
            subtitle: "장소에 도착하면 나루가 알려드려요.\n5초씩만 담아도 하루가 기록돼요",
            tint: Color(hex: "#2EA8C4"),
            chips: [("bell.badge.fill", -135), ("camera.fill", -45), ("timer", 100)]
        ),
        HeroSlide(
            id: 2, mascot: "tteoni-thumbsup",
            title: "Vlog는 자동 완성",
            subtitle: "여행이 끝나면 촬영한 클립을 모아\n감성 Vlog 영상을 만들어드려요",
            tint: Color(hex: "#8B5CF6"),
            chips: [("film.stack", -140), ("wand.and.stars", -35), ("music.note", 90)]
        ),
        HeroSlide(
            id: 3, mascot: "tteoni-jump",
            title: "함께라서 더 좋아",
            subtitle: "친구·가족과 그룹을 만들어\n코스와 '나의 오늘'을 공유해보세요",
            tint: Color(hex: "#FF4F79"),
            chips: [("person.2.fill", -140), ("bubble.left.and.bubble.right.fill", -40), ("heart.fill", 95)]
        ),
    ]

    private var slide: HeroSlide { slides[slideIndex] }
    private var isLast: Bool { slideIndex == slides.count - 1 }

    // 드래그량 → 3D 틸트 각도 (클램프)
    private var tiltY: Double { max(-10, min(10, Double(dragOffset.width) / 14)) }
    private var tiltX: Double { max(-8, min(8, Double(-dragOffset.height) / 16)) }

    var body: some View {
        ZStack {
            AuroraBackground(tint: slide.tint)

            VStack(spacing: 0) {
                // 상단 로고 + 건너뛰기
                HStack {
                    Image("tteona-logo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 22)
                    Spacer()
                    Button("건너뛰기", action: onFinish)
                        .font(.tte(14))
                        .foregroundColor(.tteMediumGray)
                }
                .padding(.horizontal, 24)
                .padding(.top, 60)

                Spacer()

                // 히어로 카드 (3D 틸트 + 패럴랙스)
                heroCard
                    .id(slideIndex)
                    .transition(.asymmetric(
                        insertion: .move(edge: goingForward ? .trailing : .leading)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.92)),
                        removal: .move(edge: goingForward ? .leading : .trailing)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.92))
                    ))

                Spacer()

                // 텍스트
                VStack(spacing: 14) {
                    Text(slide.title)
                        .font(.tte(28, .bold))
                        .foregroundColor(.tteDarkGray)
                    Text(slide.subtitle)
                        .font(.tte(16))
                        .foregroundColor(.tteMediumGray)
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .id("text-\(slideIndex)")
                .transition(.opacity.combined(with: .offset(y: 12)))
                .padding(.horizontal, 32)

                Spacer()

                // 페이지 인디케이터
                HStack(spacing: 8) {
                    ForEach(0..<slides.count, id: \.self) { i in
                        Capsule()
                            .fill(i == slideIndex ? slide.tint : Color(UIColor.tertiarySystemFill))
                            .frame(width: i == slideIndex ? 24 : 8, height: 8)
                    }
                }
                .padding(.bottom, 28)

                // 다음/시작 버튼
                Button {
                    if isLast {
                        Haptics.medium()
                        onFinish()
                    } else {
                        advance(forward: true)
                    }
                } label: {
                    Text(isLast ? "시작하기" : "다음")
                        .font(.tte(17, .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(slide.tint)
                                .shadow(color: slide.tint.opacity(0.35), radius: 12, y: 6)
                        )
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: slideIndex)
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard !reduceMotion else { return }
                    dragOffset = value.translation
                }
                .onEnded { value in
                    let dx = value.translation.width
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        dragOffset = .zero
                    }
                    if dx < -60, !isLast {
                        advance(forward: true)
                    } else if dx > 60, slideIndex > 0 {
                        advance(forward: false)
                    }
                }
        )
    }

    private func advance(forward: Bool) {
        goingForward = forward
        Haptics.light()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            slideIndex += forward ? 1 : -1
        }
    }

    // MARK: 히어로 카드
    private var heroCard: some View {
        ZStack {
            // 유리 카드
            RoundedRectangle(cornerRadius: 32)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 32)
                        .fill(
                            LinearGradient(
                                colors: [slide.tint.opacity(0.10), slide.tint.opacity(0.03)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 32)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.9), slide.tint.opacity(0.25)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                )
                .shadow(color: slide.tint.opacity(0.18), radius: 24, y: 14)

            // 마스코트
            Image(slide.mascot)
                .resizable()
                .scaledToFit()
                .frame(width: 185, height: 185)
                .floating(amplitude: 7, speed: 1.25)
                .shadow(color: .black.opacity(0.10), radius: 14, y: 10)

            // 궤도 아이콘 칩 (패럴랙스: 드래그 반대 방향으로 살짝)
            ForEach(Array(slide.chips.enumerated()), id: \.offset) { i, chip in
                orbitChip(icon: chip.icon, angle: chip.angle, index: i)
            }

            // 틸트에 따라 흐르는 글레어
            RoundedRectangle(cornerRadius: 32)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.28), .clear, .clear],
                        startPoint: tiltY > 0 ? .topLeading : .topTrailing,
                        endPoint: .bottomTrailing
                    )
                )
                .allowsHitTesting(false)
        }
        .frame(width: 290, height: 300)
        .rotation3DEffect(.degrees(tiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .offset(x: dragOffset.width * 0.35, y: dragOffset.height * 0.06)
    }

    private func orbitChip(icon: String, angle: Double, index: Int) -> some View {
        let radius: CGFloat = 132
        let rad = angle * .pi / 180
        return Image(systemName: icon)
            .font(.tte(17, .semibold))
            .foregroundColor(slide.tint)
            .frame(width: 44, height: 44)
            .background(
                Circle()
                    .fill(Color.white)
                    .shadow(color: slide.tint.opacity(0.25), radius: 8, y: 4)
            )
            .floating(amplitude: 5, speed: 1.5, phase: Double(index) * 1.7)
            .offset(
                x: cos(rad) * radius - dragOffset.width * 0.12,
                y: sin(rad) * radius - dragOffset.height * 0.08
            )
    }
}

#Preview("Splash") {
    ZStack {
        Color.tteBackground.ignoresSafeArea()
        SplashHeroView()
    }
}

#Preview("Showcase") {
    OnboardingFeatureShowcase(onFinish: {})
}
