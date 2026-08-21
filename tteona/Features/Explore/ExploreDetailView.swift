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
    // 코스 제목(UGC) 번역문 — 도착 전·실패 시에는 원문을 보여준다.
    @State private var translatedTitle: String?
    @State private var showRoomSelect = false
    @State private var showOtherCourseAlert = false
    @State private var showFullMap = false
    /// 근처 추천 식당 상세 — 코스 장소와 같은 시트를 재사용한다
    @State private var selectedNearbyFood: Place?
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
                    CourseSummaryBar(course: course)
                    CourseSourceLabel(course: course)
                    CourseTravelInfo(course: course)
                    placesBlock
                    if course.nearbyFood?.isEmpty == false {
                        Divider()
                        CourseNearbyFoodSection(course: course) { food in
                            selectedNearbyFood = food.asPlace
                        }
                    }
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
            Task { await StatsService.shared.postCourseEvent(.courseOpen, course: course) }
            author = await userService.fetchAuthor(uid: course.authorId)
            // 날씨·경로 조회 뒤로 밀리지 않도록 별도 태스크로 — 도착 전까지는 원문이 보인다.
            Task {
                translatedTitle = await TranslationService.shared.translate(
                    course.courseName, to: LanguageManager.shared.language)
            }
        }
        .fullScreenCover(isPresented: $showFullMap) {
            CourseFullMapView(course: course)
        }
        .sheet(item: $selectedNearbyFood) { place in
            PlaceDetailSheet(place: place)
        }
        .fullScreenCover(isPresented: $showRoomSelect) {
            RoomSelectView(selectedRoomIds: $selectedRoomIds) {
                // 부모(ExploreGridView)가 상세를 닫고 onDismiss에서 세션을 시작한다
                showRoomSelect = false
                onStartSession?(selectedRoomIds)
            }
            .environmentObject(roomService)
        }
        .confirmationDialog(L("detail.otherCourse.title"), isPresented: $showOtherCourseAlert, titleVisibility: .visible) {
            Button(L("detail.otherCourse.resume")) {
                if let saved = sessionStore.loadTodaySession() {
                    onStartSession?(Set(saved.roomIds))
                }
            }
            Button(L("detail.otherCourse.startNew"), role: .destructive) {
                sessionStore.clear()
                selectedRoomIds = []
                showRoomSelect = true
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            if let saved = sessionStore.loadTodaySession() {
                Text(L("detail.otherCourse.message", saved.course.courseName))
            }
        }
        .confirmationDialog(L("report.selectReason"), isPresented: $showReportDialog, titleVisibility: .visible) {
            // 신고 사유는 운영 검토용으로 한국어 원문을 서버에 제출하고, 버튼 표기만 현지화
            ForEach([("report.reason.promo", "영리목적/홍보"),
                     ("report.reason.sexual", "음란성/선정성"),
                     ("report.reason.abuse", "욕설/비하"),
                     ("report.reason.child", "아동 유해 콘텐츠"),
                     ("report.reason.other", "기타")], id: \.1) { key, reason in
                Button(L(key)) { submitCourseReport(reason: reason) }
            }
            Button(L("common.cancel"), role: .cancel) {}
        }
        .alert(L("block.author.title"), isPresented: $showBlockAlert) {
            Button(L("block.action"), role: .destructive) { blockAuthor() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("block.author.message"))
        }
        .alert(L("report.done.title"), isPresented: $showReportSuccessAlert) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(L("report.done.message"))
        }
        .alert(L("block.done.title"), isPresented: $showBlockSuccessAlert) {
            Button(L("common.ok"), role: .cancel) { dismiss() }
        } message: {
            Text(L("block.done.message"))
        }
        .alert(L("common.actionFailed"), isPresented: Binding(get: { actionErrorMessage != nil },
                                              set: { if !$0 { actionErrorMessage = nil } })) {
            Button(L("common.ok"), role: .cancel) {}
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
            .accessibilityLabel(L("detail.shareCourse"))

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
            .accessibilityLabel(isLiked ? L("detail.unlike") : L("detail.like"))

            if !isMyCourse {
                Menu {
                    Button(role: .destructive) {
                        showReportDialog = true
                    } label: {
                        Label(L("detail.reportCourse"), systemImage: "exclamationmark.bubble")
                    }
                    Button {
                        showBlockAlert = true
                    } label: {
                        Label(L("detail.blockAuthor"), systemImage: "person.crop.circle.badge.xmark")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.tte(15, .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.black.opacity(0.35)))
                }
                .accessibilityLabel(L("common.more"))
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
                actionErrorMessage = courseService.errorMessage ?? L("detail.likeFailed")
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
                actionErrorMessage = L("detail.reportFailed")
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
                actionErrorMessage = L("detail.blockFailed")
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
                Text("\(course.tag.emoji) \(course.tag.displayName) · \(course.localizedRegion)")
                    .font(.tte(13, .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text(translatedTitle ?? course.courseName)
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
                    Text(author?.nickname ?? L("detail.traveler"))
                        .font(.tte(15, .semibold))
                        .foregroundColor(.tteDarkGray)
                    if author?.isVerified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.tte(12))
                            .foregroundColor(.tteOrange)
                    }
                }
                Text(L("detail.placesLikes", course.displayPlaces.count, course.likeCount))
                    .font(.tte(13))
                    .foregroundColor(.tteMediumGray)
            }
            Spacer()
        }
    }

    // MARK: - Places

    private var placesBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("detail.courseRoute"))
                .font(.tte(16, .bold))
                .foregroundColor(.tteDarkGray)

            routeMap

            // 연속 중복 장소는 하나로 병합해 표시 (저장 데이터는 원본 유지)
            ForEach(Array(course.displayPlaces.enumerated()), id: \.element.id) { idx, place in
                PlaceCardRow(index: idx, place: place)
            }
        }
    }

    // MARK: - 동선 미니 지도

    private var routeMap: some View {
        GoogleMapView(
            markers: course.displayPlaces.enumerated().map { idx, place in
                GoogleMapMarker(id: place.id, coordinate: place.coordinate, badgeNumber: idx + 1)
            },
            polyline: course.displayPlaces.count >= 2 ? course.displayPlaces.map(\.coordinate) : nil,
            dashedPolyline: true,
            initialCamera: GoogleMapView.fittingCamera(for: course.places.map(\.coordinate)),
            interactive: false
        )
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                Text(L("detail.viewNearby"))
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
            Text(L("detail.followCourse"))
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
                markers: course.displayPlaces.enumerated().map { idx, place in
                    GoogleMapMarker(id: place.id, coordinate: place.coordinate, badgeNumber: idx + 1)
                },
                polyline: course.displayPlaces.count >= 2 ? course.displayPlaces.map(\.coordinate) : nil,
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
