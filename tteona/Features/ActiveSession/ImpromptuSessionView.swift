import SwiftUI
import MapKit
import CoreLocation

struct ImpromptuSessionView: View {
    var roomId: String? = nil
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var roomService: RoomService
    @StateObject private var locationService = LocationService()
    @Environment(\.dismiss) private var dismiss

    private let activityManager = TodaySessionActivityManager.shared

    @State private var capturedPlaces: [Place] = []
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var isResolvingLocation = false
    @State private var isSavingClip = false
    @State private var resolvedLocation: CLLocation? = nil
    @State private var pendingPlace: Place? = nil
    @State private var locationTask: Task<Void, Never>? = nil
    @State private var showPlacePicker = false
    @State private var showCamera = false
    @State private var showEndAlert = false
    @State private var showVlog = false
    @State private var showSaveCourse = false
    @State private var courseName = ""
    @State private var selectedTag: CourseTag = .friends
    @State private var generatedCourse: Course? = nil

    private var uid: String { authService.currentUser?.uid ?? "" }
    private var sessionId: String { "free_\(uid)" }
    private var nickname: String { userService.currentUser?.nickname ?? "멤버" }

    var body: some View {
        ZStack {
            mapLayer
            topBar
            bottomPanel
            if isSavingClip {
                savingOverlay
            }
        }
        .ignoresSafeArea()
        .task {
            locationService.requestPermission()
            locationService.startContinuousUpdates()
            activityManager.start()
            if let rid = roomId {
                roomService.postFeed(roomId: rid, type: .freeTripStart,
                                     userId: uid, nickname: nickname,
                                     courseId: "free", courseName: "나의 오늘")
            }
        }
        .onDisappear {
            locationService.stopContinuousUpdates()
            activityManager.end()
            locationTask?.cancel()
        }
        // 1단계: 장소 선택
        .sheet(isPresented: $showPlacePicker, onDismiss: {
            guard pendingPlace != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                showCamera = true
            }
        }) {
            if let loc = resolvedLocation {
                PlacePickerView(location: loc) { name in
                    let existingOrder = capturedPlaces.first(where: { $0.placeName == name })?.order
                    let order = existingOrder ?? (capturedPlaces.count + 1)
                    pendingPlace = Place(
                        order: order,
                        placeName: name,
                        latitude: loc.coordinate.latitude,
                        longitude: loc.coordinate.longitude
                    )
                    showPlacePicker = false
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
            }
        }
        // 2단계: 카메라
        .fullScreenCover(isPresented: $showCamera) {
            if let place = pendingPlace {
                CameraView(
                    place: place,
                    sessionId: sessionId,
                    onSaved: {
                        isSavingClip = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            handleCameraSaved()
                            isSavingClip = false
                        }
                    },
                    onClose: {
                        pendingPlace = nil
                    }
                )
            }
        }
        .fullScreenCover(isPresented: $showVlog) {
            if let course = generatedCourse {
                VlogGenerationView(course: course, sessionId: sessionId)
            }
        }
        .sheet(isPresented: $showSaveCourse) {
            saveCourseSheet
        }
        .alert("오늘을 마칠까요?", isPresented: $showEndAlert) {
            Button("Vlog 만들기") {
                buildCourseAndEnd(saveToFirestore: false)
                showVlog = true
            }
            Button("코스로 저장 후 Vlog 만들기") {
                showSaveCourse = true
            }
            Button("그냥 종료", role: .destructive) {
                postEndFeed()
                activityManager.end()
                dismiss()
            }
            Button("계속 기록", role: .cancel) {}
        } message: {
            Text("방문한 장소 \(capturedPlaces.count)곳으로 기록이 남아있어요.")
        }
    }

    // MARK: - 저장 중 오버레이
    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.3)
                    .tint(.white)
                Text("영상 보관 중...")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.black.opacity(0.7))
            )
        }
        .transition(.opacity)
    }

    // MARK: - Map
    private var mapLayer: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()
            ForEach(capturedPlaces) { place in
                Annotation(place.placeName, coordinate: place.coordinate) {
                    FreeSessionPin(order: place.order)
                }
            }
            if capturedPlaces.count >= 2 {
                MapPolyline(coordinates: capturedPlaces.map(\.coordinate))
                    .stroke(Color.tteOrange.opacity(0.6),
                            style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
            }
        }
        .mapStyle(.standard)
    }

    // MARK: - Top Bar
    private var topBar: some View {
        VStack {
            HStack {
                Button {
                    if capturedPlaces.isEmpty { dismiss() }
                    else { showEndAlert = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("나의 오늘 기록 중")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                Spacer()
                Text("\(capturedPlaces.count)곳")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 40)
                    .background(Circle().fill(Color.tteOrange))
            }
            .padding(.horizontal, 20).padding(.top, 60)
            Spacer()
        }
    }

    // MARK: - Bottom Panel
    private var bottomPanel: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                if !capturedPlaces.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(capturedPlaces) { place in
                                HStack(spacing: 4) {
                                    Text("\(place.order)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 20, height: 20)
                                        .background(Circle().fill(Color.tteOrange))
                                    Text(place.placeName)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.tteDarkGray)
                                        .lineLimit(1)
                                    Button {
                                        removePlace(place)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.tteMediumGray)
                                    }
                                }
                                .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 20)
                                    .fill(Color(UIColor.secondarySystemBackground)))
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                HStack(spacing: 12) {
                    Button { startCapture() } label: {
                        HStack(spacing: 8) {
                            if isResolvingLocation {
                                ProgressView().tint(.white).scaleEffect(0.8)
                            } else {
                                Image(systemName: "camera.fill").font(.system(size: 16))
                            }
                            Text("여기서 촬영")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.tteOrange))
                    }
                    .disabled(isResolvingLocation)

                    if !capturedPlaces.isEmpty {
                        Button { showEndAlert = true } label: {
                            Text("여행 종료")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.tteOrange)
                                .frame(height: 54).frame(maxWidth: 110)
                                .background(RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.tteOrange, lineWidth: 1.5))
                        }
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

    // MARK: - 코스 저장 시트
    private var saveCourseSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("코스 이름")
                        .font(.system(size: 14, weight: .medium)).foregroundColor(.tteMediumGray)
                    TextField("이번 여행의 이름을 지어주세요", text: $courseName)
                        .font(.system(size: 17)).padding(14)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(Color(UIColor.secondarySystemBackground)))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("태그")
                        .font(.system(size: 14, weight: .medium)).foregroundColor(.tteMediumGray)
                    HStack(spacing: 10) {
                        ForEach(CourseTag.allCases, id: \.self) { tag in
                            Button { selectedTag = tag } label: {
                                Text(tag.rawValue)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(selectedTag == tag ? .white : .tteDarkGray)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Capsule().fill(
                                        selectedTag == tag ? Color.tteOrange
                                        : Color(UIColor.secondarySystemBackground)))
                            }
                        }
                    }
                }
                Spacer()
                Button {
                    buildCourseAndEnd(saveToFirestore: true)
                    showSaveCourse = false
                    showVlog = true
                } label: {
                    Text("저장하고 Vlog 만들기")
                        .font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: 14)
                            .fill(courseName.trimmingCharacters(in: .whitespaces).isEmpty
                                  ? Color.gray.opacity(0.4) : Color.tteOrange))
                }
                .disabled(courseName.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.bottom, 36)
            }
            .padding(.horizontal, 20).padding(.top, 16)
            .navigationTitle("코스로 저장")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") { showSaveCourse = false }.foregroundColor(.tteDarkGray)
                }
            }
        }
    }

    // MARK: - Capture Flow

    private func startCapture() {
        guard !isResolvingLocation else { return }
        locationTask?.cancel()
        isResolvingLocation = true
        locationTask = Task {
            defer { isResolvingLocation = false }
            do {
                let location = try await locationService.requestOneTimeLocation()
                guard !Task.isCancelled else { return }
                resolvedLocation = location
                showPlacePicker = true
            } catch {}
        }
    }

    private func handleCameraSaved() {
        guard let place = pendingPlace else { return }
        if let idx = capturedPlaces.firstIndex(where: { $0.placeName == place.placeName }) {
            capturedPlaces[idx] = place
        } else {
            capturedPlaces.append(place)
            reorderPlaces()
        }
        activityManager.update(placesCount: capturedPlaces.count, lastPlaceName: place.placeName)
        if let rid = roomId {
            roomService.postFeed(roomId: rid, type: .freeCapture,
                                 userId: uid, nickname: nickname,
                                 courseId: "free", courseName: "나의 오늘",
                                 placeName: place.placeName)
        }
        pendingPlace = nil
    }

    private func removePlace(_ place: Place) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        locationTask?.cancel()
        locationTask = nil
        isResolvingLocation = false
        pendingPlace = nil
        resolvedLocation = nil
        deleteClip(for: place)
        capturedPlaces.removeAll { $0.order == place.order }
        reorderPlaces()
        activityManager.update(
            placesCount: capturedPlaces.count,
            lastPlaceName: capturedPlaces.last?.placeName ?? "기록 시작"
        )
    }

    private func reorderPlaces() {
        for i in capturedPlaces.indices {
            capturedPlaces[i] = Place(
                order: i + 1,
                placeName: capturedPlaces[i].placeName,
                latitude: capturedPlaces[i].latitude,
                longitude: capturedPlaces[i].longitude
            )
        }
    }

    private func deleteClip(for place: Place) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = "\(place.order)_\(place.placeName.replacingOccurrences(of: " ", with: "_")).mp4"
        let url = docs.appendingPathComponent("Tteona/Sessions/\(sessionId)/\(name)")
        try? FileManager.default.removeItem(at: url)
    }

    private func buildCourseAndEnd(saveToFirestore: Bool) {
        let name = courseName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "나의 오늘 \(Date().formatted(.dateTime.month().day()))"
            : courseName
        let region = capturedPlaces.first.map {
            "\(String(format: "%.1f", $0.latitude))°N"
        } ?? "기타"
        let course = Course(
            courseId: UUID().uuidString, authorId: uid,
            courseName: name, tag: selectedTag, region: region,
            likeCount: 0, createdAt: Date(), places: capturedPlaces
        )
        generatedCourse = course
        if saveToFirestore { Task { try? await courseService.saveCourse(course) } }
        postEndFeed(placesCount: capturedPlaces.count, courseName: name)
    }

    private func postEndFeed(placesCount: Int? = nil, courseName: String? = nil) {
        guard let rid = roomId else { return }
        roomService.postFeed(roomId: rid, type: .freeTripEnd,
                             userId: uid, nickname: nickname,
                             courseId: "free",
                             courseName: "\(placesCount ?? capturedPlaces.count)곳 방문")
    }
}

// MARK: - Free Session Pin
struct FreeSessionPin: View {
    let order: Int
    var body: some View {
        ZStack {
            Circle().fill(Color.tteOrange).frame(width: 32, height: 32)
                .shadow(color: .tteOrange.opacity(0.4), radius: 4)
            Text("\(order)").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
        }
    }
}
