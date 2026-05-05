import SwiftUI
import MapKit

struct ActiveSessionView: View {
    let course: Course
    @StateObject private var locationService = LocationService()
    @Environment(\.dismiss) private var dismiss

    @State private var currentPlaceIndex = 0
    @State private var visitedPlaces: Set<Int> = []
    @State private var showCamera = false
    @State private var showVlog = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showArrivalBanner = false
    @State private var arrivedPlace: Place?

    private var currentPlace: Place? {
        guard currentPlaceIndex < course.places.count else { return nil }
        return course.places[currentPlaceIndex]
    }

    private var allVisited: Bool {
        visitedPlaces.count >= course.places.count
    }

    var body: some View {
        ZStack {
            mapLayer
            topBar
            bottomPanel

            if showArrivalBanner, let place = arrivedPlace {
                ArrivalBanner(placeName: place.placeName)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { showCamera = true }
            }
        }
        .ignoresSafeArea()
        .task {
            locationService.requestPermission()
            locationService.startTracking(places: course.places)
            fitMap()
        }
        .onDisappear {
            locationService.stopTracking()
        }
        .onChange(of: locationService.arrivedAtPlace) { _, place in
            guard let place else { return }
            arrivedPlace = place
            withAnimation { showArrivalBanner = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation { showArrivalBanner = false }
            }
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: handleCameraDismiss) {
            if let place = currentPlace {
                CameraView(place: place, sessionId: course.courseId)
            }
        }
        .fullScreenCover(isPresented: $showVlog) {
            VlogGenerationView(course: course, sessionId: course.courseId)
        }
    }

    // MARK: - Map
    private var mapLayer: some View {
        Map(position: $cameraPosition) {
            // 현재 위치
            if let loc = locationService.currentLocation {
                Annotation("현재 위치", coordinate: loc.coordinate) {
                    CurrentLocationPin()
                }
            }

            // 코스 핀들
            ForEach(course.places) { place in
                Annotation(place.placeName, coordinate: place.coordinate) {
                    SessionPlacePin(
                        order: place.order,
                        isVisited: visitedPlaces.contains(place.order),
                        isCurrent: place.order == (currentPlace?.order ?? -1)
                    )
                }
            }

            // 경로선
            if course.places.count >= 2 {
                MapPolyline(coordinates: course.places.map(\.coordinate))
                    .stroke(Color.tteOrange.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
    }

    // MARK: - Top Bar
    private var topBar: some View {
        VStack {
            HStack {
                Button {
                    locationService.stopTracking()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                }

                Spacer()

                if let place = currentPlace {
                    Text("다음: \(place.placeName)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                }

                Spacer()

                Text("\(visitedPlaces.count)/\(course.places.count)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 40)
                    .background(Circle().fill(Color.tteOrange))
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)

            Spacer()
        }
    }

    // MARK: - Bottom Panel
    private var bottomPanel: some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                if let place = currentPlace, !allVisited {
                    // 거리 표시
                    if let distance = locationService.distance(to: place) {
                        HStack(spacing: 6) {
                            Image(systemName: "location.fill")
                                .foregroundColor(.tteOrange)
                                .font(.system(size: 14))
                            Text("\(place.placeName)까지 \(formatDistance(distance))")
                                .font(.system(size: 14))
                                .foregroundColor(.tteDarkGray)
                        }
                    }

                    // 도착했어요 버튼 (수동 도착 처리)
                    Button {
                        showCamera = true
                    } label: {
                        Text("📍 \(place.placeName) 도착! 촬영하기")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color.tteOrange)
                            )
                    }
                }

                if allVisited {
                    Button {
                        showVlog = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "film.fill")
                            Text("Vlog 만들기")
                                .fontWeight(.semibold)
                        }
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.tteOrange, Color.purple.opacity(0.8)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        )
                    }
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.tteBackground)
                    .shadow(color: .black.opacity(0.1), radius: 16, y: -4)
            )
        }
    }

    // MARK: - Helpers
    private func handleCameraDismiss() {
        if let place = currentPlace {
            visitedPlaces.insert(place.order)
        }
        if currentPlaceIndex < course.places.count - 1 {
            currentPlaceIndex += 1
        }
    }

    private func fitMap() {
        guard !course.places.isEmpty else { return }
        let coords = course.places.map(\.coordinate)
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2,
                longitude: ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: ((lats.max() ?? 0) - (lats.min() ?? 0)) * 1.8,
                longitudeDelta: ((lons.max() ?? 0) - (lons.min() ?? 0)) * 1.8
            )
        )
        cameraPosition = .region(region)
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters))m"
        } else {
            return String(format: "%.1fkm", meters / 1000)
        }
    }
}

// MARK: - Current Location Pin
struct CurrentLocationPin: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.2))
                .frame(width: 40, height: 40)
            Circle()
                .fill(Color.blue)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
        }
    }
}

// MARK: - Session Place Pin
struct SessionPlacePin: View {
    let order: Int
    let isVisited: Bool
    let isCurrent: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isVisited ? Color.green : (isCurrent ? Color.tteOrange : Color.gray.opacity(0.6)))
                .frame(width: 32, height: 32)
                .shadow(color: isCurrent ? .tteOrange.opacity(0.5) : .clear, radius: 6)

            if isVisited {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Text("\(order)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
}

// MARK: - Arrival Banner
struct ArrivalBanner: View {
    let placeName: String

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Text("📍")
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(placeName)에 도착했어요!")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Text("탭하여 촬영 시작")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                }
                Spacer()
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.tteOrange)
                    .shadow(color: .tteOrange.opacity(0.4), radius: 8)
            )
            .padding(.horizontal, 20)
            .padding(.top, 60)
            Spacer()
        }
    }
}

#Preview {
    ActiveSessionView(course: Course.mockCourses[0])
}
