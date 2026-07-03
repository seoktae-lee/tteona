import SwiftUI
import GoogleMaps
import CoreLocation

// 지도에 찍을 마커 하나
struct GoogleMapMarker: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    var title: String? = nil
    var pinImageName: String? = nil // 태그별 핀 에셋 (예: pin_couple). 없으면 기본/번호 핀
    var label: String? = nil        // 핀 아래 항상 보이는 라벨 (코스명)
    var badgeNumber: Int? = nil     // 지정 시 번호 핀(동선용)
    var highlighted: Bool = false   // 선택 강조 (더 크게 + 헤일로)
    var icon: UIImage? = nil        // 직접 렌더한 커스텀 아이콘 (있으면 최우선)
    var iconAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5)  // icon 사용 시 앵커
    var styleKey: String? = nil     // 커스텀 아이콘 상태 식별용 (갱신 트리거)
}

// Google Maps SDK를 SwiftUI에서 쓰기 위한 재사용 래퍼.
// 홈 지도(핀·탭·내위치)부터 상세 동선(폴리라인·번호핀)까지 공용으로 사용.
struct GoogleMapView: UIViewRepresentable {
    var markers: [GoogleMapMarker] = []
    var polyline: [CLLocationCoordinate2D]? = nil
    var dashedPolyline: Bool = false
    var showsUserLocation: Bool = false
    var initialCamera: GMSCameraPosition? = nil
    var interactive: Bool = true
    /// 값이 세팅되면 그 위치로 카메라 이동 후 자동으로 nil로 리셋(유저 팬 방해 없이 프로그램 이동)
    @Binding var cameraCommand: GMSCameraPosition?
    var onMarkerTap: ((String) -> Void)? = nil
    var onCameraIdle: ((GMSCameraPosition) -> Void)? = nil

    init(markers: [GoogleMapMarker] = [],
         polyline: [CLLocationCoordinate2D]? = nil,
         dashedPolyline: Bool = false,
         showsUserLocation: Bool = false,
         initialCamera: GMSCameraPosition? = nil,
         interactive: Bool = true,
         cameraCommand: Binding<GMSCameraPosition?> = .constant(nil),
         onMarkerTap: ((String) -> Void)? = nil,
         onCameraIdle: ((GMSCameraPosition) -> Void)? = nil) {
        self.markers = markers
        self.polyline = polyline
        self.dashedPolyline = dashedPolyline
        self.showsUserLocation = showsUserLocation
        self.initialCamera = initialCamera
        self.interactive = interactive
        self._cameraCommand = cameraCommand
        self.onMarkerTap = onMarkerTap
        self.onCameraIdle = onCameraIdle
    }

    func makeUIView(context: Context) -> GMSMapView {
        let options = GMSMapViewOptions()
        options.camera = initialCamera ?? GMSCameraPosition(latitude: 37.5665, longitude: 126.9780, zoom: 12)
        options.frame = .zero
        let mapView = GMSMapView(options: options)
        mapView.delegate = context.coordinator
        mapView.isMyLocationEnabled = showsUserLocation
        mapView.settings.myLocationButton = false
        mapView.settings.compassButton = interactive
        mapView.settings.setAllGesturesEnabled(interactive)
        context.coordinator.showLabels = (initialCamera?.zoom ?? 12) >= Coordinator.labelZoomThreshold
        context.coordinator.rebuildMarkers(on: mapView, markers: markers)
        context.coordinator.rebuildPolyline(on: mapView, coords: polyline, dashed: dashedPolyline)
        return mapView
    }

    func updateUIView(_ mapView: GMSMapView, context: Context) {
        mapView.isMyLocationEnabled = showsUserLocation
        context.coordinator.rebuildMarkers(on: mapView, markers: markers)
        context.coordinator.rebuildPolyline(on: mapView, coords: polyline, dashed: dashedPolyline)

        // 프로그램적 카메라 이동 명령이 있으면 실행 후 리셋
        if let cmd = cameraCommand {
            mapView.animate(to: cmd)
            DispatchQueue.main.async { cameraCommand = nil }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // 좌표들을 모두 담는 카메라 (코스 전체 동선 보기용). 뷰 크기와 무관하게 중심+줌 계산.
    static func fittingCamera(for coords: [CLLocationCoordinate2D], padding: Double = 1.4) -> GMSCameraPosition {
        guard let minLat = coords.map(\.latitude).min(),
              let maxLat = coords.map(\.latitude).max(),
              let minLng = coords.map(\.longitude).min(),
              let maxLng = coords.map(\.longitude).max() else {
            return GMSCameraPosition(latitude: 37.5665, longitude: 126.9780, zoom: 12)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let lngSpan = max((maxLng - minLng) * padding, 0.003)
        let latSpan = max((maxLat - minLat) * padding, 0.003)
        // 가로/세로 중 더 넓은 쪽 기준으로 줌 산출
        let span = max(lngSpan, latSpan)
        let zoom = Float(max(3, min(17, log2(360.0 / span))))
        return GMSCameraPosition(latitude: center.latitude, longitude: center.longitude, zoom: zoom)
    }

    class Coordinator: NSObject, GMSMapViewDelegate {
        static let labelZoomThreshold: Float = 9.0   // 이 줌 이상일 때만 코스명 라벨 표시(낮출수록 더 일찍 뜸)

        let parent: GoogleMapView
        private var markerViews: [String: GMSMarker] = [:]
        private var lastSignature: String = ""
        private var lastMarkers: [GoogleMapMarker] = []
        var showLabels: Bool = true
        private var polylineView: GMSPolyline?
        private var lastPolylineKey: String = ""

        init(_ parent: GoogleMapView) { self.parent = parent }

        // 마커 렌더 내용(id·라벨·번호·강조·라벨표시여부)이 바뀔 때만 갱신 (깜빡임 방지)
        func rebuildMarkers(on mapView: GMSMapView, markers: [GoogleMapMarker]) {
            lastMarkers = markers
            let sig = markers.map {
                "\($0.id)|\($0.pinImageName ?? "")|\($0.label ?? "")|\($0.badgeNumber.map(String.init) ?? "")|\($0.highlighted ? 1 : 0)|\($0.styleKey ?? "")|" + String(format: "%.5f,%.5f", $0.coordinate.latitude, $0.coordinate.longitude)
            }.joined(separator: ";") + "#labels:\(showLabels ? 1 : 0)"
            guard sig != lastSignature else { return }
            markerViews.values.forEach { $0.map = nil }
            markerViews.removeAll()
            for m in markers {
                let marker = GMSMarker(position: m.coordinate)
                marker.title = m.title
                marker.userData = m.id
                if let customIcon = m.icon {
                    marker.icon = customIcon
                    marker.groundAnchor = m.iconAnchor
                } else {
                    let rendered = MarkerIcon.make(pinImageName: m.pinImageName,
                                                   label: showLabels ? m.label : nil,
                                                   badge: m.badgeNumber,
                                                   highlighted: m.highlighted)
                    marker.icon = rendered.image
                    marker.groundAnchor = rendered.anchor
                }
                marker.zIndex = m.highlighted ? 1 : 0
                marker.map = mapView
                markerViews[m.id] = marker
            }
            lastSignature = sig
        }

        func rebuildPolyline(on mapView: GMSMapView, coords: [CLLocationCoordinate2D]?, dashed: Bool) {
            let key = (coords ?? []).map { "\($0.latitude),\($0.longitude)" }.joined(separator: "|") + "|dash:\(dashed ? 1 : 0)"
            guard key != lastPolylineKey else { return }
            polylineView?.map = nil
            polylineView = nil
            lastPolylineKey = key
            guard let coords, coords.count >= 2 else { return }
            let orange = UIColor(red: 1.0, green: 0.42, blue: 0.21, alpha: 1.0) // tteOrange
            let path = GMSMutablePath()
            coords.forEach { path.add($0) }
            let line = GMSPolyline(path: path)
            line.strokeWidth = dashed ? 3 : 4
            if dashed {
                // 경로 전체 길이에 비례한 점선 (줌·코스 규모와 무관하게 일정한 점선 밀도)
                let total = GMSGeometryLength(path)
                let on = max(total / 130, 1)
                let off = on * 2.2
                line.spans = GMSStyleSpans(
                    path,
                    [GMSStrokeStyle.solidColor(orange), GMSStrokeStyle.solidColor(.clear)],
                    [NSNumber(value: on), NSNumber(value: off)],
                    .rhumb
                )
            } else {
                line.strokeColor = orange
            }
            line.map = mapView
            polylineView = line
        }

        func mapView(_ mapView: GMSMapView, didTap marker: GMSMarker) -> Bool {
            if let id = marker.userData as? String { parent.onMarkerTap?(id) }
            return true // 기본 정보창/센터링 억제
        }

        func mapView(_ mapView: GMSMapView, idleAt position: GMSCameraPosition) {
            // 줌이 임계값을 넘나들면 라벨 표시 토글 후 마커 재렌더
            let shouldShow = position.zoom >= Coordinator.labelZoomThreshold
            if shouldShow != showLabels {
                showLabels = shouldShow
                rebuildMarkers(on: mapView, markers: lastMarkers)
            }
            parent.onCameraIdle?(position)
        }
    }
}

// 마커 아이콘 합성: (태그 핀 이미지 또는 기본/번호 핀) + 코스명 라벨.
// 핀 끝(tip)이 좌표에 닿도록 groundAnchor를 함께 계산해 반환.
private enum MarkerIcon {
    static var cache: [String: (image: UIImage, anchor: CGPoint)] = [:]
    static let orange = UIColor(red: 1.0, green: 0.42, blue: 0.21, alpha: 1.0)

    static func make(pinImageName: String?, label: String?, badge: Int?, highlighted: Bool = false) -> (image: UIImage, anchor: CGPoint) {
        let key = "\(pinImageName ?? "")|\(label ?? "")|\(badge.map(String.init) ?? "")|\(highlighted ? 1 : 0)"
        if let cached = cache[key] { return cached }

        let pinImage = pinImageName.flatMap { UIImage(named: $0) }
        let basePin: CGFloat = pinImageName != nil ? 40 : (highlighted ? 52 : 38)
        let pinW: CGFloat = basePin, pinH: CGFloat = basePin
        let hasLabel = !(label ?? "").isEmpty

        // 라벨 크기 측정
        let labelFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let labelText = (label ?? "") as NSString
        var labelSize = CGSize.zero
        if hasLabel {
            let raw = labelText.size(withAttributes: [.font: labelFont])
            labelSize = CGSize(width: min(raw.width, 120) + 16, height: raw.height + 7)
        }

        let gap: CGFloat = hasLabel ? 2 : 0
        let pad: CGFloat = hasLabel ? 5 : 0   // 라벨 그림자 잘림 방지 여백
        let contentW = max(pinW, labelSize.width)
        let totalW = contentW + pad * 2
        let totalH = pinH + (hasLabel ? gap + labelSize.height + pad : 0)
        // 물방울(태그) 핀은 끝이 좌표에, 원형(번호) 핀은 중앙이 좌표에 오도록
        let isTeardrop = pinImage != nil
        let pinAnchorY = isTeardrop ? pinH : pinH / 2

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalW, height: totalH))
        let img = renderer.image { ctx in
            let pinX = (totalW - pinW) / 2
            // 핀 그리기
            if let pinImage {
                pinImage.draw(in: CGRect(x: pinX, y: 0, width: pinW, height: pinH))
            } else {
                drawDefaultPin(in: CGRect(x: pinX, y: 0, width: pinW, height: pinH), badge: badge, highlighted: highlighted, ctx: ctx)
            }
            // 코스명 라벨 (흰 캡슐 + 얇은 테두리 + 은은한 그림자 + 다크 텍스트)
            if hasLabel {
                let lx = (totalW - labelSize.width) / 2
                let lrect = CGRect(x: lx, y: pinH + gap, width: labelSize.width, height: labelSize.height)
                let capsule = UIBezierPath(roundedRect: lrect, cornerRadius: labelSize.height / 2)
                ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.5,
                                        color: UIColor.black.withAlphaComponent(0.18).cgColor)
                UIColor.white.withAlphaComponent(0.98).setFill()
                capsule.fill()
                ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
                UIColor.black.withAlphaComponent(0.06).setStroke()
                capsule.lineWidth = 0.5
                capsule.stroke()

                let para = NSMutableParagraphStyle()
                para.alignment = .center
                para.lineBreakMode = .byTruncatingTail
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: labelFont,
                    .foregroundColor: UIColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1.0),
                    .paragraphStyle: para,
                ]
                let textH = labelText.size(withAttributes: [.font: labelFont]).height
                let textRect = CGRect(x: lrect.minX + 8, y: lrect.midY - textH / 2,
                                      width: lrect.width - 16, height: textH)
                labelText.draw(in: textRect, withAttributes: attrs)
            }
        }
        let anchor = CGPoint(x: 0.5, y: pinAnchorY / totalH)
        cache[key] = (img, anchor)
        return (img, anchor)
    }

    // 번호 핀 — 기존 PlacePin처럼 깔끔한 원형(주황 원 + 흰 번호), 선택 시 크게 + 헤일로
    private static func drawDefaultPin(in rect: CGRect, badge: Int?, highlighted: Bool, ctx: UIGraphicsImageRendererContext) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let circleD: CGFloat = highlighted ? 40 : 30
        let circleRect = CGRect(x: center.x - circleD / 2, y: center.y - circleD / 2, width: circleD, height: circleD)

        // 선택 강조 헤일로 (캔버스를 꽉 채우는 반투명 원)
        if highlighted {
            orange.withAlphaComponent(0.22).setFill()
            UIBezierPath(ovalIn: rect).fill()
        }
        // 주황 원 + 은은한 그림자
        ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                                color: UIColor.black.withAlphaComponent(0.25).cgColor)
        orange.setFill()
        UIBezierPath(ovalIn: circleRect).fill()
        ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

        // 흰 번호 (중앙)
        if let badge {
            let text = "\(badge)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: highlighted ? 16 : 13, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let ts = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: circleRect.midX - ts.width / 2, y: circleRect.midY - ts.height / 2), withAttributes: attrs)
        }
    }
}
