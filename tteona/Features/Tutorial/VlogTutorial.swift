import SwiftUI
import Combine

// MARK: - 첫 브이로그 튜토리얼
// 회원가입·온보딩·내비 가이드가 끝난 새 유저가 앱의 하이라이트인 브이로그 제작을
// '나의 오늘' → 촬영(5초) → 오늘 종료 → 브이로그 생성까지 실제 버튼을 직접 누르며
// 한 번 완주하도록 안내한다.
//
// 원칙:
// - 오버레이는 시각 안내(말풍선·글로우)만 담당하고 터치를 가로채지 않는다.
//   진행은 실제 사용자 행동(세션 시작, 클립 저장, 시트 열림 등)으로 감지한다.
// - 어느 단계에서든 말풍선의 X로 영구 종료할 수 있다.
// - 중도 이탈(세션 나가기 등) 시 해당 지점에 맞는 단계로 되돌린다.
@MainActor
final class VlogTutorial: ObservableObject {
    static let shared = VlogTutorial()

    enum Step: Int, Comparable {
        case tapMyToday      // 메인: '나의 오늘' 누르기
        case captureHere     // 세션: '여기서 촬영' (5초 클립)
        case endToday        // 칩 1개 확인 → '오늘 종료'
        case chooseVlogOnly  // 종료 시트: '브이로그만 생성하기'
        case chooseFormat    // 포맷 선택
        case chooseBgm       // BGM 선택
        case celebrate       // 완성 축하 + 무료 6곳 안내

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    @Published private(set) var step: Step? = nil

    private var uid: String?
    private var doneKey: String? { uid.map { "vlogTutorialDone_\($0)" } }

    private init() {}

    var isActive: Bool { step != nil }
    func isOn(_ s: Step) -> Bool { step == s }

    /// 내비 가이드 종료 후 호출 — 계정별 1회만 시작한다.
    /// 플래그는 노출 즉시 저장 — 무시하고 지나친 유저에게 매 실행마다 다시 뜨지 않게
    /// "누구나 정확히 한 번"을 보장한다. (이번 세션 안에서는 완주/X까지 계속 안내)
    func beginIfNeeded(uid: String) {
        self.uid = uid
        guard !UserDefaults.standard.bool(forKey: "vlogTutorialDone_\(uid)"),
              step == nil else { return }
        UserDefaults.standard.set(true, forKey: "vlogTutorialDone_\(uid)")
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            step = .tapMyToday
        }
    }

    /// 앞 단계로만 진행 — 뒤로 가는 신호(중복 onAppear 등)는 무시한다.
    func advance(to next: Step) {
        guard let current = step, next > current else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { step = next }
    }

    /// 흐름 중간에서 빠져나갈 때 해당 지점의 단계로 되돌린다.
    func regress(to target: Step) {
        guard let current = step, current > target else { return }
        withAnimation(.easeOut(duration: 0.25)) { step = target }
    }

    /// 세션 화면을 브이로그 완성 전에 나감 → 처음부터 다시 안내
    func handleSessionExit() { regress(to: .tapMyToday) }

    /// 브이로그 생성 화면을 닫음 → 칩은 남아 있으므로 '오늘 종료' 단계로
    func handleVlogExit() { regress(to: .endToday) }

    /// 완주 또는 '그만 보기' — 다시 표시하지 않는다.
    func finish() {
        if let key = doneKey { UserDefaults.standard.set(true, forKey: key) }
        withAnimation(.easeOut(duration: 0.25)) { step = nil }
    }
}

// MARK: - 나루 말풍선
// 대상 버튼 바로 위에 놓는 컴팩트 안내 — 나루 + 한 줄 메시지 + 영구 종료 X.
// 터치는 X 버튼만 받고 나머지는 아래로 통과시켜 기존 조작을 방해하지 않는다.
struct TutorialBubble: View {
    var mascot: String = "tteoni-guide"
    let text: String
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(mascot)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .floating(amplitude: 4, speed: 1.4)
                Text(text)
                    .font(.tte(14, .semibold))
                    .foregroundColor(.tteDarkGray)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.tteBackground)
                    .shadow(color: .tteOrange.opacity(0.35), radius: 14, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.tteOrange.opacity(0.35), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    Haptics.light()
                    onSkip()
                } label: {
                    Image(systemName: "xmark")
                        .font(.tte(9, .bold))
                        .foregroundColor(.tteMediumGray)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color(UIColor.secondarySystemBackground)))
                        .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 0.5))
                }
                .offset(x: 7, y: -7)
                .accessibilityLabel(L("tutorial.skip"))
            }

            Triangle()
                .fill(Color.tteBackground)
                .frame(width: 18, height: 9)
                .rotationEffect(.degrees(180))
                .padding(.top, -1)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.94)))
    }
}

// MARK: - 대상 버튼 글로우
// 눌러야 할 버튼 주위에 숨쉬는 주황 링 — 버튼 형태에 맞춰 cornerRadius를 받는다.
private struct TutorialGlow: ViewModifier {
    let cornerRadius: CGFloat
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(pulse ? 0.95 : 0.35), lineWidth: 2.5)
                    .scaleEffect(pulse ? 1.05 : 1.0)
                    .allowsHitTesting(false)
            )
            .shadow(color: .tteOrange.opacity(pulse ? 0.75 : 0.3), radius: pulse ? 16 : 7)
            .onAppear {
                pulse = false
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

extension View {
    /// active일 때만 글로우 — 평상시엔 뷰 트리에 아무 영향 없음
    @ViewBuilder
    func tutorialGlow(_ active: Bool, cornerRadius: CGFloat) -> some View {
        if active {
            modifier(TutorialGlow(cornerRadius: cornerRadius))
        } else {
            self
        }
    }
}

// MARK: - 반짝임 오버레이 ('나의 오늘' CTA용)
struct TutorialSparkles: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            sparkle(size: 14, x: -66, y: -26, delay: 0)
            sparkle(size: 9,  x: 64,  y: -32, delay: 0.45)
            sparkle(size: 11, x: 78,  y: 12,  delay: 0.9)
        }
        .allowsHitTesting(false)
        .onAppear { animate = true }
    }

    private func sparkle(size: CGFloat, x: CGFloat, y: CGFloat, delay: Double) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .bold))
            .foregroundColor(.white)
            .shadow(color: .tteOrange, radius: 5)
            .scaleEffect(animate ? 1.15 : 0.4)
            .opacity(animate ? 1 : 0.2)
            .offset(x: x, y: y)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true).delay(delay),
                value: animate
            )
    }
}

// MARK: - 완성 축하 카드 (튜토리얼 마지막 단계)
// 첫 브이로그 프리뷰 위에 한 번만 뜬다 — 무료 한도(장소 6곳×5초)를 알려주고 마무리.
struct TutorialCelebrateOverlay: View {
    let onFinish: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 16) {
                Image("tteoni-thumbsup")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 130, height: 130)
                    .floating(amplitude: 6, speed: 1.3)

                VStack(spacing: 8) {
                    Text(L("tutorial.done.title"))
                        .font(.tte(21, .bold))
                        .foregroundColor(.tteDarkGray)
                    Text(L("tutorial.done.message"))
                        .font(.tte(14.5))
                        .foregroundColor(.tteMediumGray)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Haptics.success()
                    onFinish()
                } label: {
                    Text(L("tutorial.done.button"))
                        .font(.tte(15, .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.tteOrange))
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.tteBackground)
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
            )
            .padding(.horizontal, 36)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}
