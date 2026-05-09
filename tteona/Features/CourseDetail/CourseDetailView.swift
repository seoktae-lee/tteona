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

    private let sessionStore = ActiveSessionStore.shared

    private var isLiked: Bool {
        courseService.likedCourseIds.contains(course.courseId)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                mapLayer
                bottomSheet
            }
            .ignoresSafeArea(edges: .bottom)
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
                        }
                    }
                }
            }
        }
        .task {
            let uid = authService.currentUser?.uid ?? ""
            await courseService.fetchLikedCourseIds(userId: uid)
            fitMapToCourse()
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
    }

    // MARK: - Map
    private var mapLayer: some View {
        Map(position: $cameraPosition) {
            ForEach(course.places) { place in
                Annotation(place.placeName, coordinate: place.coordinate) {
                    PlacePin(order: place.order)
                }
            }

            if course.places.count >= 2 {
                MapPolyline(coordinates: course.places.map(\.coordinate))
                    .stroke(Color.tteOrange, lineWidth: 2.5)
            }
        }
        .mapStyle(.standard)
    }

    // MARK: - Bottom Sheet
    private var bottomSheet: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color(UIColor.tertiaryLabel))
                .frame(width: 36, height: 5)
                .padding(.vertical, 12)

            HStack {
                VStack(alignment: .leading, spacing: 6) {
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

            Text("장소 목록")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.tteDarkGray)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(course.places.sorted(by: { $0.order < $1.order })) { place in
                        PlaceRow(place: place, isLast: place.order == course.places.count)
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(maxHeight: 200)

            startButton
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 36)
        }
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.tteBackground)
                .shadow(color: .black.opacity(0.1), radius: 16, y: -4)
        )
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
                    try await courseService.toggleLike(courseId: course.courseId, userId: uid)
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
        var region = MKCoordinateRegion()

        if course.places.count == 1 {
            region = MKCoordinateRegion(
                center: course.places[0].coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        } else {
            let lats = course.places.map(\.latitude)
            let lons = course.places.map(\.longitude)
            let minLat = lats.min()!, maxLat = lats.max()!
            let minLon = lons.min()!, maxLon = lons.max()!
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: (minLat + maxLat) / 2,
                    longitude: (minLon + maxLon) / 2
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: (maxLat - minLat) * 1.6,
                    longitudeDelta: (maxLon - minLon) * 1.6
                )
            )
        }
        cameraPosition = .region(region)
    }
}

// MARK: - Place Pin
struct PlacePin: View {
    let order: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.tteOrange)
                .frame(width: 32, height: 32)
                .shadow(color: .tteOrange.opacity(0.4), radius: 4)
            Text("\(order)")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Place Row
struct PlaceRow: View {
    let place: Place
    let isLast: Bool

    var body: some View {
        HStack(spacing: 14) {
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

            VStack(alignment: .leading, spacing: 2) {
                Text(place.placeName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.tteDarkGray)
                Text("위도 \(String(format: "%.4f", place.latitude))  경도 \(String(format: "%.4f", place.longitude))")
                    .font(.system(size: 12))
                    .foregroundColor(.tteMediumGray)
            }
            .padding(.vertical, 12)

            Spacer()
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
