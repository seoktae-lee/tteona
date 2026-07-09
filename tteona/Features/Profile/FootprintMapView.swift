import SwiftUI
import CoreLocation

// MARK: - 발자취 지도 초기 포커스
enum FootprintMapFocus: Equatable {
    case world
    case korea
    case country(String)          // ISO3 코드
    case point(lat: Double, lng: Double)
}

// MARK: - 발자취 지도
/// 빈 도화지 스타일의 세계지도 위에 방문 지역(한국 시군구·세계 국가)을 색칠하고
/// 여행 경로를 점선으로 얹는 커스텀 렌더러. 팬·핀치·탭 지원.
struct FootprintMapView: View {
    let summary: FootprintSummary
    var routes: [[FootprintPoint]] = []
    var highlightCodes: Set<String> = []     // 새로 칠해진 지역 — 펄스 연출
    var interactive: Bool = true             // 탭으로 지역 정보 표시
    // 임베드(스크롤 안) 지도는 팬/핀치를 끈다 — 세로 드래그가 페이지 스크롤로 넘어가도록.
    var panZoom: Bool = true
    var initialFocus: FootprintMapFocus = .korea
    /// 부모가 값을 바꾸면 해당 위치로 카메라가 날아간다 ("지금 여기 있네요" 연출 등)
    var focusCommand: FootprintMapFocus? = nil

    // 카메라 — center는 단위공간(0~1), zoom은 "세계 너비가 뷰 너비의 몇 배인가"
    @State private var center = CGPoint(x: 0.8549, y: 0.3929)
    @State private var zoom: CGFloat = 40
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    @State private var atlasReady = false
    @State private var flyTask: Task<Void, Never>? = nil
    @State private var tappedRegion: GeoRegion? = nil
    @State private var tappedVisited = false
    @State private var didSetInitialFocus = false

    // 종이 지도 팔레트 (라이트 고정 — 프로필 카드 안에서 항상 밝은 도화지 느낌)
    private let paperColor    = Color(hex: "#FBF8F3")
    private let landColor     = Color(hex: "#EFEAE1")
    private let borderColor   = Color(hex: "#D9D2C4")
    private let visitedColor  = Color.tteOrange
    private let visitedSoft   = Color(hex: "#FF8B5E")

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                paperColor

                if atlasReady {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: highlightCodes.isEmpty)) { timeline in
                        canvas(size: size, now: timeline.date)
                    }
                } else {
                    ProgressView().tint(.tteOrange)
                }

                if let region = tappedRegion {
                    regionChip(region)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 12)
                }
            }
            .contentShape(Rectangle())
            .clipped()
            .gesture(panZoom ? mapGestures(size: size) : nil)
            .onTapGesture(coordinateSpace: .local) { location in
                guard interactive, atlasReady else { return }
                handleTap(at: location, size: size)
            }
            .task {
                // GeoJSON 파싱은 백그라운드에서 1회
                await Task.detached(priority: .userInitiated) {
                    FootprintAtlas.shared.ensureLoaded()
                }.value
                atlasReady = true
                if !didSetInitialFocus {
                    didSetInitialFocus = true
                    applyFocus(initialFocus, size: size, animated: false)
                }
            }
            .onChange(of: focusCommand) { _, command in
                guard let command, atlasReady else { return }
                applyFocus(command, size: size, animated: true)
            }
            .onDisappear { flyTask?.cancel() }
        }
    }

    // MARK: - Canvas 렌더링

    private func canvas(size: CGSize, now: Date) -> some View {
        // 펄스 위상 — 새로 칠해진 지역이 은은하게 숨쉬는 연출
        let pulse = 0.55 + 0.45 * (0.5 + 0.5 * sin(now.timeIntervalSinceReferenceDate * 3.2))

        return Canvas { ctx, canvasSize in
            let scale = canvasSize.width * effectiveZoom
            let c = effectiveCenter(size: canvasSize)
            ctx.translateBy(x: canvasSize.width / 2 - c.x * scale,
                            y: canvasSize.height / 2 - c.y * scale)
            ctx.scaleBy(x: scale, y: scale)

            let hairline = max(0.6 / scale, 0.0000015)
            let atlas = FootprintAtlas.shared

            // 화면에 보이는 단위공간 범위 (컬링)
            let visible = CGRect(
                x: c.x - canvasSize.width / 2 / scale,
                y: c.y - canvasSize.height / 2 / scale,
                width: canvasSize.width / scale,
                height: canvasSize.height / scale
            ).insetBy(dx: -0.002, dy: -0.002)

            // 1) 세계 국가 (한국 본토는 시군구 레이어가 덮는다)
            for region in atlas.worldRegions where region.bbox.intersects(visible) {
                let path = Path(region.path)
                let visited = summary.countryCodes.contains(region.code)
                let highlighted = highlightCodes.contains(region.code)
                if region.code == "KOR" {
                    // 한국은 시군구가 본체 — 국가 폴리곤은 바탕색만 깔고 외곽선도 중립색 유지
                    // (국가 경계 stroke가 시군구 지도 위에 겹쳐 그려지는 잡선 방지)
                    ctx.fill(path, with: .color(landColor), style: FillStyle(eoFill: true))
                    ctx.stroke(path, with: .color(borderColor), lineWidth: hairline)
                } else if highlighted {
                    ctx.fill(path, with: .color(visitedSoft.opacity(pulse)), style: FillStyle(eoFill: true))
                    ctx.stroke(path, with: .color(visitedColor), lineWidth: hairline)
                } else if visited {
                    ctx.fill(path, with: .color(visitedColor.opacity(0.88)), style: FillStyle(eoFill: true))
                    ctx.stroke(path, with: .color(visitedColor), lineWidth: hairline)
                } else {
                    ctx.fill(path, with: .color(landColor), style: FillStyle(eoFill: true))
                    ctx.stroke(path, with: .color(borderColor), lineWidth: hairline)
                }
            }

            // 2) 한국 시군구 (충분히 확대됐거나 한국이 화면에 있을 때만)
            let koreaBBox = CGRect(x: 0.843, y: 0.373, width: 0.026, height: 0.026)
            if koreaBBox.intersects(visible) {
                for region in atlas.koreaRegions where region.bbox.intersects(visible) {
                    let path = Path(region.path)
                    let visited = summary.sigCodes.contains(region.code)
                    let highlighted = highlightCodes.contains(region.code)
                    if highlighted {
                        ctx.fill(path, with: .color(visitedSoft.opacity(pulse)), style: FillStyle(eoFill: true))
                    } else if visited {
                        ctx.fill(path, with: .color(visitedColor.opacity(0.88)), style: FillStyle(eoFill: true))
                    } else {
                        ctx.fill(path, with: .color(paperColor), style: FillStyle(eoFill: true))
                    }
                    ctx.stroke(path, with: .color(visited ? Color.white.opacity(0.7) : borderColor),
                               lineWidth: hairline)
                }
            }

            // 3) 여행 경로 (점선 + 장소 점)
            if !routes.isEmpty, effectiveZoom > 8 {
                let routeWidth = max(1.6 / scale, hairline)
                for route in routes where route.count >= 1 {
                    let pts = route.map { FootprintAtlas.project(lat: $0.lat, lng: $0.lng) }
                    if pts.count >= 2 {
                        var line = Path()
                        line.move(to: pts[0])
                        for pt in pts.dropFirst() { line.addLine(to: pt) }
                        ctx.stroke(line, with: .color(visitedColor.opacity(0.55)),
                                   style: StrokeStyle(lineWidth: routeWidth, lineCap: .round,
                                                      lineJoin: .round,
                                                      dash: [routeWidth * 2.2, routeWidth * 2.2]))
                    }
                    // 장소 점
                    let r = routeWidth * 1.4
                    for pt in pts {
                        let dot = Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r,
                                                         width: r * 2, height: r * 2))
                        ctx.fill(dot, with: .color(.white))
                        ctx.stroke(dot, with: .color(visitedColor), lineWidth: routeWidth * 0.7)
                    }
                }
            }
        }
    }

    // MARK: - 카메라

    private var effectiveZoom: CGFloat {
        min(max(zoom * pinch, 0.8), 900)
    }

    private func effectiveCenter(size: CGSize) -> CGPoint {
        let scale = size.width * effectiveZoom
        var c = CGPoint(x: center.x - drag.width / scale,
                        y: center.y - drag.height / scale)
        c.x = min(max(c.x, 0), 1)
        c.y = min(max(c.y, 0.04), 0.96)
        return c
    }

    private func mapGestures(size: CGSize) -> some Gesture {
        let dragGesture = DragGesture(minimumDistance: 2)
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                let scale = size.width * effectiveZoom
                center.x = min(max(center.x - value.translation.width / scale, 0), 1)
                center.y = min(max(center.y - value.translation.height / scale, 0.04), 0.96)
                flyTask?.cancel()
            }
        let pinchGesture = MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in
                zoom = min(max(zoom * value, 0.8), 900)
                flyTask?.cancel()
            }
        return dragGesture.simultaneously(with: pinchGesture)
    }

    /// 지정 위치·줌으로 부드럽게 카메라 이동 (ease-in-out)
    func fly(to target: CGPoint, zoom targetZoom: CGFloat, duration: Double = 0.9) {
        flyTask?.cancel()
        let startCenter = center
        let startZoom = zoom
        flyTask = Task { @MainActor in
            let frames = max(Int(duration * 60), 1)
            for frame in 1...frames {
                guard !Task.isCancelled else { return }
                let t = Double(frame) / Double(frames)
                let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2   // easeInOutQuad
                center = CGPoint(x: startCenter.x + (target.x - startCenter.x) * e,
                                 y: startCenter.y + (target.y - startCenter.y) * e)
                // 줌은 로그 공간에서 보간해야 자연스럽다
                zoom = exp(log(startZoom) + (log(targetZoom) - log(startZoom)) * e)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    func applyFocus(_ focus: FootprintMapFocus, size: CGSize, animated: Bool) {
        let (target, targetZoom) = Self.camera(for: focus)
        if animated {
            fly(to: target, zoom: targetZoom)
        } else {
            center = target
            zoom = targetZoom
        }
    }

    /// 포커스 → 카메라 (중심·줌) 계산
    static func camera(for focus: FootprintMapFocus) -> (CGPoint, CGFloat) {
        switch focus {
        case .world:
            return (CGPoint(x: 0.5, y: 0.42), 1.35)
        case .korea:
            // 시군구 데이터 실측 bbox: x 0.8461~0.8637, y 0.3836~0.4023 (center 0.8549, 0.3929)
            return (CGPoint(x: 0.8549, y: 0.3929), 40)
        case .country(let code):
            if code == "KOR" { return Self.camera(for: .korea) }
            guard let region = FootprintAtlas.shared.worldRegion(code: code) else {
                return Self.camera(for: .world)
            }
            let bbox = region.bbox
            let span = max(bbox.width, bbox.height * 1.4)
            let z = min(max(0.75 / max(span, 0.001), 1.2), 60)
            return (region.center, z)
        case .point(let lat, let lng):
            return (FootprintAtlas.project(lat: lat, lng: lng), 90)
        }
    }

    // MARK: - 탭 → 지역 칩

    private func handleTap(at location: CGPoint, size: CGSize) {
        let scale = size.width * effectiveZoom
        let c = effectiveCenter(size: size)
        let unit = CGPoint(x: c.x + (location.x - size.width / 2) / scale,
                           y: c.y + (location.y - size.height / 2) / scale)
        // 단위공간 → 위경도 역변환
        let lng = Double(unit.x) * 360 - 180
        let lat = atan(sinh(.pi * (1 - 2 * Double(unit.y)))) * 180 / .pi

        let resolved = FootprintAtlas.shared.resolve(lat: lat, lng: lng)
        let region = resolved.sig ?? resolved.country
        guard let region else {
            withAnimation(.easeOut(duration: 0.2)) { tappedRegion = nil }
            return
        }
        let visited = summary.sigCodes.contains(region.code) || summary.countryCodes.contains(region.code)
        withAnimation(.spring(duration: 0.35)) {
            tappedRegion = region
            tappedVisited = visited
        }
        Haptics.light()
        // 3초 뒤 자동 숨김
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if tappedRegion?.code == region.code {
                withAnimation(.easeOut(duration: 0.3)) { tappedRegion = nil }
            }
        }
    }

    private func regionChip(_ region: GeoRegion) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tappedVisited ? Color.tteOrange : Color(hex: "#C9C2B4"))
                .frame(width: 8, height: 8)
            Text(displayName(region))
                .font(.tte(13, .semibold))
                .foregroundColor(.tteDarkGray)
            Text(tappedVisited ? L("footprint.visited") : L("footprint.notYet"))
                .font(.tte(12))
                .foregroundColor(tappedVisited ? .tteOrange : .tteMediumGray)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(
            Capsule()
                .fill(.white)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        )
    }

    private func displayName(_ region: GeoRegion) -> String {
        // 한국어가 아니면 영문 이름 우선 (국가는 name이 이미 영문)
        if LanguageManager.shared.language != .korean, let eng = region.nameEng {
            return eng
        }
        return region.name
    }
}
