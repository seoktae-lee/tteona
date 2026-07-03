import SwiftUI
import MapKit

struct ExploreDetailView: View {
    let course: Course
    let thumbnailURL: String?
    var onStartSession: ((Set<String>) -> Void)? = nil

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @Environment(\.dismiss) private var dismiss

    @State private var author: AppUser?
    @State private var weather: WeatherInfo?
    @State private var carRoute: RouteInfo?
    @State private var walkRoute: RouteInfo?
    @State private var transitRoute: RouteInfo?
    @State private var isLoadingRoute = true
    @State private var isLoadingTransit = true
    @State private var showRoomSelect = false
    @State private var showOtherCourseAlert = false
    @State private var selectedRoomIds: Set<String> = []

    private let sessionStore = ActiveSessionStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerImage
                VStack(alignment: .leading, spacing: 20) {
                    titleBlock
                    weatherCard
                    transportSection
                    placesBlock
                }
                .padding(20)
                .padding(.bottom, 100)
            }
        }
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .bottom) { startButton }
        .overlay(alignment: .topLeading) { closeButton }
        .navigationBarHidden(true)
        .task {
            author = await userService.fetchAuthor(uid: course.authorId)
            if let first = course.places.first {
                weather = await ExploreInfoService.shared.fetchWeather(lat: first.latitude, lng: first.longitude)
            }
            carRoute  = await ExploreInfoService.shared.computeRoute(places: course.places, transport: .automobile)
            walkRoute = await ExploreInfoService.shared.computeRoute(places: course.places, transport: .walking)
            isLoadingRoute = false
            transitRoute = await ExploreInfoService.shared.computeTransitRoute(places: course.places)
            isLoadingTransit = false
        }
        .fullScreenCover(isPresented: $showRoomSelect) {
            RoomSelectView(selectedRoomIds: $selectedRoomIds) {
                let confirmed = selectedRoomIds
                showRoomSelect = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        onStartSession?(confirmed)
                    }
                }
            }
            .environmentObject(roomService)
        }
        .confirmationDialog("진행 중인 코스가 있어요", isPresented: $showOtherCourseAlert, titleVisibility: .visible) {
            Button("이어서 하기") {
                if let saved = sessionStore.loadTodaySession() {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        onStartSession?(Set(saved.roomIds))
                    }
                }
            }
            Button("새로 시작", role: .destructive) {
                sessionStore.clear()
                selectedRoomIds = []
                showRoomSelect = true
            }
            Button("취소", role: .cancel) {}
        } message: {
            if let saved = sessionStore.loadTodaySession() {
                Text("'\(saved.course.courseName)' 코스가 진행 중이에요.\n이어서 할까요, 아니면 새로 시작할까요?")
            }
        }
    }

    // MARK: - Header

    private var headerImage: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let url = thumbnailURL.flatMap(URL.init) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            DefaultCourseThumbnail()
                        default:
                            Color(UIColor.secondarySystemBackground)
                        }
                    }
                } else {
                    DefaultCourseThumbnail()
                }
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center, endPoint: .bottom
            )
            .frame(height: 300)

            VStack(alignment: .leading, spacing: 6) {
                Text("\(course.tag.emoji) \(course.tag.rawValue) · \(course.region)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text(course.courseName)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(20)
        }
    }

    // MARK: - Title / author

    private var titleBlock: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.tteOrange.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String((author?.nickname ?? "?").prefix(1)))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.tteOrange)
                )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(author?.nickname ?? "여행자")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.tteDarkGray)
                    if author?.isVerified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.tteOrange)
                    }
                }
                Text("장소 \(course.places.count)곳 · ♥ \(course.likeCount)")
                    .font(.system(size: 13))
                    .foregroundColor(.tteMediumGray)
            }
            Spacer()
        }
    }

    // MARK: - 날씨 카드

    private var weatherCard: some View {
        HStack(spacing: 10) {
            Text(weather?.emoji ?? "🌡️").font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text("현재 날씨 (첫 장소 기준)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.tteMediumGray)
                Text(weather.map { "\(Int($0.tempC))° \($0.description)" } ?? "-")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.tteDarkGray)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemBackground)))
    }

    // MARK: - 이동 정보 (자동차 / 대중교통 / 도보)

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("이동 정보")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.tteDarkGray)

            VStack(spacing: 0) {
                transportRow(icon: "car.fill", label: "자동차",
                             route: carRoute, loading: isLoadingRoute)
                Divider().padding(.leading, 44)
                transportRow(icon: "bus.fill", label: "대중교통",
                             route: transitRoute, loading: isLoadingTransit,
                             unavailableText: "정보 없음")
                Divider().padding(.leading, 44)
                transportRow(icon: "figure.walk", label: "도보",
                             route: walkRoute, loading: isLoadingRoute)
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemBackground)))
        }
    }

    private func transportRow(icon: String, label: String, route: RouteInfo?,
                              loading: Bool, unavailableText: String = "-") -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(.tteOrange)
                .frame(width: 24)
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.tteDarkGray)
            Spacer()
            if loading {
                ProgressView().scaleEffect(0.8)
            } else if let route {
                Text("\(route.timeText) · \(route.distanceText)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.tteDarkGray)
            } else {
                Text(unavailableText)
                    .font(.system(size: 14))
                    .foregroundColor(.tteMediumGray)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Places

    private var placesBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("코스 동선")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.tteDarkGray)

            routeMap

            ForEach(Array(course.places.enumerated()), id: \.element.id) { idx, place in
                PlaceCardRow(index: idx, place: place)
            }
        }
    }

    // MARK: - 동선 미니 지도

    private var routeMap: some View {
        Map(initialPosition: .region(fittingRegion), interactionModes: []) {
            if course.places.count >= 2 {
                MapPolyline(coordinates: course.places.map(\.coordinate))
                    .stroke(Color.tteOrange, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1, 6]))
            }
            ForEach(Array(course.places.enumerated()), id: \.element.id) { idx, place in
                Annotation(place.placeName, coordinate: place.coordinate) {
                    ZStack {
                        Circle().fill(Color.tteOrange).frame(width: 24, height: 24)
                        Text("\(idx + 1)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                }
            }
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .allowsHitTesting(false)
    }

    private var fittingRegion: MKCoordinateRegion {
        let lats = course.places.map(\.latitude)
        let lngs = course.places.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLng = lngs.min(), let maxLng = lngs.max() else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLng + maxLng) / 2
        )
        // 핀이 가장자리에 붙지 않도록 1.5배 여유, 장소가 몰려있을 때 최소 스팬 보장
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.5, 0.01),
            longitudeDelta: max((maxLng - minLng) * 1.5, 0.01)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: - Buttons

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.black.opacity(0.35)))
        }
        .padding(.leading, 16)
        .padding(.top, 52)
    }

    private var startButton: some View {
        Button {
            if sessionStore.hasTodaySession {
                showOtherCourseAlert = true
            } else {
                selectedRoomIds = []
                showRoomSelect = true
            }
        } label: {
            Text("이 코스 따라가기")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .background(
            LinearGradient(colors: [.clear, Color.tteBackground], startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .allowsHitTesting(false),
            alignment: .bottom
        )
    }
}

// MARK: - 장소 사진 카드

private struct PlaceCardRow: View {
    let index: Int
    let place: Place

    @State private var photoURL: String?
    @State private var category: String?
    @State private var isLoading = true

    var body: some View {
        HStack(spacing: 12) {
            placePhoto
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(Color.tteOrange).frame(width: 20, height: 20)
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    if let category {
                        Text(category)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.tteOrange)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.tteOrange.opacity(0.12)))
                    }
                }
                Text(place.placeName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.tteDarkGray)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemBackground)))
        .task {
            photoURL = await PlacesPhotoService.shared.photoURL(
                for: place.placeName, latitude: place.latitude, longitude: place.longitude)
            category = await PlacesPhotoService.shared.placeCategory(
                for: place.placeName, latitude: place.latitude, longitude: place.longitude)
            isLoading = false
        }
    }

    @ViewBuilder
    private var placePhoto: some View {
        if isLoading {
            ZStack {
                Color.tteOrange.opacity(0.08)
                ProgressView().scaleEffect(0.8)
            }
        } else if let urlString = photoURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    photoPlaceholder
                default:
                    ZStack {
                        Color.tteOrange.opacity(0.08)
                        ProgressView().scaleEffect(0.8)
                    }
                }
            }
        } else {
            photoPlaceholder
        }
    }

    private var photoPlaceholder: some View {
        ZStack {
            Color.tteOrange.opacity(0.08)
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 24))
                .foregroundColor(.tteOrange.opacity(0.5))
        }
    }
}
