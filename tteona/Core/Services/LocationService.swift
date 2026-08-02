import Foundation
import Combine
import CoreLocation
import UserNotifications

/// 위치 서비스 오류 — superseded는 새 1회성 요청이 이전 요청을 대체했을 때.
enum LocationError: Error, Equatable {
    case superseded
    /// 응답이 오지 않아 스스로 끊었다 — CoreLocation은 콜백을 보장하지 않는다
    case timedOut
    /// 위치 권한이 거부·제한됨. 재시도해도 소용없으니 설정으로 안내해야 한다
    case denied
}

@MainActor
class LocationService: NSObject, ObservableObject {
    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var arrivedAtPlace: Place?

    private let manager = CLLocationManager()
    private var monitoredPlaces: [Place] = []
    private let arrivalRadius: CLLocationDistance = 50

    private var oneTimeLocationContinuation: CheckedContinuation<CLLocation, Error>?
    private var oneTimeTimeoutTask: Task<Void, Never>?
    /// 권한이 정해진 뒤 실제 측위에 줄 시간 — 권한 팝업 대기 시간은 여기 포함되지 않는다
    private var pendingLocationTimeout: TimeInterval = 6

    /// 실제 측위 요청을 내고 시한을 건다.
    /// 권한이 정해진 뒤에만 부른다 — 미결정 상태의 requestLocation()은 조용히 버려진다.
    private func beginOneTimeRequest(timeout: TimeInterval) {
        oneTimeTimeoutTask?.cancel()
        oneTimeTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.timeOutOneTimeLocation()
        }
        manager.requestLocation()
    }

    /// 1회성 위치 요청이 끝나는 **유일한** 지점.
    /// 응답·실패·시한 초과 중 무엇으로 끝나든 여기로 모아, continuation을 두 번 재개하거나
    /// 시한 타이머를 남겨 두는 일이 없게 한다.
    private func finishOneTimeLocation(_ result: Result<CLLocation, Error>) {
        guard let pending = oneTimeLocationContinuation else { return }
        oneTimeLocationContinuation = nil
        oneTimeTimeoutTask?.cancel()
        oneTimeTimeoutTask = nil
        pending.resume(with: result)
    }

    /// 시한이 다 됐을 때 — 조금 오래된 위치라도 있으면 그걸 쓴다.
    /// 방금 찍은 클립의 장소를 고르는 자리라 사용자는 실제로 그 근처에 있다.
    /// 다만 너무 묵은 좌표는 엉뚱한 도시를 기록해 버리므로 30분으로 끊는다.
    private func timeOutOneTimeLocation() {
        if let recent = currentLocation, Date().timeIntervalSince(recent.timestamp) < 30 * 60 {
            finishOneTimeLocation(.success(recent))
        } else {
            finishOneTimeLocation(.failure(LocationError.timedOut))
        }
    }

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
        // 도착 알림이 실제 필요한 세션 시작 시에만 권한 요청 —
        // 빈 목록(홈 지도 로드)에서 요청하면 앱 진입 직후 맥락 없는 팝업이 뜬다
        if !places.isEmpty {
            requestNotificationPermission()
        }
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
    func requestOneTimeLocation(timeout: TimeInterval = 6) async throws -> CLLocation {
        // 최근 60초 이내 위치가 있으면 즉시 반환 (연속 업데이트 중일 때 빠름)
        if let loc = currentLocation, Date().timeIntervalSince(loc.timestamp) < 60 {
            return loc
        }
        // 권한이 이미 거부·제한이면 requestLocation()은 콜백 없이 조용히 잠긴다.
        // 시한까지 기다릴 이유가 없으니 바로 알리고 설정으로 안내한다.
        if authorizationStatus == .denied || authorizationStatus == .restricted {
            throw LocationError.denied
        }
        // 이미 대기 중인 요청이 있으면, 그 continuation을 잃어버리지 않도록 먼저 안전하게
        // 종료(supersede)한다. 그냥 덮어쓰면 이전 continuation이 영원히 resume되지 않아
        // 그 태스크가 무한 대기(스피너 멈춤)에 빠진다.
        finishOneTimeLocation(.failure(LocationError.superseded))

        return try await withCheckedThrowingContinuation { continuation in
            oneTimeLocationContinuation = continuation
            pendingLocationTimeout = timeout

            // CoreLocation은 응답을 보장하지 않는다. 측위가 안 되는 곳에서 requestLocation()이
            // 콜백 없이 잠기면 continuation이 영원히 살아남아 스피너가 멈춘다. 시한을 둔다.
            //
            // 다만 시계를 언제 켜느냐가 중요하다. 권한 팝업이 떠 있는 동안까지 시한에 넣으면
            // 사용자가 팝업을 읽는 사이 시간이 다 흘러, '허용'을 누르자마자 실패로 끝나 버린다.
            // 그래서 권한이 정해지기 전에는 넉넉한 안전망만 걸고, 정해지는 순간
            // didChangeAuthorization이 요청을 다시 내면서 짧은 시한으로 갈아 끼운다.
            if authorizationStatus == .notDetermined {
                oneTimeTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(45))
                    guard !Task.isCancelled else { return }
                    self?.timeOutOneTimeLocation()
                }
            } else {
                beginOneTimeRequest(timeout: timeout)
            }
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
        content.title = L("notif.arrived.title", placeName)
        content.body = L("notif.arrived.body")
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
            self.finishOneTimeLocation(.success(location))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finishOneTimeLocation(.failure(error))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                manager.startUpdatingLocation()
                // 권한 미결정일 때 낸 requestLocation()은 조용히 버려졌다.
                // 이제 다시 내고, 팝업 대기 시간이 빠진 짧은 시한으로 바꾼다.
                if self.oneTimeLocationContinuation != nil {
                    self.beginOneTimeRequest(timeout: self.pendingLocationTimeout)
                }
            } else if status == .denied || status == .restricted {
                // 거부가 확정되면 requestLocation()은 영영 답하지 않는다 — 시한을 기다릴 것 없이 끝낸다
                self.finishOneTimeLocation(.failure(LocationError.denied))
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
