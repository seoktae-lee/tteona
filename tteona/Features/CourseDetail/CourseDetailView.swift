import SwiftUI
import GoogleMaps

struct CourseDetailView: View {
    let course: Course
    var onStartSession: ((Set<String>) -> Void)? = nil
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @Environment(\.dismiss) private var dismiss
    @State private var showRoomSelect = false
    @State private var showOtherCourseAlert = false
    @State private var isLikeProcessing = false
    @State private var showLikeErrorAlert = false
    @State private var likeErrorMessage: String = ""
    @State private var selectedRoomIds: Set<String> = []
    @State private var selectedPlaceIndex: Int = 0
    @State private var courseAuthor: AppUser?
    // 코스 제목(UGC) 번역문 — 도착 전·실패 시에는 원문을 보여준다.
    @State private var translatedTitle: String?
    @State private var selectedPlaceForDetail: Place?
    /// 코스 전체 동선을 전체 화면 지도로 본다.
    /// 예전에는 상세 위쪽 260pt를 지도가 늘 차지했는데, 그만큼 목록이 밀려
    /// 코스 정보가 한눈에 안 들어왔다. 필요할 때만 펼치도록 바꿨다.
    @State private var showFullMap = false
    @State private var showReportAlert = false
    @State private var showBlockAlert = false
    @State private var showReportSuccessAlert = false
    @State private var showBlockSuccessAlert = false
    @State private var actionErrorMessage: String?
    // 코스 이름/태그 편집 (작성자)
    @State private var showEditSheet = false
    @State private var editName = ""
    @State private var editTag: CourseTag = .friends
    @State private var localName: String?   // 편집 후 로컬 반영

    private let sessionStore = ActiveSessionStore.shared

    private var isLiked: Bool {
        courseService.likedCourseIds.contains(course.courseId)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                contentSection
                startButton
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                    .background(Color.tteBackground)
            }
            .navigationTitle(localName ?? translatedTitle ?? course.courseName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.tte(16, .medium))
                            .foregroundColor(.tteDarkGray)
                    }
                    .accessibilityLabel(L("common.close"))
                }

                ToolbarItem(placement: .topBarTrailing) {
                    // 아이콘은 셋(지도·하트·⋯)까지만 둔다. 넷이 되면 코스명이 잘려
                    // "현충원 벚꽃과…"처럼 무슨 코스인지 알 수 없게 된다.
                    // 공유는 자주 쓰는 동작이 아니라 ⋯ 메뉴 안으로 넣었다.
                    HStack(spacing: 16) {
                        Button {
                            Haptics.light()
                            showFullMap = true
                        } label: {
                            Image(systemName: "map")
                                .font(.tte(16, .medium))
                                .foregroundColor(.tteDarkGray)
                        }
                        .accessibilityLabel(L("coursedetail.viewMap"))
                        likeButton
                        if course.authorId == authService.currentUser?.uid {
                            Menu {
                                Button {
                                    shareCourse()
                                } label: {
                                    Label(L("detail.shareCourse"), systemImage: "square.and.arrow.up")
                                }
                                Button {
                                    editName = localName ?? course.courseName
                                    editTag = course.tag
                                    showEditSheet = true
                                } label: {
                                    Label(L("coursedetail.edit"), systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    Task {
                                        try? await courseService.deleteCourse(course)
                                        dismiss()
                                    }
                                } label: {
                                    Label(L("coursedetail.delete"), systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.tte(16, .medium))
                                    .foregroundColor(.tteDarkGray)
                            }
                        } else {
                            Menu {
                                Button {
                                    shareCourse()
                                } label: {
                                    Label(L("detail.shareCourse"), systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    showReportAlert = true
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
                                    .font(.tte(16, .medium))
                                    .foregroundColor(.tteDarkGray)
                            }
                        }
                    }
                }
            }
        }
        .task {
            Task { await StatsService.shared.postCourseEvent(.courseOpen, course: course) }
            let uid = authService.currentUser?.uid ?? ""
            await courseService.fetchLikedCourseIds(userId: uid)
            courseAuthor = await userService.fetchAuthor(uid: course.authorId)
            translatedTitle = await TranslationService.shared.translate(
                course.courseName, to: LanguageManager.shared.language)
        }
        .fullScreenCover(isPresented: $showRoomSelect) {
            RoomSelectView(selectedRoomIds: $selectedRoomIds) {
                // 부모가 상세 시트를 닫고 onDismiss에서 세션을 시작한다
                showRoomSelect = false
                onStartSession?(selectedRoomIds)
            }
            .environmentObject(roomService)
        }
        .sheet(isPresented: $showEditSheet) {
            CourseEditSheet(name: $editName, tag: $editTag) {
                let newName = editName.trimmingCharacters(in: .whitespaces)
                guard !newName.isEmpty else { return }
                showEditSheet = false
                Task {
                    try? await courseService.updateCourseInfo(courseId: course.courseId, name: newName, tag: editTag)
                    localName = newName
                    // 새 이름 다시 번역
                    translatedTitle = await TranslationService.shared.translate(newName, to: LanguageManager.shared.language)
                }
            }
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
        .alert(L("coursedetail.likeError"), isPresented: $showLikeErrorAlert) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(likeErrorMessage)
        }
        .sheet(item: $selectedPlaceForDetail) { place in
            PlaceDetailSheet(place: place)
        }
        .fullScreenCover(isPresented: $showFullMap) {
            NavigationStack {
                mapLayer
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(L("coursedetail.mapTitle"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { showFullMap = false } label: {
                                Image(systemName: "xmark")
                                    .font(.tte(16, .medium))
                                    .foregroundColor(.tteDarkGray)
                            }
                            .accessibilityLabel(L("common.close"))
                        }
                    }
            }
        }
        .confirmationDialog(L("report.selectReason"), isPresented: $showReportAlert, titleVisibility: .visible) {
            // 신고 사유는 운영 검토용으로 한국어 원문을 서버에 제출하고, 버튼 표기만 현지화
            ForEach([("report.reason.promo", "영리목적/홍보"),
                     ("report.reason.sexual", "음란성/선정성"),
                     ("report.reason.abuse", "욕설/비하"),
                     ("report.reason.child", "아동 유해 콘텐츠"),
                     ("report.reason.other", "기타")], id: \.1) { key, reason in
                Button(L(key)) {
                    submitCourseReport(reason: reason)
                }
            }
            Button(L("common.cancel"), role: .cancel) {}
        }
        .alert(L("block.author.title"), isPresented: $showBlockAlert) {
            Button(L("block.action"), role: .destructive) {
                blockAuthor()
            }
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
            Button(L("common.ok"), role: .cancel) {
                dismiss()
            }
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

    // MARK: - Map
    private var mapLayer: some View {
        let sorted = sortedPlaces
        let selectedOrder = selectedPlaceIndex < sorted.count ? sorted[selectedPlaceIndex].order : -1

        // 코스 장소는 번호 핀, 근처 맛집은 포크 핀 — 한 지도에 있어도 역할이 갈린다.
        // 맛집은 코스에 포함된 곳이 아니므로 폴리라인(동선)에는 넣지 않는다.
        var markers = sorted.map { place in
            GoogleMapMarker(id: place.id, coordinate: place.coordinate,
                            badgeNumber: place.order,
                            highlighted: place.order == selectedOrder)
        }
        markers += (course.nearbyFood ?? []).map { food in
            GoogleMapMarker(id: "food-\(food.name)", coordinate: food.coordinate,
                            label: food.name, symbolName: "fork.knife")
        }

        return GoogleMapView(
            markers: markers,
            polyline: sorted.count >= 2 ? sorted.map(\.coordinate) : nil,
            initialCamera: GoogleMapView.fittingCamera(for: sorted.map(\.coordinate)),
            onMarkerTap: { id in
                guard id.hasPrefix("food-") else { return }
                let name = String(id.dropFirst(5))
                if let food = course.nearbyFood?.first(where: { $0.name == name }) {
                    showFullMap = false
                    // 전체화면 지도를 먼저 닫아야 상세 시트가 그 위에 겹치지 않는다
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        selectedPlaceForDetail = food.asPlace
                    }
                }
            }
        )
    }

    // 표시 전용 — 연속 중복 장소 병합본 (저장·Vlog 합성은 course.places 원본 사용)
    private var sortedPlaces: [Place] {
        course.displayPlaces
    }

    // MARK: - Content Section
    private var contentSection: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if let author = courseAuthor, author.isVerified {
                    HStack(spacing: 5) {
                        VerifiedBadge(creatorLabel: author.creatorLabel)
                        Text(L("coursedetail.creatorCourse"))
                            .font(.tte(11))
                            .foregroundColor(.tteOrange.opacity(0.8))
                        Spacer()
                        Text(author.nickname)
                            .font(.tte(11, .medium))
                            .foregroundColor(.tteOrange.opacity(0.8))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.tteOrange.opacity(0.06))
                }

                CourseSourceLabel(course: course)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 7)

                if !sortedPlaces.isEmpty {
                    VStack(spacing: 8) {
                        TabView(selection: $selectedPlaceIndex) {
                            ForEach(Array(sortedPlaces.enumerated()), id: \.offset) { index, place in
                                PlacePagePhoto(place: place, onDetail: { selectedPlaceForDetail = place })
                                    .tag(index)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 20)

                        if sortedPlaces.count > 1 {
                            HStack(spacing: 5) {
                                ForEach(0..<sortedPlaces.count, id: \.self) { i in
                                    Circle()
                                        .fill(i == selectedPlaceIndex ? Color.tteOrange : Color(UIColor.tertiaryLabel))
                                        .frame(
                                            width: i == selectedPlaceIndex ? 7 : 5,
                                            height: i == selectedPlaceIndex ? 7 : 5
                                        )
                                        .animation(.easeInOut(duration: 0.2), value: selectedPlaceIndex)
                                }
                            }
                        }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                }

                HStack {
                    HStack(spacing: 6) {
                        Text(course.tag.displayName)
                            .font(.tte(12, .medium))
                            .foregroundColor(.tteOrange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.tteOrange.opacity(0.12)))

                        Text(course.localizedRegion)
                            .font(.tte(12))
                            .foregroundColor(.tteMediumGray)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color(UIColor.tertiarySystemBackground)))
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .foregroundColor(isLiked ? .red : .tteMediumGray)
                            .font(.tte(14))
                        Text("\(course.likeCount)")
                            .font(.tte(14))
                            .foregroundColor(.tteMediumGray)
                    }
                }
                .padding(.horizontal, 20)

                CourseSummaryBar(course: course)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                .padding(.vertical, 10)

                // 지도 입구를 여기에도 둔다. 툴바 아이콘 하나만으로는 눈에 띄지 않아
                // "코스가 어디인지" 확인할 방법이 없는 것처럼 느껴진다.
                HStack {
                    Text(L("coursedetail.placeList"))
                        .font(.tte(14, .semibold))
                        .foregroundColor(.tteDarkGray)
                    Spacer()
                    Button {
                        Haptics.light()
                        showFullMap = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "map")
                                .font(.tte(11))
                            Text(L("coursedetail.viewMap"))
                                .font(.tte(12, .medium))
                        }
                        .foregroundColor(.tteOrange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.tteOrange.opacity(0.10)))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

                Divider().padding(.horizontal, 20)

                VStack(spacing: 0) {
                    ForEach(Array(sortedPlaces.enumerated()), id: \.offset) { index, place in
                        PlaceRow(place: place, isLast: index == sortedPlaces.count - 1)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedPlaceForDetail = place }
                    }
                }
                .padding(.horizontal, 20)

                extraInfoSection

            }
        }
        .background(Color.tteBackground)
    }

    /// 근처 추천 식당 + 날씨·이동 정보.
    /// 두 화면(탐색·지도)이 같은 것을 보여주도록 공용 조각(CourseDetailParts)을 쓴다.
    @ViewBuilder
    private var extraInfoSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if course.nearbyFood?.isEmpty == false {
                Divider()
                CourseNearbyFoodSection(course: course) { food in
                    selectedPlaceForDetail = food.asPlace
                }
            }
            Divider()
            CourseTravelInfo(course: course)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var startButton: some View {
        Button {
            if let saved = sessionStore.loadTodaySession() {
                if saved.course.courseId == course.courseId {
                    // 같은 코스 → 부모가 시트를 닫고 onDismiss에서 세션을 연다
                    onStartSession?(Set(saved.roomIds))
                } else {
                    // 다른 코스 진행 중 → 막기
                    showOtherCourseAlert = true
                }
            } else {
                selectedRoomIds = []
                showRoomSelect = true
            }
        } label: {
            Text(L("coursedetail.goWithCourse"))
                .font(.tte(17, .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.tteOrange)
                )
        }
    }

    private var likeButton: some View {
        Button {
            guard !isLikeProcessing else { return }
            Haptics.light()
            isLikeProcessing = true
            Task {
                let uid = authService.currentUser?.uid ?? ""
                do {
                    let nickname = userService.currentUser?.nickname ?? ""
                    try await courseService.toggleLike(courseId: course.courseId, userId: uid, likerNickname: nickname)
                } catch {
                    likeErrorMessage = courseService.errorMessage ?? error.localizedDescription
                    showLikeErrorAlert = true
                }
                isLikeProcessing = false
            }
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.tte(20))
                .foregroundColor(isLiked ? .red : .tteDarkGray)
        }
        .disabled(isLikeProcessing)
        .accessibilityLabel(isLiked ? L("detail.unlike") : L("detail.like"))
    }

    private func shareCourse() {
        CourseShareHelper.share(course: course)
    }

}

// MARK: - Place Page Photo (스와이프 갤러리용)
struct PlacePagePhoto: View {
    let place: Place
    var onDetail: (() -> Void)? = nil
    @State private var photoURL: String?
    @State private var isLoading = true

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if isLoading {
                    loadingPlaceholder
                } else if let urlStr = photoURL, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        case .failure:
                            failurePlaceholder
                        default:
                            loadingPlaceholder
                        }
                    }
                } else {
                    failurePlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            LinearGradient(
                colors: [.clear, .black.opacity(0.5)],
                startPoint: .center,
                endPoint: .bottom
            )

            HStack(alignment: .bottom) {
                Text("\(place.order). \(place.placeName)")
                    .font(.tte(14, .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                if let onDetail {
                    Button(action: onDetail) {
                        HStack(spacing: 4) {
                            Image(systemName: "photo.stack.fill")
                                .font(.tte(10))
                            Text(L("coursedetail.photosReviews"))
                                .font(.tte(11, .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                    }
                }
            }
            .padding(14)
        }
        .task {
            photoURL = await PlacesPhotoService.shared.photoURL(
                for: place.placeName, latitude: place.latitude, longitude: place.longitude)
            isLoading = false
        }
    }

    private var loadingPlaceholder: some View {
        ZStack {
            Color.tteOrange.opacity(0.06)
            Image("tteona-icon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72)
            ProgressView()
                .tint(Color.white)
                .scaleEffect(1.2)
                .offset(y: -7)
        }
    }

    private var failurePlaceholder: some View {
        ZStack {
            Color.tteOrange.opacity(0.06)
            Image("tteona-no-image")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 90)
        }
    }
}

// MARK: - Place Pin
struct PlacePin: View {
    let order: Int
    var isSelected: Bool = false

    var body: some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(Color.tteOrange.opacity(0.25))
                    .frame(width: 50, height: 50)
            }
            Circle()
                .fill(Color.tteOrange)
                .frame(width: isSelected ? 40 : 32, height: isSelected ? 40 : 32)
                .shadow(color: .tteOrange.opacity(isSelected ? 0.6 : 0.4), radius: isSelected ? 8 : 4)
            Text("\(order)")
                .font(.system(size: isSelected ? 16 : 13, weight: .bold))
                .foregroundColor(.white)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
    }
}

// MARK: - Place Row
struct PlaceRow: View {
    let place: Place
    let isLast: Bool
    @State private var photoURL: String?
    @State private var category: String?
    @State private var isLoading = true

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.tteOrange)
                    .frame(width: 10, height: 10)
                if !isLast {
                    Rectangle()
                        .fill(Color.tteOrange.opacity(0.3))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)

            Group {
                if isLoading {
                    rowLoadingPlaceholder
                } else if let urlStr = photoURL, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        case .failure:
                            rowFailurePlaceholder
                        default:
                            rowLoadingPlaceholder
                        }
                    }
                } else {
                    rowFailurePlaceholder
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(place.placeName)
                    .font(.tte(15, .medium))
                    .foregroundColor(.tteDarkGray)
                if let category {
                    Text(category)
                        .font(.tte(12))
                        .foregroundColor(.tteMediumGray)
                }
            }
            .padding(.vertical, 12)

            Spacer()

            HStack(spacing: 3) {
                Image(systemName: "star.fill")
                    .font(.tte(9))
                Text(L("coursedetail.viewReviews"))
                    .font(.tte(11, .medium))
                Image(systemName: "chevron.right")
                    .font(.tte(9, .semibold))
            }
            .foregroundColor(.tteOrange)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.tteOrange.opacity(0.1)))
        }
        .task {
            async let photo = PlacesPhotoService.shared.photoURL(
                for: place.placeName, latitude: place.latitude, longitude: place.longitude)
            async let cat = PlacesPhotoService.shared.placeCategory(
                for: place.placeName, latitude: place.latitude, longitude: place.longitude)
            (photoURL, category) = await (photo, cat)
            isLoading = false
        }
    }

    private var rowLoadingPlaceholder: some View {
        ZStack {
            Color.tteOrange.opacity(0.06)
            Image("tteona-icon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(8)
            ProgressView()
                .tint(Color.white)
                .scaleEffect(0.8)
                .offset(y: -4)
        }
    }

    private var rowFailurePlaceholder: some View {
        ZStack {
            Color.tteOrange.opacity(0.06)
            Image("tteona-no-image")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(4)
        }
    }
}

// MARK: - 코스 이름/태그 편집 시트 (작성자)
struct CourseEditSheet: View {
    @Binding var name: String
    @Binding var tag: CourseTag
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false
    @State private var blocked = false

    private var valid: Bool {
        let t = name.trimmingCharacters(in: .whitespaces)
        return t.count >= 1 && t.count <= 20
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("impromptu.courseName"))
                        .font(.tte(14, .medium)).foregroundColor(.tteMediumGray)
                    TteTextField(placeholder: L("impromptu.courseName.placeholder"), text: $name)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("impromptu.tag"))
                        .font(.tte(14, .medium)).foregroundColor(.tteMediumGray)
                    HStack(spacing: 10) {
                        ForEach(CourseTag.allCases, id: \.self) { t in
                            Button { tag = t } label: {
                                Text(t.displayName)
                                    .font(.tte(14, .medium))
                                    .foregroundColor(tag == t ? .white : .tteDarkGray)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Capsule().fill(tag == t ? Color.tteOrange : Color(UIColor.secondarySystemBackground)))
                            }
                        }
                    }
                }
                if blocked {
                    Text(L("onboarding.nickname.inappropriate"))
                        .font(.tte(12)).foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
                Button {
                    Task { await validateAndSave() }
                } label: {
                    ZStack {
                        if checking { ProgressView().tint(.white) }
                        else { Text(L("common.save")).font(.tte(17, .semibold)) }
                    }
                    .foregroundColor(.white).frame(maxWidth: .infinity).frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 14).fill(valid ? Color.tteOrange : Color.gray.opacity(0.4)))
                }
                .disabled(!valid || checking)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 20).padding(.top, 16)
            .navigationTitle(L("coursedetail.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.cancel")) { dismiss() }.foregroundColor(.tteMediumGray)
                }
            }
        }
        .presentationDetents([.height(360)])
    }

    private func validateAndSave() async {
        checking = true; blocked = false
        defer { checking = false }
        let t = name.trimmingCharacters(in: .whitespaces)
        // 코스명도 UGC라 부적절 표현 검사 (서버 실패 시 통과)
        guard await StatsService.shared.isTextAllowed(t) else { blocked = true; return }
        onSave()
    }
}

#Preview {
    CourseDetailView(course: Course.mockCourses[0])
        .environmentObject(AuthService())
        .environmentObject(CourseService())
        .environmentObject(UserService())
        .environmentObject(RoomService())
}
