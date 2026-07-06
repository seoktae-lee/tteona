import SwiftUI
import GoogleMaps
import CoreLocation

struct ImpromptuSessionView: View {
    var selectedRoomIds: Set<String> = []
    var onRestartWithRoomSelect: (() -> Void)? = nil
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var roomService: RoomService
    @StateObject private var locationService = LocationService()
    @Environment(\.dismiss) private var dismiss

    private let activityManager = TodaySessionActivityManager.shared

    @State private var capturedPlaces: [Place] = []
    @State private var cameraCommand: GMSCameraPosition?
    @State private var didCenterOnUser = false
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
    @State private var pendingShowVlog = false
    @State private var pendingShowSaveCourse = false
    @State private var courseName = ""
    @State private var selectedTag: CourseTag = .friends
    @State private var generatedCourse: Course? = nil
    @State private var courseSavedToFirestore = false
    @State private var showResumeSheet = false
    @State private var savedSession: SavedImpromptuSession? = nil
    @State private var activeRoomIds: Set<String> = []
    @State private var didStartSession = false
    @State private var cameraResult = false
    @State private var showIntegrityAlert = false

    private let sessionStore = ImpromptuSessionStore.shared

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
            guard !didStartSession else { return }
            didStartSession = true
            locationService.requestPermission()
            locationService.startContinuousUpdates()
            activityManager.start()
            activeRoomIds = selectedRoomIds
            // uid가 준비될 때까지 대기 (최대 3초)
            var waited = 0
            while uid.isEmpty && waited < 30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            // 이전 세션 복원 여부 확인
            if let saved = sessionStore.loadTodaySession(), !saved.places.isEmpty {
                savedSession = saved
                showResumeSheet = true
            } else {
                sessionStore.clear()
                startNewSession()
            }
        }
        .onDisappear {
            locationService.stopContinuousUpdates()
            activityManager.end()
            locationTask?.cancel()
        }
        .onChange(of: locationService.currentLocation) { _, loc in
            // 위치 첫 확보 시 내 위치로 카메라 이동 (이후엔 유저가 자유롭게 이동)
            guard let loc, !didCenterOnUser else { return }
            didCenterOnUser = true
            cameraCommand = GMSCameraPosition(latitude: loc.coordinate.latitude,
                                              longitude: loc.coordinate.longitude, zoom: 15)
        }
        .sheet(isPresented: $showResumeSheet) {
            resumeSheet
        }
        // 1단계: 장소 선택
        .sheet(isPresented: $showPlacePicker, onDismiss: {
            guard pendingPlace != nil else { return }
            showCamera = true
        }) {
            if let loc = resolvedLocation {
                PlacePickerView(location: loc) { name in
                    pendingPlace = Place(
                        order: capturedPlaces.count + 1,
                        placeName: name,
                        latitude: loc.coordinate.latitude,
                        longitude: loc.coordinate.longitude,
                        clipFileName: "\(UUID().uuidString).mp4"
                    )
                    showPlacePicker = false
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
            }
        }
        // 2단계: 카메라
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            if cameraResult {
                handleCameraSaved()
                cameraResult = false
            }
        }) {
            if let place = pendingPlace {
                CameraView(
                    place: place,
                    sessionId: sessionId,
                    onSaved: {
                        cameraResult = true
                    },
                    onClose: {
                        cameraResult = false
                        pendingPlace = nil
                    }
                )
            }
        }
        .fullScreenCover(isPresented: $showVlog) {
            if let course = generatedCourse {
                VlogGenerationView(
                    course: course,
                    sessionId: sessionId,
                    thumbnailCourseId: courseSavedToFirestore ? course.courseId : nil
                ) {
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $showSaveCourse) {
            saveCourseSheet
        }
        .sheet(isPresented: $showEndAlert, onDismiss: {
            // 종료 시트에서 고른 다음 단계를 닫힘 완료 후 실행
            if pendingShowVlog {
                pendingShowVlog = false
                showVlog = true
            } else if pendingShowSaveCourse {
                pendingShowSaveCourse = false
                showSaveCourse = true
            }
        }) {
            endSheet
        }
        .alert("일부 영상 확인 불가", isPresented: $showIntegrityAlert) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("일부 장소의 영상 파일이 확인되지 않아 촬영 리스트가 자동으로 정리되었습니다. 해당 장소는 다시 촬영하실 수 있습니다.")
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
                    .font(.tte(15, .medium))
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
        GoogleMapView(
            markers: capturedPlaces.map { GoogleMapMarker(id: $0.id, coordinate: $0.coordinate, badgeNumber: $0.order) },
            polyline: capturedPlaces.count >= 2 ? capturedPlaces.map(\.coordinate) : nil,
            dashedPolyline: true,
            showsUserLocation: true,   // 내 위치는 구글맵 기본 파란 점
            initialCamera: locationService.currentLocation.map {
                GMSCameraPosition(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, zoom: 15)
            },
            cameraCommand: $cameraCommand
        )
    }

    // MARK: - Top Bar
    private var topBar: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.tte(16, .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                }
                Spacer()
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("나의 오늘 기록 중")
                            .font(.tte(13, .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.6)))

                    if !activeRoomIds.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill")
                                .font(.tte(10))
                            Text("그룹 위치 공유 중")
                                .font(.tte(11, .medium))
                        }
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.tteOrange.opacity(0.85)))
                    }
                }
                Spacer()
                Text("\(capturedPlaces.count)곳")
                    .font(.tte(14, .bold))
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
                                        .font(.tte(11, .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 20, height: 20)
                                        .background(Circle().fill(Color.tteOrange))
                                    Text(place.placeName)
                                        .font(.tte(13, .medium))
                                        .foregroundColor(.tteDarkGray)
                                        .lineLimit(1)
                                    Button {
                                        removePlace(place)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.tte(10, .bold))
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
                                Image(systemName: "camera.fill").font(.tte(16))
                            }
                            Text("여기서 촬영")
                                .font(.tte(16, .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.tteOrange))
                    }
                    .disabled(isResolvingLocation)

                    if !capturedPlaces.isEmpty {
                        Button { showEndAlert = true } label: {
                            Text("오늘 종료")
                                .font(.tte(16, .semibold))
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

    // MARK: - 오늘 종료 시트
    private var endSheet: some View {
        VStack(spacing: 0) {
            // 핸들
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 20)

            // 헤더
            VStack(spacing: 6) {
                Text("오늘을 마칠까요?")
                    .font(.tte(20, .bold))
                    .foregroundColor(.tteDarkGray)
                Text("방문한 장소 \(capturedPlaces.count)곳이 기록됐어요")
                    .font(.tte(14))
                    .foregroundColor(.tteMediumGray)
            }
            .padding(.bottom, 28)

            VStack(spacing: 12) {
                // 두 가지 마무리 방식 — 정사각형 카드 좌우 배치로 한눈에 비교
                HStack(spacing: 12) {
                    endChoiceCard(
                        icon: "film.fill",
                        title: "Vlog만 만들기",
                        subtitle: "영상을 이어 붙여\n추억으로 남겨요",
                        isPrimary: true
                    ) {
                        buildCourseAndEnd(saveToFirestore: false)
                        pendingShowVlog = true
                        showEndAlert = false
                    }

                    endChoiceCard(
                        icon: "mappin.and.ellipse",
                        title: "코스 저장 후\nVlog 만들기",
                        subtitle: "경로를 나중에\n다시 쓸 수 있어요",
                        isPrimary: false
                    ) {
                        pendingShowSaveCourse = true
                        showEndAlert = false
                    }
                }

                // 구분선
                HStack {
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
                    Text("또는")
                        .font(.tte(12))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
                }
                .padding(.vertical, 2)

                // 계속 기록
                Button {
                    showEndAlert = false
                } label: {
                    Text("계속 기록할게요")
                        .font(.tte(15, .medium))
                        .foregroundColor(.tteOrange)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.tteOrange.opacity(0.4), lineWidth: 1))
                }
            }
            .padding(.horizontal, 20)

            Spacer().frame(height: 36)
        }
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(28)
    }

    // MARK: - 종료 선택 카드 (좌우 정사각형 배치)
    private func endChoiceCard(icon: String, title: String, subtitle: String,
                               isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Circle()
                        .fill(isPrimary ? Color.white.opacity(0.22) : Color.tteOrange.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.tte(18))
                        .foregroundColor(isPrimary ? .white : .tteOrange)
                }

                Spacer(minLength: 10)

                Text(title)
                    .font(.tte(16, .bold))
                    .foregroundColor(isPrimary ? .white : .tteDarkGray)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.tte(11.5))
                    .foregroundColor(isPrimary ? .white.opacity(0.85) : .tteMediumGray)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(isPrimary ? Color.tteOrange : Color(UIColor.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isPrimary ? Color.clear : Color.tteOrange.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 코스 저장 시트
    private var saveCourseSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("코스 이름")
                        .font(.tte(14, .medium)).foregroundColor(.tteMediumGray)
                    TextField("이번 여행의 이름을 지어주세요", text: $courseName)
                        .font(.tte(17)).padding(14)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(Color(UIColor.secondarySystemBackground)))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("태그")
                        .font(.tte(14, .medium)).foregroundColor(.tteMediumGray)
                    HStack(spacing: 10) {
                        ForEach(CourseTag.allCases, id: \.self) { tag in
                            Button { selectedTag = tag } label: {
                                Text(tag.rawValue)
                                    .font(.tte(14, .medium))
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
                        .font(.tte(17, .semibold)).foregroundColor(.white)
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
        Haptics.success()
        capturedPlaces.append(place)
        reorderPlaces()
        sessionStore.save(places: capturedPlaces, roomIds: Array(activeRoomIds))
        activityManager.update(placesCount: capturedPlaces.count, lastPlaceName: place.placeName)
        for rid in activeRoomIds {
            roomService.postFeed(roomId: rid, type: .freeCapture,
                                 userId: uid, nickname: nickname,
                                 courseId: "free", courseName: "나의 오늘",
                                 placeName: place.placeName,
                                 latitude: place.latitude,
                                 longitude: place.longitude)
        }
        if !activeRoomIds.isEmpty {
            FCMService.shared.requestGroupNotification(
                type: .videoRecorded,
                senderUserId: uid,
                senderNickname: nickname,
                roomIds: Array(activeRoomIds),
                placeName: place.placeName
            )
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
        if capturedPlaces.isEmpty {
            sessionStore.clear()
        } else {
            sessionStore.save(places: capturedPlaces)
        }
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
                longitude: capturedPlaces[i].longitude,
                clipFileName: capturedPlaces[i].clipFileName
            )
        }
    }

    private func deleteClip(for place: Place) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = place.clipFileName ?? {
            let safeName = place.placeName
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            return "\(place.order)_\(safeName).mp4"
        }()
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
        courseSavedToFirestore = saveToFirestore
        sessionStore.clear()
        if saveToFirestore { Task { try? await courseService.saveCourse(course) } }
        postEndFeed(toRoomIds: Array(activeRoomIds), count: capturedPlaces.count)
    }

    private func postEndFeed(toRoomIds roomIds: [String], count: Int) {
        guard !roomIds.isEmpty else { return }
        FCMService.shared.requestGroupNotification(
            type: .freeTripEnd,
            senderUserId: uid,
            senderNickname: nickname,
            roomIds: roomIds,
            courseName: "\(count)곳 방문"
        )
        for rid in roomIds {
            roomService.postFeed(roomId: rid, type: .freeTripEnd,
                                 userId: uid, nickname: nickname,
                                 courseId: "free",
                                 courseName: "\(count)곳 방문")
        }
    }

    private func startNewSession() {
        // 세션 폴더(free_{uid})는 유저당 고정이라 이전 세션 클립이 남아 있으면
        // 촬영 예산(무료 30초)을 그대로 소진시킨다 — 새 세션은 깨끗한 폴더로 시작
        deleteAllClips()
        capturedPlaces = []
        activeRoomIds = selectedRoomIds
        let roomIds = Array(activeRoomIds)
        print("[Feed] startNewSession uid=\(uid) nickname=\(nickname) roomIds=\(roomIds)")
        for rid in roomIds {
            roomService.postFeed(roomId: rid, type: .freeTripStart,
                                 userId: uid, nickname: nickname,
                                 courseId: "free", courseName: "나의 오늘")
        }
    }

    private func resumeSession(_ session: SavedImpromptuSession) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let validatedPlaces = session.places.filter { place in
            let name: String
            if let clipFileName = place.clipFileName {
                name = clipFileName
            } else {
                let safeName = place.placeName.replacingOccurrences(of: " ", with: "_")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: ":", with: "_")
                name = "\(place.order)_\(safeName).mp4"
            }
            let url = docs.appendingPathComponent("Tteona/Sessions/\(sessionId)/\(name)")
            return FileManager.default.fileExists(atPath: url.path)
        }

        if validatedPlaces.count < session.places.count {
            showIntegrityAlert = true
        }

        capturedPlaces = validatedPlaces
        reorderPlaces()

        if !session.roomIds.isEmpty {
            activeRoomIds = Set(session.roomIds)
        }
    }

    private func deleteAllClips() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tteona/Sessions/\(sessionId)")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 이어서 / 새로 시작 시트
    private var resumeSheet: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 24)

            // 아이콘
            ZStack {
                Circle()
                    .fill(Color.tteOrange.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.tte(30))
                    .foregroundColor(.tteOrange)
            }
            .padding(.bottom, 16)

            VStack(spacing: 6) {
                Text("오늘 기록이 남아있어요")
                    .font(.tte(20, .bold))
                    .foregroundColor(.tteDarkGray)
                if let saved = savedSession {
                    Text("장소 \(saved.places.count)곳 · \(Self.timeString(saved.date))")
                        .font(.tte(14))
                        .foregroundColor(.tteMediumGray)
                }
            }
            .padding(.bottom, 32)

            VStack(spacing: 12) {
                // 이어서 기록하기
                Button {
                    if let saved = savedSession { resumeSession(saved) }
                    showResumeSheet = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                            .font(.tte(15))
                        Text("이어서 기록하기")
                            .font(.tte(16, .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }

                // 새로 시작하기
                Button {
                    deleteAllClips()
                    sessionStore.clear()
                    showResumeSheet = false
                    if let restart = onRestartWithRoomSelect {
                        // 부모가 이 화면을 닫고 onDismiss에서 방 선택을 다시 연다
                        restart()
                    } else {
                        startNewSession()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.tte(15))
                        Text("새로 시작하기")
                            .font(.tte(16, .medium))
                    }
                    .foregroundColor(.tteDarkGray)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 16)
                        .fill(Color(UIColor.secondarySystemBackground)))
                }
            }
            .padding(.horizontal, 24)

            Spacer().frame(height: 40)
        }
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(28)
        .interactiveDismissDisabled(true)
    }

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "a h:mm"
        f.locale = Locale(identifier: "ko_KR")
        return f.string(from: date)
    }
}

// MARK: - Free Session Pin
struct FreeSessionPin: View {
    let order: Int
    var body: some View {
        ZStack {
            Circle().fill(Color.tteOrange).frame(width: 32, height: 32)
                .shadow(color: .tteOrange.opacity(0.4), radius: 4)
            Text("\(order)").font(.tte(13, .bold)).foregroundColor(.white)
        }
    }
}
