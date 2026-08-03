import SwiftUI

/// 한 지점에서 바깥으로 터지는 축하 파티클.
///
/// 이미지·라이브러리 없이 도형만 쓴다 — 몇 초 스치는 연출에 에셋을 늘릴 이유가 없다.
/// 조각마다 각도·속도·회전·색을 흩어 두고 **한 번의 애니메이션**으로 날린다.
/// (조각마다 애니메이션을 따로 걸면 조각 수만큼 타이머가 돌아 타이핑이 끊긴다)
struct ConfettiBurst: View {
    private let pieces: [Piece]
    private let duration: Double

    @State private var fired = false

    /// 조각 값은 **init에서 한 번만** 만든다.
    /// 계산 프로퍼티로 두면 화면이 갱신될 때마다 난수가 새로 생겨 조각의 정체성이 바뀌고,
    /// SwiftUI가 뷰를 통째로 갈아끼워 애니메이션이 아예 일어나지 않는다.
    init(baseAngle: Double = 0, spread: Double = 70, pieceCount: Int = 14,
         distance: Double = 110, duration: Double = 1.1) {
        self.duration = duration
        let palette: [Color] = [
            .tteOrange,
            Color(red: 1.00, green: 0.78, blue: 0.35),
            Color(red: 1.00, green: 0.55, blue: 0.55),
            Color(red: 0.42, green: 0.80, blue: 0.95),
            Color(red: 0.65, green: 0.85, blue: 0.55),
        ]
        self.pieces = (0..<pieceCount).map { i in
            let t = Double(i) / Double(max(1, pieceCount - 1))
            // 부채꼴로 고르게 펼치되 약간씩 흔들어 기계적으로 보이지 않게 한다
            let angle = baseAngle - spread / 2 + spread * t + Double.random(in: -8...8)
            return Piece(
                angle: angle,
                travel: distance * Double.random(in: 0.6...1.2),
                size: CGSize(width: Double.random(in: 5...8), height: Double.random(in: 8...14)),
                spin: Double.random(in: -340...340),
                color: palette[i % palette.count],
                delay: Double.random(in: 0...0.08)
            )
        }
    }

    private struct Piece: Identifiable {
        let id = UUID()
        let angle: Double
        let travel: Double
        let size: CGSize
        let spin: Double
        let color: Color
        let delay: Double
    }

    var body: some View {
        ZStack {
            ForEach(pieces) { piece in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(piece.color)
                    .frame(width: piece.size.width, height: piece.size.height)
                    .rotationEffect(.degrees(fired ? piece.spin : 0))
                    .offset(
                        x: fired ? cos(piece.angle * .pi / 180) * piece.travel : 0,
                        y: fired ? sin(piece.angle * .pi / 180) * piece.travel * 0.8 : 0
                    )
                    .opacity(fired ? 0 : 1)
                    .animation(.easeOut(duration: duration).delay(piece.delay), value: fired)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            // 다음 런루프에 켜야 '꺼진 상태 → 켜진 상태' 변화로 잡혀 애니메이션이 걸린다.
            // 그리기와 같은 프레임에 바꾸면 처음부터 끝난 상태로 그려져 아무것도 안 보인다.
            DispatchQueue.main.async { fired = true }
        }
    }
}

/// 글자가 하나씩 찍히고 커서가 깜빡이는 텍스트.
///
/// 자리를 미리 잡아 두고 그 위에 덧그린다 — 글자가 늘 때마다 레이아웃이 밀리면
/// 아래 내용이 함께 출렁여 오히려 산만해진다.
struct TypewriterText: View {
    let text: String
    var font: Font
    var color: Color
    /// 글자당 간격(초)
    var speed: Double = 0.09
    /// 다 찍히면 알려준다 — 축하 연출을 이 시점에 맞추기 위해
    var onFinished: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0
    @State private var caretOn = true
    @State private var typing = true

    /// 커서 자리를 항상 차지해 둔다 — 깜빡일 때마다 글자가 좌우로 흔들리지 않게
    private var caret: String { (typing && caretOn) ? "|" : " " }

    private var displayed: String {
        String(text.prefix(shown)) + (typing ? caret : "")
    }

    var body: some View {
        // 전체 문구 + 커서 한 칸으로 자리를 잡는다
        Text(text + " ")
            .font(font)
            .multilineTextAlignment(.center)
            .opacity(0)
            .overlay(
                Text(displayed)
                    .font(font)
                    .foregroundColor(color)
                    .multilineTextAlignment(.center)
            )
            .task {
                // 모션 최소화를 켠 사용자에게는 타이핑을 하지 않는다
                guard !reduceMotion else {
                    shown = text.count
                    typing = false
                    onFinished?()
                    return
                }
                // 커서 깜빡임 — 타이핑이 끝나면 스스로 멈춘다
                Task {
                    while typing {
                        try? await Task.sleep(for: .seconds(0.45))
                        caretOn.toggle()
                    }
                }
                try? await Task.sleep(for: .seconds(0.25))   // 커서만 한 번 깜빡이고 시작
                for i in 1...max(1, text.count) {
                    shown = i
                    try? await Task.sleep(for: .seconds(speed))
                }
                try? await Task.sleep(for: .seconds(0.2))    // 마지막 글자를 잠깐 머금는다
                typing = false
                onFinished?()
            }
    }
}
