import Foundation
import Combine
import CoreLocation
import UserNotifications

@MainActor
class LocationService: NSObject, ObservableObject {
    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var arrivedAtPlace: Place?

    private let manager = CLLocationManager()
    private var monitoredPlaces: [Place] = []
    private let arrivalRadius: CLLocationDistance = 50

    private var oneTimeLocationContinuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
    }

    func requestPermission() {
        manager.requestAlwaysAuthorization()
    }

    // 나의 오늘 모드: 연속 업데이트로 currentLocation 항상 최신 유지
    func startContinuousUpdates() {
        manager.startUpdatingLocation()
    }

    func stopContinuousUpdates() {
        manager.stopUpdatingLocation()
    }

    func startTracking(places: [Place]) {
        monitoredPlaces = places
        manager.allowsBackgroundLocationUpdates = !places.isEmpty
        manager.startUpdatingLocation()
        setupGeofences(for: places)
        requestNotificationPermission()
    }

    func stopTracking() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        monitoredPlaces = []
    }

    // 촬영 버튼 눌렀을 때만 위치 한 번 요청
    func requestOneTimeLocation() async throws -> CLLocation {
        // 최근 60초 이내 위치가 있으면 즉시 반환 (연속 업데이트 중일 때 빠름)
        if let loc = currentLocation, Date().timeIntervalSince(loc.timestamp) < 60 {
            return loc
        }
        return try await withCheckedThrowingContinuation { continuation in
            oneTimeLocationContinuation = continuation
            manager.requestLocation()
        }
    }

    // MARK: - Geofencing
    private func setupGeofences(for places: [Place]) {
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        // iOS는 앱당 최대 20개 region만 감시 가능 — 초과분은 조용히 실패하므로
        // 현재 위치에서 가까운 순으로 20개만 등록 (도착 감지는 거리 기반 버튼이 보완)
        var targets = places
        if targets.count > 20 {
            if let current = currentLocation {
                targets = targets.sorted {
                    current.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                    < current.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
                }
            }
            targets = Array(targets.prefix(20))
        }
        for place in targets {
            let region = CLCircularRegion(
                center: place.coordinate,
                radius: arrivalRadius,
                identifier: "place_\(place.order)_\(place.placeName)"
            )
            region.notifyOnEntry = true
            region.notifyOnExit = false
            manager.startMonitoring(for: region)
        }
    }

    // MARK: - Notifications
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func sendArrivalNotification(placeName: String) {
        let content = UNMutableNotificationContent()
        content.title = "📍 \(placeName)에 도착했어요!"
        content.body = "지금 촬영하세요"
        content.sound = .default
        content.userInfo = ["placeName": placeName, "action": "openCamera"]

        let request = UNNotificationRequest(
            identifier: "arrival_\(placeName)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Distance to next place
    func distance(to place: Place) -> CLLocationDistance? {
        guard let current = currentLocation else { return nil }
        let target = CLLocation(latitude: place.latitude, longitude: place.longitude)
        return current.distance(from: target)
    }
}

// MARK: - CLLocationManagerDelegate
extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.currentLocation = location
            // requestLocation 일회성 응답
            self.oneTimeLocationContinuation?.resume(returning: location)
            self.oneTimeLocationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.oneTimeLocationContinuation?.resume(throwing: error)
            self.oneTimeLocationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circularRegion = region as? CLCircularRegion else { return }
        let identifier = circularRegion.identifier

        Task { @MainActor in
            if let place = self.monitoredPlaces.first(where: { "place_\($0.order)_\($0.placeName)" == identifier }) {
                self.arrivedAtPlace = place
                self.sendArrivalNotification(placeName: place.placeName)
            }
        }
    }
}
