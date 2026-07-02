import SwiftUI

/// 커스텀 썸네일이 없는 코스에 쓰이는 떠나 기본 썸네일.
/// 전부 SwiftUI 네이티브: 틸 그라데이션 + 지도 등고선 + 오렌지 굽은 길
/// (TRAVEL/MOVE/EXPLORE) + 나루 캐릭터. 저작권 이슈 없고 어떤 크기에도 선명.
struct DefaultCourseThumbnail: View {
    /// 그리드 셀처럼 작은 영역이면 true (텍스트/장식 간소화)
    var compact: Bool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // 틸 그라데이션 배경
                LinearGradient(
                    colors: [
                        Color(hex: "#1E3A40"),
                        Color(hex: "#2C5A61"),
                        Color(hex: "#3A7B7E"),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // 지도 등고선 패턴 (은은하게)
                ContourLines()
                    .stroke(Color.white.opacity(0.07),
                            style: StrokeStyle(lineWidth: 1.5))

                // 오렌지 굽은 길
                WindingRoad()
                    .stroke(Color.tteOrange,
                            style: StrokeStyle(lineWidth: compact ? 6 : 12, lineCap: .round))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 2)

                // 타이포그래피
                roadLabels(w: w, h: h)

                // 나루 캐릭터 (우하단)
                Image("tteoni-wink")
                    .resizable()
                    .scaledToFit()
                    .frame(width: compact ? w * 0.30 : w * 0.24)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .position(x: w * 0.80, y: h * 0.83)
            }
            .frame(width: w, height: h)
        }
    }

    @ViewBuilder
    private func roadLabels(w: CGFloat, h: CGFloat) -> some View {
        let base = min(w, h)
        if compact {
            Text("TRAVEL")
                .font(.system(size: base * 0.12, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .rotationEffect(.degrees(-14))
                .position(x: w * 0.34, y: h * 0.24)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        } else {
            Group {
                label("TRAVEL", size: base * 0.10, angle: -16)
                    .position(x: w * 0.32, y: h * 0.20)
                label("MOVE", size: base * 0.10, angle: 12)
                    .position(x: w * 0.28, y: h * 0.72)
                label("EXPLORE", size: base * 0.10, angle: -14)
                    .position(x: w * 0.70, y: h * 0.50)
            }
        }
    }

    private func label(_ text: String, size: CGFloat, angle: Double) -> some View {
        Text(text)
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .foregroundColor(.white)
            .rotationEffect(.degrees(angle))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}

/// 좌상단에서 우하단으로 흐르는 S자 길
private struct WindingRoad: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.15, y: h * 0.05))
        p.addCurve(to: CGPoint(x: w * 0.30, y: h * 0.45),
                   control1: CGPoint(x: w * 0.55, y: h * 0.12),
                   control2: CGPoint(x: w * 0.05, y: h * 0.28))
        p.addCurve(to: CGPoint(x: w * 0.75, y: h * 0.70),
                   control1: CGPoint(x: w * 0.52, y: h * 0.60),
                   control2: CGPoint(x: w * 0.80, y: h * 0.48))
        p.addCurve(to: CGPoint(x: w * 0.60, y: h * 1.02),
                   control1: CGPoint(x: w * 0.72, y: h * 0.88),
                   control2: CGPoint(x: w * 0.48, y: h * 0.92))
        return p
    }
}

/// 지도 등고선 느낌의 겹친 곡선들
private struct ContourLines: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()
        // 우상단을 감싸는 동심 곡선 3개
        for i in 0..<3 {
            let inset = CGFloat(i) * w * 0.14
            var c = Path()
            c.move(to: CGPoint(x: w * 0.45 + inset, y: -h * 0.05))
            c.addQuadCurve(
                to: CGPoint(x: w * 1.05, y: h * 0.42 + inset * 0.6),
                control: CGPoint(x: w * 0.95, y: -h * 0.02)
            )
            p.addPath(c)
        }
        // 좌하단을 감싸는 동심 곡선 2개
        for i in 0..<2 {
            let inset = CGFloat(i) * w * 0.16
            var c = Path()
            c.move(to: CGPoint(x: -w * 0.05, y: h * 0.70 - inset * 0.5))
            c.addQuadCurve(
                to: CGPoint(x: w * 0.42 - inset, y: h * 1.08),
                control: CGPoint(x: w * 0.02, y: h * 1.02)
            )
            p.addPath(c)
        }
        return p
    }
}

#Preview {
    HStack {
        DefaultCourseThumbnail(compact: true).frame(width: 124, height: 124)
        DefaultCourseThumbnail().frame(width: 200, height: 260)
    }
}
