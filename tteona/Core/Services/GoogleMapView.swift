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
    var symbolName: String? = nil   // 번호 대신 넣을 SF Symbol (예: 검색 핀의 mappin)
    var highlighted: Bool = false   // 선택 강조 (더 크게 + 헤일로)
    var icon: UIImage? = nil        // 직접 렌더한 커스텀 아이콘 (있으면 최우선)
    var iconAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5)  // icon 사용 시 앵커
    var styleKey: String? = nil     // 커스텀 아이콘 상태 식별용 (갱신 트리거)
    var curated: Bool = false       // 공식 큐레이션 코스 — 라벨에 주황 테두리를 둘러 유저 코스와 구분
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
    /// 핀이 많을 때 솎아낼지. 코스가 많은 홈 지도만 켠다(상세 동선 번호핀은 다 보여야 한다)
    var thinsMarkers: Bool = false
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
         thinsMarkers: Bool = false,
         cameraCommand: Binding<GMSCameraPosition?> = .constant(nil),
         onMarkerTap: ((String) -> Void)? = nil,
         onCameraIdle: ((GMSCameraPosition) -> Void)? = nil) {
        self.markers = markers
        self.polyline = polyline
        self.dashedPolyline = dashedPolyline
        self.showsUserLocation = showsUserLocation
        self.initialCamera = initialCamera
        self.interactive = interactive
        self.thinsMarkers = thinsMarkers
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
        context.coordinator.thinsMarkers = thinsMarkers
        context.coordinator.showLabels = (initialCamera?.zoom ?? 12) >= Coordinator.labelZoomThreshold
        context.coordinator.rebuildMarkers(on: mapView, markers: markers)
        context.coordinator.rebuildPolyline(on: mapView, coords: polyline, dashed: dashedPolyline)
        return mapView
    }

    func updateUIView(_ mapView: GMSMapView, context: Context) {
        // 콜백만 최신으로 — 이걸 빠뜨리면 탭 콜백이 첫 렌더에 묶인다
        context.coordinator.onMarkerTap = onMarkerTap
        context.coordinator.onCameraIdle = onCameraIdle
        context.coordinator.thinsMarkers = thinsMarkers
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
        /// 화면에 보이는 코스가 이 수를 넘으면 라벨을 접고 핀만 남긴다.
        /// **줌만으로는 부족하다** — 같은 줌이라도 서울 도심은 핀이 몰리고 지방은 흩어져서,
        /// 줌 임계 하나로는 한쪽이 반드시 깨진다. 큐레이션 코스를 넣으며 실제로 겪었다:
        /// 수도권이 라벨로 완전히 덮여 지도가 보이지 않았다.
        static let labelDensityLimit: Int = 20
        /// 이 줌 이상이면 밀도와 무관하게 라벨을 보여준다(동네 단위로 당겨본 상태)
        static let labelAlwaysZoom: Float = 14.0
        /// 이 줌보다 멀리 보면 핀을 아예 그리지 않는다.
        /// 광역 화면에서 전국의 코스를 뿌려봐야 서로 겹쳐 읽히지 않고, 그 상태의 핀은
        /// 누를 대상도 되지 못한다. 네이버·카카오 지도가 그렇듯 확대를 유도한다.
        static let pinMinZoom: Float = 9.5
        /// 한 화면에 그릴 핀의 최대 개수. 넘으면 화면 중심에 가까운 것만 남긴다.
        /// (에어비앤비가 화면에 20개 남짓만 띄우는 것과 같은 방식)
        ///
        /// **라벨 밀도 한계와 같은 값으로 맞춘다.** 핀만 잔뜩 있고 이름이 안 보이면
        /// 무엇을 누를지 고를 수 없어 아무 소용이 없다. 상한 안에서는 항상 이름이 보이게 한다.
        static let maxVisiblePins: Int = 20

        // 부모 구조체를 통째로 붙잡지 않고 **콜백만** 보관한다.
        //
        // makeCoordinator는 한 번만 불리므로, 여기에 처음 값을 잡아 두면 마커 탭 콜백이
        // 첫 렌더에 묶인다. MainView는 구조체라 클로저가 당시 상태를 스냅샷하므로,
        // 지도가 만들어질 때 코스가 비어 있었다면 이후 핀이 그려져도 탭은 빈 목록을 뒤진다
        // — 핀은 보이는데 눌리지 않고, 탭을 오가 뷰를 새로 만들어야 고쳐진다.
        //
        // 그렇다고 parent 구조체 자체를 갱신하면 그 안의 @Binding까지 매 갱신마다 붙잡게 되어
        // 갱신 그래프에 되먹임이 생긴다(updateUIView가 끝없이 반복돼 화면이 멎었다).
        // 필요한 건 콜백뿐이므로 그것만 갈아끼운다.
        var onMarkerTap: ((String) -> Void)?
        var onCameraIdle: ((GMSCameraPosition) -> Void)?
        private var markerViews: [String: GMSMarker] = [:]
        /// 마커별 현재 아이콘의 렌더 키 — 바뀔 때만 아이콘을 다시 그린다
        private var markerKeys: [String: String] = [:]
        /// 부모가 준 솎아내기 설정. 갱신 때마다 최신값을 받는다.
        var thinsMarkers: Bool = false
        private var lastSignature: String = ""
        private var lastMarkers: [GoogleMapMarker] = []
        var showLabels: Bool = true
        private var polylineView: GMSPolyline?
        private var lastPolylineKey: String = ""

        init(_ parent: GoogleMapView) {
            self.onMarkerTap = parent.onMarkerTap
            self.onCameraIdle = parent.onCameraIdle
        }

        /// 줌 + 화면 내 마커 밀도로 라벨 표시 여부를 정한다. (그리기는 하지 않는다)
        /// 카메라가 멈출 때만이 아니라 **마커 목록이 바뀔 때도** 다시 재야 한다 —
        /// 코스가 처음 로드되는 순간에는 카메라가 움직이지 않으므로 idleAt이 안 불린다.
        @discardableResult
        func updateLabelVisibility(on mapView: GMSMapView, shown: [GoogleMapMarker]? = nil) -> Bool {
            let zoom = mapView.camera.zoom
            let bounds = GMSCoordinateBounds(region: mapView.projection.visibleRegion())
            // 밀도는 **실제로 그려질 마커** 기준이어야 한다. 클러스터로 묶인 뒤에는 핀이
            // 훨씬 적으므로, 원본 목록으로 재면 라벨이 필요 이상으로 억제된다.
            let visible = (shown ?? lastMarkers).reduce(into: 0) { count, m in
                if bounds.contains(m.coordinate) { count += 1 }
            }
            // 동네 단위까지 당겨봤다면 밀도를 따지지 않는다. 그 줌에서 핀이 여러 개 겹쳐 보이는
            // 것은 사용자가 의도한 것이고, 오히려 이름이 안 보이면 고를 수가 없다.
            let shouldShow = zoom >= Coordinator.labelAlwaysZoom
                          || (zoom >= Coordinator.labelZoomThreshold
                              && visible <= Coordinator.labelDensityLimit)
            defer { showLabels = shouldShow }
            return shouldShow != showLabels
        }

        /// 화면 밖 마커를 걸러낸다.
        ///
        /// 전국 코스가 900개를 넘으면서 보이지도 않는 마커까지 GMSMarker로 만들고 있었다
        /// (줌 12 기준 약 680개). 보이는 것만 만들면 팬·줌이 눈에 띄게 가벼워진다.
        /// 다만 화면에 딱 맞춰 자르면 조금만 밀어도 가장자리가 비므로, 사방으로 화면 절반씩
        /// 넓힌 범위를 쓴다 — 그 여유 덕에 대부분의 팬은 재계산 없이 지나간다.
        private func culled(_ markers: [GoogleMapMarker], on mapView: GMSMapView) -> [GoogleMapMarker] {
            let region = mapView.projection.visibleRegion()
            let latSpan = abs(region.farLeft.latitude - region.nearLeft.latitude)
            let lngSpan = abs(region.farRight.longitude - region.farLeft.longitude)
            guard latSpan > 0, lngSpan > 0, latSpan < 170, lngSpan < 350 else { return markers }
            let minLat = min(region.nearLeft.latitude, region.farLeft.latitude) - latSpan / 2
            let maxLat = max(region.nearLeft.latitude, region.farLeft.latitude) + latSpan / 2
            let minLng = min(region.farLeft.longitude, region.nearLeft.longitude) - lngSpan / 2
            let maxLng = max(region.farRight.longitude, region.nearRight.longitude) + lngSpan / 2
            return markers.filter { m in
                // 선택 강조·검색 핀은 화면 밖이어도 남긴다 — 카메라가 그쪽으로 가는 중일 수 있다
                if m.highlighted || m.symbolName != nil || m.icon != nil { return true }
                let c = m.coordinate
                return c.latitude >= minLat && c.latitude <= maxLat
                    && c.longitude >= minLng && c.longitude <= maxLng
            }
        }

        /// 화면에 그릴 핀을 솎아낸다. **묶어서 숫자로 만들지 않는다.**
        ///
        /// 처음엔 숫자 클러스터를 썼는데 지도가 주황 동그라미로 덮여 더 나빠졌다.
        /// "이 근처에 157개"라는 정보는 어디로 갈지 정하는 데 아무 도움이 되지 않는다.
        /// 실제 지도 앱들이 하는 대로 간다 — 멀리서는 아무것도 그리지 않고(확대 유도),
        /// 가까이서는 화면에 담기는 만큼만 개별 핀으로 보여준다.
        ///
        /// 남길 것을 고르는 기준은 **화면 중심에서 가까운 순**이다. 사용자가 방금 가져다 놓은
        /// 지점이 곧 관심사이므로, 가운데부터 채우는 편이 가장자리 것을 남기는 것보다 낫다.
        private func thinned(_ markers: [GoogleMapMarker], on mapView: GMSMapView) -> [GoogleMapMarker] {
            // 선택 강조·검색 핀은 어떤 경우에도 남긴다 — 사용자가 방금 지목한 대상이다
            let pinned = markers.filter { $0.highlighted || $0.symbolName != nil || $0.icon != nil }
            let rest = markers.filter { !($0.highlighted || $0.symbolName != nil || $0.icon != nil) }

            guard mapView.camera.zoom >= Coordinator.pinMinZoom else { return pinned }

            let visible = culled(rest, on: mapView)
            guard visible.count > Coordinator.maxVisiblePins else { return pinned + visible }

            let c = mapView.camera.target
            let near = visible.sorted {
                let d0 = pow($0.coordinate.latitude - c.latitude, 2)
                       + pow(($0.coordinate.longitude - c.longitude) * 0.8, 2)
                let d1 = pow($1.coordinate.latitude - c.latitude, 2)
                       + pow(($1.coordinate.longitude - c.longitude) * 0.8, 2)
                return d0 < d1
            }
            return pinned + near.prefix(Coordinator.maxVisiblePins)
        }

        /// 이 마커의 **그림**을 결정하는 값들. 이게 같으면 아이콘을 다시 그리지 않는다.
        private func renderKey(_ m: GoogleMapMarker) -> String {
            "\(m.pinImageName ?? "")|\(showLabels ? (m.label ?? "") : "")|\(m.badgeNumber.map(String.init) ?? "")|\(m.symbolName ?? "")|\(m.highlighted ? 1 : 0)|\(m.styleKey ?? "")|\(m.curated ? 1 : 0)"
        }

        private func applyIcon(to marker: GMSMarker, _ m: GoogleMapMarker) {
            marker.title = m.title
            marker.userData = m.id
            if let customIcon = m.icon {
                marker.icon = customIcon
                marker.groundAnchor = m.iconAnchor
            } else {
                let rendered = MarkerIcon.make(pinImageName: m.pinImageName,
                                               label: showLabels ? m.label : nil,
                                               badge: m.badgeNumber,
                                               symbolName: m.symbolName,
                                               highlighted: m.highlighted,
                                               curated: m.curated)
                marker.icon = rendered.image
                marker.groundAnchor = rendered.anchor
            }
            marker.zIndex = m.highlighted ? 1 : 0
        }

        /// 마커를 **증분으로** 반영한다.
        ///
        /// 예전에는 목록이 조금이라도 바뀌면 전부 `map = nil` 하고 새로 만들었다. 코스가
        /// 수십 개일 땐 티가 안 났지만, 전국 큐레이션(900여 개)을 넣고 지도를 옮기자
        /// **핀이 통째로 사라졌다 다시 나타나 지도를 쓸 수 없었다** — 팬할 때마다
        /// 그 지역 코스가 붙고, 그때마다 전멸 후 재생성이 일어났기 때문이다.
        /// 그래서 id로 맞춰 살아남을 것은 그대로 두고, 바뀐 것만 손댄다.
        func rebuildMarkers(on mapView: GMSMapView, markers: [GoogleMapMarker]) {
            lastMarkers = markers
            // 라벨 표시 여부는 클러스터링 결과에 달렸고, 클러스터 계산은 라벨과 무관하다.
            // 그래서 묶은 뒤에 라벨을 정하고, 서명은 그 다음에 만든다.
            let shown = thinsMarkers ? thinned(markers, on: mapView) : markers
            updateLabelVisibility(on: mapView, shown: shown)

            let sig = shown.map { "\($0.id)|" + renderKey($0)
                + String(format: "|%.5f,%.5f", $0.coordinate.latitude, $0.coordinate.longitude)
            }.joined(separator: ";")
            guard sig != lastSignature else { return }
            lastSignature = sig

            var alive = Set<String>()
            for m in shown {
                alive.insert(m.id)
                let key = renderKey(m)
                if let existing = markerViews[m.id] {
                    if markerKeys[m.id] != key {
                        applyIcon(to: existing, m)
                        markerKeys[m.id] = key
                    }
                    if existing.position.latitude != m.coordinate.latitude
                        || existing.position.longitude != m.coordinate.longitude {
                        existing.position = m.coordinate
                    }
                } else {
                    let marker = GMSMarker(position: m.coordinate)
                    applyIcon(to: marker, m)
                    marker.map = mapView
                    markerViews[m.id] = marker
                    markerKeys[m.id] = key
                }
            }
            for (id, marker) in markerViews where !alive.contains(id) {
                marker.map = nil
                markerViews.removeValue(forKey: id)
                markerKeys.removeValue(forKey: id)
            }
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
            if let id = marker.userData as? String { onMarkerTap?(id) }
            return true // 기본 정보창/센터링 억제
        }

        func mapView(_ mapView: GMSMapView, idleAt position: GMSCameraPosition) {
            // 줌이 바뀌면 클러스터 묶음과 라벨 조건이 함께 달라진다. 항상 다시 계산하되,
            // 결과가 같으면 서명 비교에서 걸러지므로 실제 그리기는 일어나지 않는다.
            rebuildMarkers(on: mapView, markers: lastMarkers)
            onCameraIdle?(position)
        }
    }
}

// 마커 아이콘 합성: (태그 핀 이미지 또는 기본/번호 핀) + 코스명 라벨.
// 핀 끝(tip)이 좌표에 닿도록 groundAnchor를 함께 계산해 반환.
private enum MarkerIcon {
    static var cache: [String: (image: UIImage, anchor: CGPoint)] = [:]
    static let orange = UIColor(red: 1.0, green: 0.42, blue: 0.21, alpha: 1.0)

    static func make(pinImageName: String?, label: String?, badge: Int?,
                     symbolName: String? = nil, highlighted: Bool = false,
                     curated: Bool = false) -> (image: UIImage, anchor: CGPoint) {
        let key = "\(pinImageName ?? "")|\(label ?? "")|\(badge.map(String.init) ?? "")|\(symbolName ?? "")|\(highlighted ? 1 : 0)|\(curated ? 1 : 0)"
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
                drawDefaultPin(in: CGRect(x: pinX, y: 0, width: pinW, height: pinH), badge: badge,
                               symbolName: symbolName, highlighted: highlighted, ctx: ctx)
            }
            // 코스명 라벨 (흰 캡슐 + 얇은 테두리 + 은은한 그림자 + 다크 텍스트)
            if hasLabel {
                let lx = (totalW - labelSize.width) / 2
                let lrect = CGRect(x: lx, y: pinH + gap, width: labelSize.width, height: labelSize.height)
                let capsule = UIBezierPath(roundedRect: lrect, cornerRadius: labelSize.height / 2)
                ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.5,
                                        color: UIColor.black.withAlphaComponent(0.18).cgColor)
                // 큐레이션 코스는 **주황 테두리**로 구분한다.
                // 캡슐을 통째로 주황으로 채웠더니 라벨이 전부 강하게 튀어 지도를 덮어버렸다
                // (수도권 182개를 넣고 실제로 확인). 바탕은 흰색으로 두고 테두리만 바꾼다.
                UIColor.white.withAlphaComponent(0.98).setFill()
                capsule.fill()
                ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
                (curated ? orange : UIColor.black.withAlphaComponent(0.06)).setStroke()
                capsule.lineWidth = curated ? 1.5 : 0.5
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
    private static func drawDefaultPin(in rect: CGRect, badge: Int?, symbolName: String? = nil,
                                       highlighted: Bool, ctx: UIGraphicsImageRendererContext) {
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

        // 번호가 없는 핀(검색으로 찍은 장소 등)은 빈 주황 원이 돼 무엇을 가리키는지 알 수 없다.
        // 흰 글리프를 넣어 코스 핀과 역할을 구분한다.
        if badge == nil, let symbolName,
           let glyph = UIImage(systemName: symbolName)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) {
            let side = circleD * 0.5
            let box = CGRect(x: circleRect.midX - side / 2, y: circleRect.midY - side / 2,
                             width: side, height: side)
            glyph.draw(in: box)
        }
    }
}
