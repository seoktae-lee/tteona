import SwiftUI
import GoogleMaps
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
    @State private var showFullMap = false
    @State private var selectedRoomIds: Set<String> = []
    @State private var isLikeProcessing = false
    @State private var showReportDialog = false
    @State private var showBlockAlert = false
    @State private var showReportSuccessAlert = false
    @State private var showBlockSuccessAlert = false
    @State private var actionErrorMessage: String?

    private let sessionStore = ActiveSessionStore.shared

    private var isLiked: Bool {
        courseService.likedCourseIds.contains(course.courseId)
    }

    private var isMyCourse: Bool {
        course.authorId == authService.currentUser?.uid
    }

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
        .overlay(alignment: .topTrailing) { actionButtons }
        .navigationBarHidden(true)
        .task {
            let uid = authService.currentUser?.uid ?? ""
            await courseService.fetchLikedCourseIds(userId: uid)
            author = await userService.fetchAuthor(uid: course.authorId)
            if let main = course.mainPlace {
                weather = await ExploreInfoService.shared.fetchWeather(lat: main.latitude, lng: main.longitude)
            }
            // 자동차: 서버 실측(한국=카카오모빌리티) 우선, 실패 시 로컬 추정 폴백
            if let serverCar = await ExploreInfoService.shared.computeServerRoute(places: course.places, mode: "car") {
                carRoute = serverCar
            } else {
                carRoute = await ExploreInfoService.shared.computeRoute(places: course.places, transport: .automobile)
            }
            walkRoute = await ExploreInfoService.shared.computeRoute(places: course.places, transport: .walking)
            isLoadingRoute = false
            transitRoute = await ExploreInfoService.shared.computeTransitRoute(places: course.places)
            isLoadingTransit = false
        }
        .fullScreenCover(isPresented: $showFullMap) {
            CourseFullMapView(course: course)
        }
        .fullScreenCover(isPresented: $showRoomSelect) {
            RoomSelectView(selectedRoomIds: $selectedRoomIds) {
                // 부모(ExploreGridView)가 상세를 닫고 onDismiss에서 세션을 시작한다
                showRoomSelect = false
                onStartSession?(selectedRoomIds)
            }
            .environmentObject(roomService)
        }
        .confirmationDialog("진행 중인 코스가 있어요", isPresented: $showOtherCourseAlert, titleVisibility: .visible) {
            Button("이어서 하기") {
                if let saved = sessionStore.loadTodaySession() {
                    onStartSession?(Set(saved.roomIds))
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
        .confirmationDialog("신고 사유를 선택해주세요", isPresented: $showReportDialog, titleVisibility: .visible) {
            ForEach(["영리목적/홍보", "음란성/선정성", "욕설/비하", "아동 유해 콘텐츠", "기타"], id: \.self) { reason in
                Button(reason) { submitCourseReport(reason: reason) }
            }
            Button("취소", role: .cancel) {}
        }
        .alert("작성자 차단", isPresented: $showBlockAlert) {
            Button("차단", role: .destructive) { blockAuthor() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 작성자를 차단하시겠어요? 차단하시면 이 작성자가 등록한 모든 코스와 후기가 숨겨집니다.")
        }
        .alert("신고 완료", isPresented: $showReportSuccessAlert) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("신고가 정상 접수되었습니다. 24시간 이내에 검토 및 삭제 처리됩니다.")
        }
        .alert("차단 완료", isPresented: $showBlockSuccessAlert) {
            Button("확인", role: .cancel) { dismiss() }
        } message: {
            Text("작성자가 차단되었습니다. 목록에서 제외하기 위해 화면을 닫습니다.")
        }
        .alert("처리 실패", isPresented: Binding(get: { actionErrorMessage != nil },
                                              set: { if !$0 { actionErrorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    // MARK: - 좋아요 / 공유 / 신고 / 차단

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                shareCourse()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.tte(15, .semibold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.35)))
            }
            .accessibilityLabel("코스 공유")

            Button {
                toggleLike()
            } label: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.tte(16, .semibold))
                    .foregroundColor(isLiked ? .red : .white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.35)))
            }
            .disabled(isLikeProcessing)
            .accessibilityLabel(isLiked ? "좋아요 취소" : "좋아요")

            if !isMyCourse {
                Menu {
                    Button(role: .destructive) {
                        showReportDialog = true
                    } label: {
                        Label("코스 신고하기", systemImage: "exclamationmark.bubble")
                    }
                    Button {
                        showBlockAlert = true
                    } label: {
                        Label("작성자 차단하기", systemImage: "person.crop.circle.badge.xmark")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.tte(15, .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.black.opacity(0.35)))
                }
                .accessibilityLabel("더 보기")
            }
        }
        .padding(.trailing, 16)
        .padding(.top, 52)
    }

    private func toggleLike() {
        guard !isLikeProcessing else { return }
        Haptics.light()
        isLikeProcessing = true
        Task {
            let uid = authService.currentUser?.uid ?? ""
            do {
                let nickname = userService.currentUser?.nickname ?? ""
                try await courseService.toggleLike(courseId: course.courseId, userId: uid, likerNickname: nickname)
            } catch {
                actionErrorMessage = courseService.errorMessage ?? "좋아요 처리에 실패했어요. 잠시 후 다시 시도해주세요."
            }
            isLikeProcessing = false
        }
    }

    private func shareCourse() {
        CourseShareHelper.share(course: course)
    }

    private func submitCourseReport(reason: String) {
        guard let currentUid = authService.currentUser?.uid else { return }
        Task {
            do {
                try await ReportService.shared.reportContent(
                    reporterId: currentUid,
                    targetType: "course",
                    targetId: course.courseId,
                    targetAuthorId: course.authorId,
                    reason: reason
                )
                showReportSuccessAlert = true
            } catch {
                actionErrorMessage = "신고 접수에 실패했어요. 잠시 후 다시 시도해주세요."
            }
        }
    }

    private func blockAuthor() {
        guard let currentUid = authService.currentUser?.uid else { return }
        Task {
            do {
                try await userService.blockUser(uid: currentUid, blockedUid: course.authorId)
                showBlockSuccessAlert = true
            } catch {
                actionErrorMessage = "차단에 실패했어요. 잠시 후 다시 시도해주세요."
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
                    .font(.tte(13, .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text(course.courseName)
                    .font(.tte(26, .bold))
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
                        .font(.tte(16, .bold))
                        .foregroundColor(.tteOrange)
                )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(author?.nickname ?? "여행자")
                        .font(.tte(15, .semibold))
                        .foregroundColor(.tteDarkGray)
                    if author?.isVerified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.tte(12))
                            .foregroundColor(.tteOrange)
                    }
                }
                Text("장소 \(course.places.count)곳 · ♥ \(course.likeCount)")
                    .font(.tte(13))
                    .foregroundColor(.tteMediumGray)
            }
            Spacer()
        }
    }

    // MARK: - 날씨 카드

    private var weatherCard: some View {
        HStack(spacing: 10) {
            Text(weather?.emoji ?? "🌡️").font(.tte(22))
            VStack(alignment: .leading, spacing: 2) {
                Text("현재 날씨 (첫 장소 기준)")
                    .font(.tte(12, .semibold))
                    .foregroundColor(.tteMediumGray)
                Text(weather.map { "\(Int($0.tempC))° \($0.description)" } ?? "-")
                    .font(.tte(15, .bold))
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
                .font(.tte(16, .bold))
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
                .font(.tte(15))
                .foregroundColor(.tteOrange)
                .frame(width: 24)
            Text(label)
                .font(.tte(15, .medium))
                .foregroundColor(.tteDarkGray)
            Spacer()
            if loading {
                ProgressView().scaleEffect(0.8)
            } else if let route {
                Text("\(route.timeText) · \(route.distanceText)")
                    .font(.tte(15, .semibold))
                    .foregroundColor(.tteDarkGray)
            } else {
                Text(unavailableText)
                    .font(.tte(14))
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
                .font(.tte(16, .bold))
                .foregroundColor(.tteDarkGray)

            routeMap

            ForEach(Array(course.places.enumerated()), id: \.element.id) { idx, place in
                PlaceCardRow(index: idx, place: place)
            }
        }
    }

    // MARK: - 동선 미니 지도

    private var routeMap: some View {
        GoogleMapView(
            markers: course.places.enumerated().map { idx, place in
                GoogleMapMarker(id: place.id, coordinate: place.coordinate, badgeNumber: idx + 1)
            },
            polyline: course.places.count >= 2 ? course.places.map(\.coordinate) : nil,
            dashedPolyline: true,
            initialCamera: GoogleMapView.fittingCamera(for: course.places.map(\.coordinate)),
            interactive: false
        )
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                Text("주변 보기")
            }
            .font(.tte(11, .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.5)))
            .padding(8)
        }
        // 지도 위 탭 → 전체화면 인터랙티브 지도 (제스처 충돌 방지용 투명 오버레이)
        .overlay { Color.clear.contentShape(Rectangle()).onTapGesture { showFullMap = true } }
    }

    // MARK: - Buttons

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.tte(16, .bold))
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
                .font(.tte(17, .bold))
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

// MARK: - 전체화면 코스 지도 (주변 탐색)

private struct CourseFullMapView: View {
    let course: Course
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            GoogleMapView(
                markers: course.places.enumerated().map { idx, place in
                    GoogleMapMarker(id: place.id, coordinate: place.coordinate, badgeNumber: idx + 1)
                },
                polyline: course.places.count >= 2 ? course.places.map(\.coordinate) : nil,
                dashedPolyline: true,
                showsUserLocation: true,
                initialCamera: GoogleMapView.fittingCamera(for: course.places.map(\.coordinate)),
                interactive: true
            )
            .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.tte(16, .bold))
                    .foregroundColor(.tteDarkGray)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white))
                    .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
            }
            .padding(.leading, 16)
            .padding(.top, 52)
        }
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
                            .font(.tte(11, .bold))
                            .foregroundColor(.white)
                    }
                    if let category {
                        Text(category)
                            .font(.tte(11, .semibold))
                            .foregroundColor(.tteOrange)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.tteOrange.opacity(0.12)))
                    }
                }
                Text(place.placeName)
                    .font(.tte(15, .semibold))
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
                .font(.tte(24))
                .foregroundColor(.tteOrange.opacity(0.5))
        }
    }
}
