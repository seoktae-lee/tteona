import SwiftUI
import MapKit

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
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isLikeProcessing = false
    @State private var showLikeErrorAlert = false
    @State private var likeErrorMessage: String = ""
    @State private var selectedRoomIds: Set<String> = []
    @State private var selectedPlaceIndex: Int = 0
    @State private var courseAuthor: AppUser?
    @State private var selectedPlaceForDetail: Place?
    @State private var showReportAlert = false
    @State private var showBlockAlert = false
    @State private var showReportSuccessAlert = false
    @State private var showBlockSuccessAlert = false

    private let sessionStore = ActiveSessionStore.shared

    private var isLiked: Bool {
        courseService.likedCourseIds.contains(course.courseId)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapLayer
                    .frame(height: 260)
                contentSection
                startButton
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                    .background(Color.tteBackground)
            }
            .navigationTitle(course.courseName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.tteDarkGray)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        shareButton
                        likeButton
                        if course.authorId == authService.currentUser?.uid {
                            Menu {
                                Button(role: .destructive) {
                                    Task {
                                        try? await courseService.deleteCourse(course)
                                        dismiss()
                                    }
                                } label: {
                                    Label("코스 삭제", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.tteDarkGray)
                            }
                        } else {
                            Menu {
                                Button(role: .destructive) {
                                    showReportAlert = true
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
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.tteDarkGray)
                            }
                        }
                    }
                }
            }
        }
        .task {
            let uid = authService.currentUser?.uid ?? ""
            await courseService.fetchLikedCourseIds(userId: uid)
            fitMapToCourse()
            courseAuthor = await userService.fetchAuthor(uid: course.authorId)
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
        .alert("좋아요 오류", isPresented: $showLikeErrorAlert) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(likeErrorMessage)
        }
        .sheet(item: $selectedPlaceForDetail) { place in
            PlaceDetailSheet(place: place)
        }
        .confirmationDialog("신고 사유를 선택해주세요", isPresented: $showReportAlert, titleVisibility: .visible) {
            ForEach(["영리목적/홍보", "음란성/선정성", "욕설/비하", "아동 유해 콘텐츠", "기타"], id: \.self) { reason in
                Button(reason) {
                    submitCourseReport(reason: reason)
                }
            }
            Button("취소", role: .cancel) {}
        }
        .alert("작성자 차단", isPresented: $showBlockAlert) {
            Button("차단", role: .destructive) {
                blockAuthor()
            }
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
            Button("확인", role: .cancel) {
                dismiss()
            }
        } message: {
            Text("작성자가 차단되었습니다. 목록에서 제외하기 위해 화면을 닫습니다.")
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
            } catch {}
        }
    }

    private func blockAuthor() {
        guard let currentUid = authService.currentUser?.uid else { return }
        Task {
            do {
                try await userService.blockUser(uid: currentUid, blockedUid: course.authorId)
                showBlockSuccessAlert = true
            } catch {}
        }
    }

    // MARK: - Map
    private var mapLayer: some View {
        let sorted = course.places.sorted { $0.order < $1.order }
        let selectedOrder = selectedPlaceIndex < sorted.count ? sorted[selectedPlaceIndex].order : -1

        return Map(position: $cameraPosition) {
            ForEach(course.places) { place in
                Annotation(place.placeName, coordinate: place.coordinate) {
                    PlacePin(order: place.order, isSelected: place.order == selectedOrder)
                }
            }
            if course.places.count >= 2 {
                MapPolyline(coordinates: course.places.map(\.coordinate))
                    .stroke(Color.tteOrange, lineWidth: 2.5)
            }
        }
        .mapStyle(.standard)
    }

    private var sortedPlaces: [Place] {
        course.places.sorted { $0.order < $1.order }
    }

    private var uniqueSortedPlaces: [Place] {
        var seen = Set<String>()
        return sortedPlaces.filter { seen.insert($0.placeName).inserted }
    }

    // MARK: - Content Section
    private var contentSection: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if let author = courseAuthor, author.isVerified {
                    HStack(spacing: 5) {
                        VerifiedBadge(creatorLabel: author.creatorLabel)
                        Text("크리에이터 코스")
                            .font(.system(size: 11))
                            .foregroundColor(.tteOrange.opacity(0.8))
                        Spacer()
                        Text(author.nickname)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.tteOrange.opacity(0.8))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.tteOrange.opacity(0.06))
                }

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
                        Text(course.tag.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.tteOrange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.tteOrange.opacity(0.12)))

                        Text(course.region)
                            .font(.system(size: 12))
                            .foregroundColor(.tteMediumGray)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color(UIColor.tertiarySystemBackground)))
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .foregroundColor(isLiked ? .red : .tteMediumGray)
                            .font(.system(size: 14))
                        Text("\(course.likeCount)")
                            .font(.system(size: 14))
                            .foregroundColor(.tteMediumGray)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                Text("장소 목록")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.tteDarkGray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                Divider().padding(.horizontal, 20)

                VStack(spacing: 0) {
                    ForEach(Array(uniqueSortedPlaces.enumerated()), id: \.offset) { index, place in
                        PlaceRow(place: place, isLast: index == uniqueSortedPlaces.count - 1)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedPlaceForDetail = place }
                    }
                }
                .padding(.horizontal, 20)

            }
        }
        .background(Color.tteBackground)
    }

    private var startButton: some View {
        Button {
            if let saved = sessionStore.loadTodaySession() {
                if saved.course.courseId == course.courseId {
                    // 같은 코스 → MainView에서 직접 열기
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        onStartSession?(Set(saved.roomIds))
                    }
                } else {
                    // 다른 코스 진행 중 → 막기
                    showOtherCourseAlert = true
                }
            } else {
                selectedRoomIds = []
                showRoomSelect = true
            }
        } label: {
            Text("이 코스로 떠나기")
                .font(.system(size: 17, weight: .semibold))
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
                .font(.system(size: 20))
                .foregroundColor(isLiked ? .red : .tteDarkGray)
        }
        .disabled(isLikeProcessing)
    }

    private var shareButton: some View {
        Button {
            shareCourse()
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.tteDarkGray)
        }
    }

    private func shareCourse() {
        CourseShareHelper.share(course: course)
    }

    private func fitMapToCourse() {
        guard !course.places.isEmpty else { return }
        if course.places.count == 1 {
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: course.places[0].latitude + 0.004, longitude: course.places[0].longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
            ))
            return
        }
        let lats = course.places.map(\.latitude)
        let lons = course.places.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let latDelta = max((maxLat - minLat) * 1.7, 0.01)
        let lonDelta = max((maxLon - minLon) * 1.7, 0.01)
        cameraPosition = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        ))
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                if let onDetail {
                    Button(action: onDetail) {
                        HStack(spacing: 4) {
                            Image(systemName: "photo.stack.fill")
                                .font(.system(size: 10))
                            Text("사진·리뷰")
                                .font(.system(size: 11, weight: .semibold))
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
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.tteDarkGray)
                if let category {
                    Text(category)
                        .font(.system(size: 12))
                        .foregroundColor(.tteMediumGray)
                }
            }
            .padding(.vertical, 12)

            Spacer()

            HStack(spacing: 3) {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                Text("리뷰 보기")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
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

#Preview {
    CourseDetailView(course: Course.mockCourses[0])
        .environmentObject(AuthService())
        .environmentObject(CourseService())
        .environmentObject(UserService())
        .environmentObject(RoomService())
}
