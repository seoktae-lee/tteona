import SwiftUI
import MapKit
import GoogleMaps
import AVFoundation

struct ActiveSessionView: View {
    let course: Course
    var roomIds: Set<String> = []
    var isResuming: Bool = false
    @StateObject private var locationService = LocationService()
    @ObservedObject private var locationSocket = LocationSocketService.shared
    @EnvironmentObject private var notificationManager: AppNotificationManager
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var currentPlaceIndex = 0
    @State private var visitedPlaces: Set<Int> = []
    @State private var skippedPlaces: Set<Int> = []
    @State private var showCamera = false
    @State private var showVlog = false
    @State private var showArrivalBanner = false
    @State private var arrivedPlace: Place?
    @State private var orderedPlaces: [Place] = []
    @State private var showPlaceEditor = false
    @State private var showResumeSheet = false
    @State private var didStartSession = false
    @State private var cameraResult = false
    @State private var showIntegrityAlert = false
    @State private var showRatingPrompt = false
    @State private var ratingPlace: Place?
    @State private var showFarCaptureConfirm = false
    @State private var farCaptureDistance: Double?
    @State private var vlogCompleted = false
    @State private var showExitNotice = false
    @State private var recordedSeconds: Double = 0   // 세션 누적 촬영 길이(초) — 진행률 바용
    @AppStorage("didShowSessionExitNotice") private var didShowExitNotice = false

    private let sessionStore = ActiveSessionStore.shared

    private var currentPlace: Place? {
        guard currentPlaceIndex < orderedPlaces.count else { return nil }
        return orderedPlaces[currentPlaceIndex]
    }

    private var allVisited: Bool {
        orderedPlaces.allSatisfy { visitedPlaces.contains($0.order) || skippedPlaces.contains($0.order) }
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
            guard !didStartSession else { return }
            didStartSession = true
            recomputeRecordedSeconds()
            locationService.requestPermission()
            locationService.startTracking(places: course.places)
            if let saved = sessionStore.loadTodaySession(),
               saved.course.courseId == course.courseId {
                
                // 이어하기 시 무결성 검증 (파일 존재 여부 확인)
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let sessionId = course.courseId
                let validatedVisitedOrders = saved.visitedPlaceOrders.filter { order in
                    guard let place = saved.orderedPlaces.first(where: { $0.order == order }) else { return false }
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

                let isCorrupted = validatedVisitedOrders.count < saved.visitedPlaceOrders.count

                if isResuming {
                    // 바로 이어서 하기
                    orderedPlaces = saved.orderedPlaces
                    visitedPlaces = Set(validatedVisitedOrders)
                    skippedPlaces = Set(saved.skippedPlaceOrders)
                    currentPlaceIndex = saved.currentPlaceIndex
                    locationService.startTracking(places: orderedPlaces)
                    if isCorrupted { showIntegrityAlert = true }
                } else {
                    // 저장된 세션 → 시트로 물어보기
                    orderedPlaces = saved.orderedPlaces
                    visitedPlaces = Set(validatedVisitedOrders)
                    skippedPlaces = Set(saved.skippedPlaceOrders)
                    currentPlaceIndex = saved.currentPlaceIndex
                    showResumeSheet = true
                    if isCorrupted { showIntegrityAlert = true }
                }
            } else {
                startNewSession()
            }
        }
        .onDisappear {
            saveSession()
            locationService.stopTracking()
            if !roomIds.isEmpty {
                LocationSocketService.shared.disconnect()
            }
        }
        .onChange(of: locationService.currentLocation) { _, location in
            guard !roomIds.isEmpty, let location else { return }
            guard scenePhase == .active else { return }
            LocationSocketService.shared.sendLocation(
                latitude:  location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
        }
        .onChange(of: locationService.arrivedAtPlace) { _, place in
            guard let place else { return }
            arrivedPlace = place
            Haptics.success()
            withAnimation { showArrivalBanner = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation { showArrivalBanner = false }
            }
            if let uid = authService.currentUser?.uid {
                Task { await StatsService.shared.postEvent(.placeVisited, userId: uid) }
            }
        }
        .onChange(of: notificationManager.pendingPlaceName) { _, placeName in
            guard let placeName else { return }
            // 알림 탭 시 해당 장소로 currentPlaceIndex 맞추고 카메라 열기
            if let idx = course.places.firstIndex(where: { $0.placeName == placeName }) {
                currentPlaceIndex = idx
            }
            showCamera = true
            notificationManager.pendingPlaceName = nil
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            if cameraResult {
                let visitedPlace = currentPlace
                handleCameraDismiss()
                cameraResult = false
                if let visitedPlace {
                    ratingPlace = visitedPlace
                    showRatingPrompt = true
                }
            }
        }) {
            if let place = currentPlace {
                CameraView(place: place, sessionId: course.courseId) {
                    cameraResult = true
                } onClose: {
                    cameraResult = false
                }
            }
        }
        .fullScreenCover(isPresented: $showVlog, onDismiss: {
            sessionStore.clear()
            // Vlog 완료 후에는 세션 화면까지 함께 닫는다
            if vlogCompleted { dismiss() }
        }) {
            // orderedPlaces(재정렬 반영)로 course를 재구성해서 Vlog 순서 보장
            let reorderedCourse = Course(
                courseId: course.courseId,
                authorId: course.authorId,
                courseName: course.courseName,
                tag: course.tag,
                region: course.region,
                likeCount: course.likeCount,
                createdAt: course.createdAt,
                places: orderedPlaces
            )
            VlogGenerationView(course: reorderedCourse, sessionId: course.courseId) {
                vlogCompleted = true
                showVlog = false
            }
        }
        .sheet(isPresented: $showResumeSheet) {
            resumeSheet
        }
        .alert(L("session.exitNotice.title"), isPresented: $showExitNotice) {
            Button(L("common.close")) {
                didShowExitNotice = true
                closeSession()
            }
            Button(L("session.continueProgress"), role: .cancel) {
                didShowExitNotice = true
            }
        } message: {
            Text(L("session.exitNotice.message"))
        }
        .confirmationDialog(L("session.notArrivedYet"), isPresented: $showFarCaptureConfirm, titleVisibility: .visible) {
            Button(L("session.captureAnyway")) { showCamera = true }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            if let d = farCaptureDistance, let place = currentPlace {
                Text(L("session.farCapture.message", place.placeName, formatDistance(d)))
            } else {
                Text(L("session.farCapture.noLocation"))
            }
        }
        .alert(L("session.integrity.title"), isPresented: $showIntegrityAlert) {
            Button(L("common.ok"), role: .cancel) { }
        } message: {
            Text(L("session.integrity.message"))
        }
        .sheet(isPresented: $showRatingPrompt, onDismiss: { ratingPlace = nil }) {
            if let place = ratingPlace,
               let uid = authService.currentUser?.uid {
                PlaceRatingPromptView(
                    place: place,
                    userId: uid,
                    nickname: userService.currentUser?.nickname ?? L("session.member")
                ) {
                    showRatingPrompt = false
                }
            }
        }
        .sheet(isPresented: $showPlaceEditor, onDismiss: saveSession) {
            PlaceEditorSheet(
                places: $orderedPlaces,
                visitedPlaces: $visitedPlaces,
                skippedPlaces: $skippedPlaces,
                currentPlaceIndex: $currentPlaceIndex
            )
        }
    }

    // MARK: - Map
    private var mapLayer: some View {
        GoogleMapView(
            markers: sessionMarkers,
            polyline: orderedPlaces.count >= 2 ? orderedPlaces.map(\.coordinate) : nil,
            dashedPolyline: true,
            showsUserLocation: true,   // 현재 위치는 구글맵 기본 파란 점
            initialCamera: GoogleMapView.fittingCamera(for: course.places.map(\.coordinate))
        )
    }

    // 코스 장소 핀(방문/현재/일반) + 동행 멤버 위치 핀 — 기존 SwiftUI 핀 디자인을 이미지로 렌더
    private var sessionMarkers: [GoogleMapMarker] {
        var result: [GoogleMapMarker] = []
        for (index, place) in orderedPlaces.enumerated() {
            let visited = visitedPlaces.contains(place.order)
            let current = index == currentPlaceIndex
            result.append(GoogleMapMarker(
                id: "place_\(place.id)",
                coordinate: place.coordinate,
                icon: Self.renderPinImage(SessionPlacePin(order: index + 1, isVisited: visited, isCurrent: current)),
                iconAnchor: CGPoint(x: 0.5, y: 0.5),
                styleKey: "s:\(index):\(visited ? 1 : 0):\(current ? 1 : 0)"
            ))
        }
        for member in locationSocket.memberLocations {
            result.append(GoogleMapMarker(
                id: "member_\(member.userId)",
                coordinate: member.coordinate,
                icon: Self.renderPinImage(MemberLocationPin(nickname: member.nickname)),
                iconAnchor: CGPoint(x: 0.5, y: 0.32),   // 원(상단)이 좌표에 오도록
                styleKey: "m:\(member.nickname)"
            ))
        }
        return result
    }

    // SwiftUI 핀 뷰 → 마커 아이콘 이미지
    private static func renderPinImage<V: View>(_ view: V) -> UIImage? {
        let renderer = ImageRenderer(content: view.padding(3))
        renderer.scale = UIScreen.main.scale
        return renderer.uiImage
    }

    // MARK: - Top Bar
    private var topBar: some View {
        VStack {
            HStack {
                Button {
                    if didShowExitNotice {
                        closeSession()
                    } else {
                        showExitNotice = true
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.tte(16, .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                }
                .accessibilityLabel(L("session.close"))

                Spacer()

                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text(L("session.courseInProgress"))
                            .font(.tte(13, .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.6)))

                    if !roomIds.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill")
                                .font(.tte(10))
                            Text(L("session.sharingLocation"))
                                .font(.tte(11, .medium))
                        }
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.tteOrange.opacity(0.85)))
                    }
                }

                Spacer()

                Button {
                    showPlaceEditor = true
                } label: {
                    VStack(spacing: 1) {
                        Text("\(visitedPlaces.count)/\(orderedPlaces.count)")
                            .font(.tte(13, .semibold))
                            .foregroundColor(.white)
                        Text(L("common.edit"))
                            .font(.tte(10))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(width: 52, height: 40)
                    .background(Circle().fill(Color.tteOrange))
                }
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
                // 촬영 완료된 장소 칩
                let visitedList = orderedPlaces.filter { visitedPlaces.contains($0.order) }
                if !visitedList.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(visitedList) { place in
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
                                }
                                .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 20)
                                    .fill(Color(UIColor.secondarySystemBackground)))
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }

                if !visitedList.isEmpty { budgetBar }

                if let place = currentPlace, !allVisited {
                    // 거리 표시
                    if let distance = locationService.distance(to: place) {
                        HStack(spacing: 6) {
                            Image(systemName: "location.fill")
                                .foregroundColor(.tteOrange)
                                .font(.tte(14))
                            Text(L("session.distanceRemaining", place.placeName, formatDistance(distance)))
                                .font(.tte(14))
                                .foregroundColor(.tteDarkGray)
                        }
                    }

                    // 도착했어요 버튼 — 멀리 있어도 탭 가능 (GPS 오차·실내 대비 수동 촬영 허용)
                    let distance = locationService.distance(to: place)
                    let isNearby = distance.map { $0 <= 200 } ?? false
                    Button {
                        if isNearby {
                            showCamera = true
                        } else {
                            farCaptureDistance = distance
                            showFarCaptureConfirm = true
                        }
                    } label: {
                        Text(isNearby ? L("session.arrivedCapture", place.placeName) : L("session.movingTo", place.placeName))
                            .font(.tte(16, .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(isNearby ? Color.tteOrange : Color.gray.opacity(0.4))
                            )
                    }
                }

                if allVisited {
                    Button {
                        postTripEnd()
                        showVlog = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "film.fill")
                            Text(L("session.makeVlog"))
                                .fontWeight(.semibold)
                        }
                        .font(.tte(16))
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
    private func closeSession() {
        saveSession()
        locationService.stopTracking()
        dismiss()
    }

    // MARK: - 촬영 예산 진행률 바
    private var budgetSeconds: Double { ProManager.shared.vlogBudgetSeconds }

    private var budgetBar: some View {
        let full = recordedSeconds >= budgetSeconds
        let frac = min(1, max(0, recordedSeconds / budgetSeconds))
        return VStack(spacing: 6) {
            HStack {
                Text(L("impromptu.videoBudget"))
                    .font(.tte(12, .semibold))
                    .foregroundColor(.tteMediumGray)
                Spacer()
                Text(budgetValueText)
                    .font(.tte(12, .bold))
                    .foregroundColor(full ? .red : .tteOrange)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.tteMediumGray.opacity(0.2))
                    Capsule()
                        .fill(full ? Color.red : Color.tteOrange)
                        .frame(width: max(0, geo.size.width * frac))
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 4)
    }

    private var budgetValueText: String {
        if ProManager.shared.isPro {
            return "\(Self.mmss(recordedSeconds)) / \(Self.mmss(budgetSeconds))"
        }
        return L("impromptu.videoBudgetValue",
                 Int(recordedSeconds.rounded()), Int(budgetSeconds.rounded()))
    }

    private static func mmss(_ s: Double) -> String {
        let v = max(0, Int(s.rounded()))
        return String(format: "%d:%02d", v / 60, v % 60)
    }

    /// 세션 폴더의 클립 길이를 합산해 진행률 바를 갱신한다.
    private func recomputeRecordedSeconds() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tteona/Sessions/\(course.courseId)")
        Task {
            var total: Double = 0
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension.lowercased() == "mp4" {
                if let d = try? await AVURLAsset(url: f).load(.duration) {
                    total += CMTimeGetSeconds(d)
                }
            }
            await MainActor.run { self.recordedSeconds = total }
        }
    }

    private func handleCameraDismiss() {
        guard let place = currentPlace else { return }
        Haptics.success()
        visitedPlaces.insert(place.order)
        recomputeRecordedSeconds()
        if !roomIds.isEmpty, let uid = authService.currentUser?.uid {
            let nickname = userService.currentUser?.nickname ?? L("session.member")
            let lat = locationService.currentLocation?.coordinate.latitude ?? place.latitude
            let lon = locationService.currentLocation?.coordinate.longitude ?? place.longitude
            for rid in roomIds {
                roomService.postFeed(roomId: rid, type: .freeCapture,
                                     userId: uid, nickname: nickname,
                                     courseId: course.courseId, courseName: course.courseName,
                                     placeName: place.placeName,
                                     latitude: lat, longitude: lon)
            }
            FCMService.shared.requestGroupNotification(
                type: .videoRecorded,
                senderUserId: uid,
                senderNickname: nickname,
                roomIds: Array(roomIds),
                placeName: place.placeName
            )
        }
        // 건너뛴 장소를 포함해 다음 미완료 장소로 이동
        if let next = orderedPlaces.indices.first(where: { idx in
            let o = orderedPlaces[idx].order
            return !visitedPlaces.contains(o) && !skippedPlaces.contains(o)
        }) {
            currentPlaceIndex = next
        }
        saveSession()
    }

    // MARK: - 이어서 / 새로 시작 시트
    private var resumeSheet: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 24)

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
                Text(L("session.courseRemaining.title"))
                    .font(.tte(20, .bold))
                    .foregroundColor(.tteDarkGray)
                Text(L("session.courseRemaining.progress", course.courseName, visitedPlaces.count, orderedPlaces.count))
                    .font(.tte(14))
                    .foregroundColor(.tteMediumGray)
            }
            .padding(.bottom, 32)

            VStack(spacing: 12) {
                Button {
                    showResumeSheet = false
                    locationService.startTracking(places: orderedPlaces)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill").font(.tte(15))
                        Text(L("session.resume")).font(.tte(16, .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }

                Button {
                    showResumeSheet = false
                    startNewSession()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise").font(.tte(15))
                        Text(L("main.startFresh")).font(.tte(16, .medium))
                    }
                    .foregroundColor(.tteDarkGray)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemBackground)))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled()
    }

    private func startNewSession() {
        Haptics.medium()
        sessionStore.clear()
        orderedPlaces = course.places
        visitedPlaces = []
        skippedPlaces = []
        currentPlaceIndex = 0
        locationService.startTracking(places: orderedPlaces)
        guard let uid = authService.currentUser?.uid else { return }
        let nickname = userService.currentUser?.nickname ?? L("session.member")
        FCMService.shared.requestGroupNotification(
            type: .courseTripStart,
            senderUserId: uid,
            senderNickname: nickname,
            roomIds: Array(roomIds),
            courseName: course.courseName
        )
        // 코스 작성자에게 "누군가 내 코스를 따라가고 있어요" 알림 (본인 제외)
        if uid != course.authorId {
            Task {
                await PushService.shared.notifyCourseFollowed(
                    courseOwnerId: course.authorId,
                    followerNickname: nickname,
                    courseName: course.courseName
                )
            }
        }
        if !roomIds.isEmpty {
            if let rid = roomIds.first {
                LocationSocketService.shared.connect(roomId: rid, userId: uid, nickname: nickname)
            }
            for rid in roomIds {
                roomService.postFeed(roomId: rid, type: .tripStart, userId: uid,
                                     nickname: nickname, courseId: course.courseId,
                                     courseName: course.courseName)
            }
        }
    }

    private func postTripEnd() {
        guard !roomIds.isEmpty, let uid = authService.currentUser?.uid else { return }
        let nickname = userService.currentUser?.nickname ?? L("session.member")
        for rid in roomIds {
            roomService.postFeed(roomId: rid, type: .tripEnd, userId: uid,
                                 nickname: nickname, courseId: course.courseId,
                                 courseName: course.courseName)
        }
    }

    private func saveSession() {
        let session = SavedActiveSession(
            date: Date(),
            course: SavedCourse(from: course),
            orderedPlaces: orderedPlaces,
            visitedPlaceOrders: Array(visitedPlaces),
            skippedPlaceOrders: Array(skippedPlaces),
            currentPlaceIndex: currentPlaceIndex,
            roomIds: Array(roomIds)
        )
        sessionStore.save(session)
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

            // ImageRenderer로 지도 마커에 그려지는 뷰 — Dynamic Type 스케일 없이 고정 크기 유지
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
                    .font(.tte(20))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("session.arrivedAt", placeName))
                        .font(.tte(15, .semibold))
                        .foregroundColor(.white)
                    Text(L("session.tapToCapture"))
                        .font(.tte(12))
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

// MARK: - Member Location Pin
struct MemberLocationPin: View {
    let nickname: String

    var body: some View {
        // ImageRenderer로 지도 마커에 그려지는 뷰 — Dynamic Type 스케일 없이 고정 크기 유지
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(Color.purple)
                    .frame(width: 36, height: 36)
                    .shadow(color: .purple.opacity(0.4), radius: 4)
                Text(String(nickname.prefix(1)))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }
            Text(nickname)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.purple.opacity(0.85)))
        }
    }
}

// MARK: - 코스 순서 편집 시트
struct PlaceEditorSheet: View {
    @Binding var places: [Place]
    @Binding var visitedPlaces: Set<Int>
    @Binding var skippedPlaces: Set<Int>
    @Binding var currentPlaceIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .active

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                    let isVisited = visitedPlaces.contains(place.order)
                    let isSkipped = skippedPlaces.contains(place.order)
                    let isCurrent = index == currentPlaceIndex && !isVisited && !isSkipped

                    HStack(spacing: 14) {
                        // 순서 번호
                        ZStack {
                            Circle()
                                .fill(isVisited ? Color.green
                                      : isSkipped ? Color.gray.opacity(0.3)
                                      : isCurrent ? Color.tteOrange
                                      : Color.gray.opacity(0.25))
                                .frame(width: 32, height: 32)
                            if isVisited {
                                Image(systemName: "checkmark")
                                    .font(.tte(12, .bold))
                                    .foregroundColor(.white)
                            } else if isSkipped {
                                Image(systemName: "forward.fill")
                                    .font(.tte(11, .bold))
                                    .foregroundColor(.white.opacity(0.7))
                            } else {
                                Text("\(index + 1)")
                                    .font(.tte(13, .bold))
                                    .foregroundColor(isCurrent ? .white : .tteDarkGray)
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(place.placeName)
                                .font(.tte(15, isCurrent ? .semibold : .regular))
                                .foregroundColor(isVisited || isSkipped ? .tteMediumGray : .tteDarkGray)
                                .strikethrough(isVisited || isSkipped)
                            if isCurrent {
                                Text(L("session.currentDestination"))
                                    .font(.tte(11))
                                    .foregroundColor(.tteOrange)
                            } else if isSkipped {
                                Text(L("session.skipped"))
                                    .font(.tte(11))
                                    .foregroundColor(.tteMediumGray)
                            }
                        }

                        Spacer()

                        if !isVisited {
                            if isSkipped {
                                // 건너뛰기 취소
                                Button {
                                    skippedPlaces.remove(place.order)
                                    updateCurrentIndex()
                                } label: {
                                    Text(L("common.cancel"))
                                        .font(.tte(12))
                                        .foregroundColor(.tteOrange)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Capsule().stroke(Color.tteOrange, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            } else {
                                // 건너뛰기 (현재 목적지 포함)
                                Button {
                                    skippedPlaces.insert(place.order)
                                    updateCurrentIndex()
                                } label: {
                                    Text(L("common.skip"))
                                        .font(.tte(12))
                                        .foregroundColor(.tteMediumGray)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Capsule().fill(Color(UIColor.tertiarySystemBackground)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(isCurrent ? Color.tteOrange.opacity(0.06) : Color.clear)
                }
                .onMove { from, to in
                    places.move(fromOffsets: from, toOffset: to)

                    // order를 배열 순서 기준으로 재번호 매기기
                    let oldOrders = places.map(\.order)
                    for i in places.indices {
                        places[i].order = i + 1
                    }

                    // visitedPlaces / skippedPlaces를 새 order로 매핑
                    var orderMap: [Int: Int] = [:]
                    for (i, oldOrder) in oldOrders.enumerated() {
                        orderMap[oldOrder] = i + 1
                    }
                    visitedPlaces = Set(visitedPlaces.compactMap { orderMap[$0] })
                    skippedPlaces = Set(skippedPlaces.compactMap { orderMap[$0] })

                    // 새 순서 기준 첫 번째 미방문·미건너뛴 장소로 이동
                    updateCurrentIndex()
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)
            .navigationTitle(L("session.editCourse"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.done")) { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundColor(.tteOrange)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func updateCurrentIndex() {
        if let next = places.indices.first(where: {
            !visitedPlaces.contains(places[$0].order) && !skippedPlaces.contains(places[$0].order)
        }) {
            currentPlaceIndex = next
        }
    }
}

#Preview {
    ActiveSessionView(course: Course.mockCourses[0])
}
