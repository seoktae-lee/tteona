import Foundation
import UIKit
import CoreLocation

/// 길찾기·장소 보기를 **설치된 지도 앱에 넘긴다.**
///
/// 앱 안에 턴바이턴 안내를 만들지 않는다. 도로 단위 경로, 이탈 시 재탐색, 음성 안내는
/// 지도 회사가 수년에 걸쳐 만드는 것이고, 무엇보다 사용자는 이미 쓰던 지도 앱이 있다.
/// 그쪽이 더 정확하고 익숙하다.
///
/// 애플 지도는 iOS에 항상 있으므로 **최후 수단이 보장된다** — 어떤 기기에서도 길찾기가
/// 실패하지 않는다.
enum MapAppLauncher {

    /// 이동 수단. 거리로 자동 판단한다 — 20km 떨어진 곳을 도보로 안내하면 곤란하고,
    /// 500m를 대중교통으로 안내해도 마찬가지다.
    enum Mode {
        case walk, transit, car

        static func suggested(forMeters meters: Double?) -> Mode {
            guard let meters else { return .transit }
            if meters <= 1500 { return .walk }
            if meters <= 40_000 { return .transit }
            return .car
        }

        var kakao: String {
            switch self {
            case .walk: return "FOOT"
            case .transit: return "PUBLICTRANSIT"
            case .car: return "CAR"
            }
        }
        var naverPath: String {
            switch self {
            case .walk: return "route/walk"
            case .transit: return "route/public"
            case .car: return "route/car"
            }
        }
        var appleFlag: String {
            switch self {
            case .walk: return "w"
            case .transit: return "r"
            case .car: return "d"
            }
        }
    }

    /// 현재 위치에서 목적지까지 길안내를 연다.
    ///
    /// 출발지를 넘기지 않는다 — 지도 앱이 자기 위치 정보로 현재 위치를 잡는 편이
    /// 우리가 마지막으로 알던 좌표를 넘기는 것보다 정확하다.
    static func openDirections(to coordinate: CLLocationCoordinate2D,
                               name: String,
                               distanceMeters: Double? = nil) {
        let mode = Mode.suggested(forMeters: distanceMeters)
        let lat = coordinate.latitude, lng = coordinate.longitude
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let bundleId = Bundle.main.bundleIdentifier ?? "com.seoktaedev.tteona"

        // 네이버지도 → 카카오맵 → 애플 지도 순. 국내 이용자 다수가 네이버를 쓴다.
        let candidates = [
            // 네이버는 목적지 이름(dname)과 호출 앱(appname)이 없으면 열리지 않는다
            "nmap://\(mode.naverPath)?dlat=\(lat)&dlng=\(lng)&dname=\(encoded)&appname=\(bundleId)",
            "kakaomap://route?ep=\(lat),\(lng)&by=\(mode.kakao)",
        ]
        for scheme in candidates {
            if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }
        if let apple = URL(string: "maps://?daddr=\(lat),\(lng)&dirflg=\(mode.appleFlag)") {
            UIApplication.shared.open(apple)
        }
    }

    /// 목적지를 지도에서 보여주기만 한다(길안내 없이).
    static func openPlace(at coordinate: CLLocationCoordinate2D, name: String) {
        let lat = coordinate.latitude, lng = coordinate.longitude
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let bundleId = Bundle.main.bundleIdentifier ?? "com.seoktaedev.tteona"
        for scheme in ["nmap://place?lat=\(lat)&lng=\(lng)&name=\(encoded)&appname=\(bundleId)",
                       "kakaomap://look?p=\(lat),\(lng)"] {
            if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }
        if let apple = URL(string: "maps://?ll=\(lat),\(lng)&q=\(encoded)") {
            UIApplication.shared.open(apple)
        }
    }
}
