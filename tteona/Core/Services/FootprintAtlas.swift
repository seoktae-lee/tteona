import Foundation
import CoreGraphics

// MARK: - 지역 폴리곤 (발자취 지도용)
/// 번들 GeoJSON에서 로드한 하나의 지역(한국 시군구 또는 세계 주/도).
/// 링 좌표는 웹 메르카토르 단위공간(0~1)으로 투영해 보관 — 렌더링·판정 모두 이 공간에서 수행.
struct GeoRegion: Identifiable {
    let code: String        // 시군구 행정코드("11010") 또는 ISO 3166-2 주/도코드("JP-27")
    let name: String        // 한글/원어 이름
    let nameEng: String?    // 영문 이름 (주/도는 name이 이미 영문)
    let country: String?    // 소속 국가 ISO3 (주/도만; 한국 시군구는 nil = 암묵적 KOR)
    let rings: [[CGPoint]]  // 외곽 + 구멍 링 (even-odd 채움)
    let bbox: CGRect        // 단위공간 바운딩박스 (빠른 후보 선별용)
    let path: CGPath        // 단위공간에 미리 구운 패스 (Canvas 렌더링 캐시)

    var id: String { code }
    var center: CGPoint { CGPoint(x: bbox.midX, y: bbox.midY) }
}

// MARK: - 발자취 아틀라스
/// 한국 시군구 250개 + 세계 주/도(admin-1) 4,600여 개 경계를 앱 번들에서 로드하고,
/// 좌표 → 지역 판정(point-in-polygon)을 오프라인으로 수행한다.
/// 해외는 국가 통째가 아니라 주/도 단위로 칠해진다(한국 시군구에 대응하는 세분화).
final class FootprintAtlas: @unchecked Sendable {
    static let shared = FootprintAtlas()

    private(set) var koreaRegions: [GeoRegion] = []      // 시군구 (250)
    private(set) var worldProvinces: [GeoRegion] = []    // 세계 주/도 (admin-1)
    /// 국가 ISO3 → 소속 주/도들의 합집합 바운딩박스 (카메라 포커스용)
    private(set) var countryBBox: [String: CGRect] = [:]

    private let loadLock = NSLock()
    private var loaded = false

    /// 한국 대략 범위(도 단위) — 시군구 판정을 시도할지 결정
    private let koreaLatRange = 32.0...39.5
    private let koreaLngRange = 124.0...132.5

    // MARK: 로드

    /// 최초 1회 GeoJSON 파싱 (약 0.3~0.6초, 백그라운드 스레드에서 호출할 것)
    func ensureLoaded() {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard !loaded else { return }
        koreaRegions = Self.load(resource: "korea-sig", codeKey: "code", nameKey: "name",
                                 nameEngKey: "name_eng", countryKey: nil)
        worldProvinces = Self.load(resource: "world-admin1", codeKey: "code", nameKey: "nm",
                                   nameEngKey: nil, countryKey: "country")

        // 국가별 바운딩박스 = 소속 주/도 bbox 합집합
        var boxes: [String: CGRect] = [:]
        for province in worldProvinces {
            guard let iso3 = province.country else { continue }
            boxes[iso3] = boxes[iso3].map { $0.union(province.bbox) } ?? province.bbox
        }
        countryBBox = boxes

        loaded = true
        print("[FootprintAtlas] loaded korea=\(koreaRegions.count) provinces=\(worldProvinces.count) countries=\(countryBBox.count)")
    }

    private static func load(resource: String, codeKey: String, nameKey: String,
                             nameEngKey: String?, countryKey: String?) -> [GeoRegion] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            print("[FootprintAtlas] failed to load \(resource).geojson")
            return []
        }

        var regions: [GeoRegion] = []
        regions.reserveCapacity(features.count)

        for feature in features {
            guard let props = feature["properties"] as? [String: Any],
                  let code = props[codeKey] as? String, !code.isEmpty,
                  let name = props[nameKey] as? String,
                  let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String,
                  let coords = geometry["coordinates"] else { continue }

            var rings: [[CGPoint]] = []
            if type == "Polygon", let polygon = coords as? [[[Double]]] {
                rings = polygon.compactMap(Self.projectRing)
            } else if type == "MultiPolygon", let multi = coords as? [[[[Double]]]] {
                for polygon in multi {
                    rings.append(contentsOf: polygon.compactMap(Self.projectRing))
                }
            }
            guard !rings.isEmpty else { continue }

            var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            let mutablePath = CGMutablePath()
            for ring in rings {
                guard let first = ring.first else { continue }
                mutablePath.move(to: first)
                for pt in ring.dropFirst() { mutablePath.addLine(to: pt) }
                mutablePath.closeSubpath()
                for pt in ring {
                    minX = min(minX, pt.x); minY = min(minY, pt.y)
                    maxX = max(maxX, pt.x); maxY = max(maxY, pt.y)
                }
            }

            regions.append(GeoRegion(
                code: code,
                name: name,
                nameEng: props[nameEngKey ?? ""] as? String,
                country: countryKey.flatMap { props[$0] as? String },
                rings: rings,
                bbox: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                path: mutablePath.copy() ?? mutablePath
            ))
        }
        return regions
    }

    private static func projectRing(_ ring: [[Double]]) -> [CGPoint]? {
        guard ring.count >= 3 else { return nil }
        return ring.map { project(lat: $0[1], lng: $0[0]) }
    }

    // MARK: 투영

    /// 위경도 → 웹 메르카토르 단위공간(0~1). 지도 렌더링·판정 공용.
    static func project(lat: Double, lng: Double) -> CGPoint {
        let x = (lng + 180) / 360
        let clamped = max(-85.0, min(85.0, lat)) * .pi / 180
        let y = (1 - log(tan(.pi / 4 + clamped / 2)) / .pi) / 2
        return CGPoint(x: x, y: y)
    }

    // MARK: 판정

    struct ResolvedRegion {
        let sig: GeoRegion?        // 한국 시군구 (한국 밖이면 nil)
        let province: GeoRegion?   // 세계 주/도
        let countryCode: String?   // 소속 국가 ISO3
    }

    /// 좌표가 속한 시군구·주도·국가 판정. 단순화된 경계라 해안가 등에서 빗나가면 근접 폴리곤으로 보정.
    func resolve(lat: Double, lng: Double) -> ResolvedRegion {
        ensureLoaded()
        let pt = Self.project(lat: lat, lng: lng)

        var sig: GeoRegion? = nil
        if koreaLatRange.contains(lat), koreaLngRange.contains(lng) {
            sig = hit(point: pt, in: koreaRegions)
                ?? nearest(point: pt, in: koreaRegions, maxUnitDistance: 0.0006) // ≈ 20km
        }

        let province = hit(point: pt, in: worldProvinces)
            ?? nearest(point: pt, in: worldProvinces, maxUnitDistance: 0.009)     // ≈ 3°
        // 시군구가 잡혔으면 국가는 무조건 한국 (경계 오차로 주/도가 빗나가도 보정)
        let countryCode = sig != nil ? "KOR" : province?.country
        return ResolvedRegion(sig: sig, province: province, countryCode: countryCode)
    }

    private func hit(point: CGPoint, in regions: [GeoRegion]) -> GeoRegion? {
        for region in regions where region.bbox.insetBy(dx: -0.0001, dy: -0.0001).contains(point) {
            if contains(point: point, rings: region.rings) { return region }
        }
        return nil
    }

    /// even-odd 규칙 point-in-polygon (구멍 링 포함 처리)
    private func contains(point: CGPoint, rings: [[CGPoint]]) -> Bool {
        var inside = false
        for ring in rings {
            var j = ring.count - 1
            for i in 0..<ring.count {
                let a = ring[i], b = ring[j]
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                    inside.toggle()
                }
                j = i
            }
        }
        return inside
    }

    /// 어느 폴리곤에도 안 들어갈 때(단순화 오차·해안) 가장 가까운 경계 정점 기준 근접 지역 선택
    private func nearest(point: CGPoint, in regions: [GeoRegion], maxUnitDistance: CGFloat) -> GeoRegion? {
        var best: (region: GeoRegion, dist: CGFloat)? = nil
        for region in regions {
            // bbox에서 이미 멀면 스킵
            let expanded = region.bbox.insetBy(dx: -maxUnitDistance, dy: -maxUnitDistance)
            guard expanded.contains(point) else { continue }
            for ring in region.rings {
                for pt in ring {
                    let d = hypot(pt.x - point.x, pt.y - point.y)
                    if d < maxUnitDistance, d < (best?.dist ?? .greatestFiniteMagnitude) {
                        best = (region, d)
                    }
                }
            }
        }
        return best?.region
    }

    // MARK: 조회 헬퍼

    func koreaRegion(code: String) -> GeoRegion? {
        ensureLoaded()
        return koreaRegions.first { $0.code == code }
    }

    func province(code: String) -> GeoRegion? {
        ensureLoaded()
        return worldProvinces.first { $0.code == code }
    }
}
