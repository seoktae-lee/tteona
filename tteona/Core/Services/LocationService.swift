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

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
    }

    func requestPermission() {
        manager.requestAlwaysAuthorization()
    }

    func startTracking(places: [Place]) {
        monitoredPlaces = places
        manager.startUpdatingLocation()
        setupGeofences(for: places)
        requestNotificationPermission()
    }

    func stopTracking() {
        manager.stopUpdatingLocation()
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        monitoredPlaces = []
    }

    // MARK: - Geofencing
    private func setupGeofences(for places: [Place]) {
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        for place in places {
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
