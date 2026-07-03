import Foundation
import MapKit

// MARK: - 날씨 (Open-Meteo, API 키 불필요)

struct WeatherInfo {
    let tempC: Double
    let code: Int

    var emoji: String {
        switch code {
        case 0:            return "☀️"
        case 1, 2:         return "🌤️"
        case 3:            return "☁️"
        case 45, 48:       return "🌫️"
        case 51...67:      return "🌧️"
        case 71...77:      return "❄️"
        case 80...82:      return "🌦️"
        case 85, 86:       return "🌨️"
        case 95...99:      return "⛈️"
        default:           return "🌡️"
        }
    }

    var description: String {
        switch code {
        case 0:            return "맑음"
        case 1, 2:         return "구름 조금"
        case 3:            return "흐림"
        case 45, 48:       return "안개"
        case 51...57:      return "이슬비"
        case 61...67:      return "비"
        case 71...77:      return "눈"
        case 80...82:      return "소나기"
        case 85, 86:       return "눈 소나기"
        case 95...99:      return "뇌우"
        default:           return "-"
        }
    }
}

// MARK: - 경로 (MKDirections, API 키 불필요)

struct RouteInfo {
    let distanceMeters: Double
    let travelTimeSec: Double

    var distanceText: String {
        if distanceMeters >= 1000 {
            return String(format: "%.1fkm", distanceMeters / 1000)
        }
        return String(format: "%.0fm", distanceMeters)
    }

    var timeText: String {
        let minutes = Int(travelTimeSec / 60)
        if minutes >= 60 {
            return "\(minutes / 60)시간 \(minutes % 60)분"
        }
        return "\(max(minutes, 1))분"
    }
}

actor ExploreInfoService {
    static let shared = ExploreInfoService()

    // 날씨 조회
    func fetchWeather(lat: Double, lng: Double) async -> WeatherInfo? {
        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lng)&current=temperature_2m,weather_code"
        guard let url = URL(string: urlStr) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any],
                  let temp = current["temperature_2m"] as? Double,
                  let code = current["weather_code"] as? Int else { return nil }
            return WeatherInfo(tempC: temp, code: code)
        } catch {
            print("[ExploreInfoService] weather error:", error)
            return nil
        }
    }

    // 서버 통합 경로 (한국 자동차=카카오모빌리티 실측, 그 외=추정). 실패 시 nil.
    func computeServerRoute(places: [Place], mode: String) async -> RouteInfo? {
        guard places.count >= 2, let url = URL(string: "https://tteona.kr/api/route") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "mode": mode,
            "places": places.map { ["lat": $0.latitude, "lng": $0.longitude] }
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let dist = (j["distanceMeters"] as? Double) ?? Double(j["distanceMeters"] as? Int ?? 0)
            let time = (j["travelTimeSec"] as? Double) ?? Double(j["travelTimeSec"] as? Int ?? 0)
            guard dist > 0 else { return nil }
            return RouteInfo(distanceMeters: dist, travelTimeSec: time)
        } catch {
            return nil
        }
    }

    // 코스 전체 이동거리 + 소요시간 (수단별)
    func computeRoute(places: [Place], transport: MKDirectionsTransportType) async -> RouteInfo {
        guard places.count >= 2 else { return RouteInfo(distanceMeters: 0, travelTimeSec: 0) }

        // 폴백 속도(m/s): 도보 4.5km/h, 자동차 40km/h(도심 평균)
        let fallbackSpeed: Double = transport == .walking ? (4500.0 / 3600.0) : (40000.0 / 3600.0)

        var totalDistance: Double = 0
        var totalTime: Double = 0

        for i in 0..<(places.count - 1) {
            let from = places[i].coordinate
            let to   = places[i + 1].coordinate

            if let leg = await calculateLeg(from: from, to: to, transport: transport) {
                totalDistance += leg.distanceMeters
                totalTime     += leg.travelTimeSec
            } else {
                let d = haversineMeters(from, to)
                totalDistance += d
                totalTime     += d / fallbackSpeed
            }
        }
        return RouteInfo(distanceMeters: totalDistance, travelTimeSec: totalTime)
    }

    private func calculateLeg(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                              transport: MKDirectionsTransportType) async -> RouteInfo? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = transport
        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else { return nil }
            return RouteInfo(distanceMeters: route.distance, travelTimeSec: route.expectedTravelTime)
        } catch {
            return nil
        }
    }

    // 대중교통 (ODsay) — WAS 경유. 키 연동 후 활성화.
    func computeTransitRoute(places: [Place]) async -> RouteInfo? {
        guard places.count >= 2 else { return nil }
        guard let url = URL(string: "https://tteona.kr/api/courses/transit-route") else { return nil }

        let coords = places.map { ["lat": $0.latitude, "lng": $0.longitude] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["places": coords])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dist = json["distanceMeters"] as? Double,
                  let time = json["travelTimeSec"] as? Double else { return nil }
            return RouteInfo(distanceMeters: dist, travelTimeSec: time)
        } catch {
            return nil
        }
    }

    private func haversineMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return R * 2 * atan2(sqrt(h), sqrt(1 - h))
    }
}
