import SwiftUI
import MapKit

struct ActiveSessionView: View {
    let course: Course
    var roomIds: Set<String> = []
    var isResuming: Bool = false
    @StateObject private var locationService = LocationService()
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
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showArrivalBanner = false
    @State private var arrivedPlace: Place?
    @State private var orderedPlaces: [Place] = []
    @State private var showPlaceEditor = false
    @State private var showResumeSheet = false
    @State private var didStartSession = false
    @State private var cameraResult = false
    @State private var showIntegrityAlert = false

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
            locationService.requestPermission()
            locationService.startTracking(places: course.places)
            fitMap()
            if let saved = sessionStore.loadTodaySession(),
               saved.course.courseId == course.courseId {
                
                // 이어하기 시 무결성 검증 (파일 존재 여부 확인)
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let sessionId = course.courseId
                let validatedVisitedOrders = saved.visitedPlaceOrders.filter { order in
                    guard let place = saved.orderedPlaces.first(where: { $0.order == order }) else { return false }
                    let safeName = place.placeName.replacingOccurrences(of: " ", with: "_")
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: ":", with: "_")
                    let name = "\(place.order)_\(safeName).mp4"
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
                let uid = authService.currentUser?.uid ?? ""
                roomService.stopListeningLocations()
                for rid in roomIds {
                    roomService.stopSharingLocation(roomId: rid, userId: uid)
                }
            }
        }
        .onChange(of: locationService.currentLocation) { _, location in
            guard let rid = roomIds.first,
                  let location,
                  let uid = authService.currentUser?.uid else { return }
            guard scenePhase == .active else { return }
            let nickname = userService.currentUser?.nickname ?? "멤버"
            roomService.updateMyLocationThrottled(roomId: rid, userId: uid, nickname: nickname, location: location)
        }
        .onChange(of: locationService.arrivedAtPlace) { _, place in
            guard let place else { return }
            arrivedPlace = place
            withAnimation { showArrivalBanner = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation { showArrivalBanner = false }
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
                handleCameraDismiss()
                cameraResult = false
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
        .fullScreenCover(isPresented: $showVlog, onDismiss: { sessionStore.clear() }) {
            VlogGenerationView(course: course, sessionId: course.courseId) {
                showVlog = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $showResumeSheet) {
            resumeSheet
        }
        .alert("일부 영상 확인 불가", isPresented: $showIntegrityAlert) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("일부 장소의 영상 파일이 확인되지 않아 촬영 리스트가 자동으로 정리되었습니다. 해당 장소는 다시 촬영하실 수 있습니다.")
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
        Map(position: $cameraPosition) {
            // 현재 위치
            if let loc = locationService.currentLocation {
                Annotation("현재 위치", coordinate: loc.coordinate) {
                    CurrentLocationPin()
                }
            }

            // 코스 핀들
            ForEach(Array(orderedPlaces.enumerated()), id: \.element.id) { index, place in
                Annotation(place.placeName, coordinate: place.coordinate) {
                    SessionPlacePin(
                        order: index + 1,
                        isVisited: visitedPlaces.contains(place.order),
                        isCurrent: index == currentPlaceIndex
                    )
                }
            }

            // 경로선
            if orderedPlaces.count >= 2 {
                MapPolyline(coordinates: orderedPlaces.map(\.coordinate))
                    .stroke(Color.tteOrange.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }

            // 동행 멤버 위치
            ForEach(roomService.memberLocations) { member in
                Annotation(member.nickname, coordinate: CLLocationCoordinate2D(latitude: member.latitude, longitude: member.longitude)) {
                    MemberLocationPin(nickname: member.nickname)
                }
            }
        }
    }

    // MARK: - Top Bar
    private var topBar: some View {
        VStack {
            HStack {
                Button {
                    saveSession()
                    locationService.stopTracking()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                }

                Spacer()

                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("코스 진행 중")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.6)))

                    if !roomIds.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 10))
                            Text("그룹 위치 공유 중")
                                .font(.system(size: 11, weight: .medium))
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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text("편집")
                            .font(.system(size: 10))
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
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 20, height: 20)
                                        .background(Circle().fill(Color.tteOrange))
                                    Text(place.placeName)
                                        .font(.system(size: 13, weight: .medium))
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
                    let isNearby = locationService.distance(to: place).map { $0 <= 200 } ?? false
                    Button {
                        showCamera = true
                    } label: {
                        Text(isNearby ? "📍 \(place.placeName) 도착! 촬영하기" : "📍 \(place.placeName)으로 이동 중...")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(isNearby ? Color.tteOrange : Color.gray.opacity(0.4))
                            )
                    }
                    .disabled(!isNearby)
                }

                if allVisited {
                    Button {
                        postTripEnd()
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
        guard let place = currentPlace else { return }
        visitedPlaces.insert(place.order)
        if !roomIds.isEmpty, let uid = authService.currentUser?.uid {
            let nickname = userService.currentUser?.nickname ?? "멤버"
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
        if currentPlaceIndex < orderedPlaces.count - 1 {
            currentPlaceIndex += 1
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
                    .font(.system(size: 30))
                    .foregroundColor(.tteOrange)
            }
            .padding(.bottom, 16)

            VStack(spacing: 6) {
                Text("오늘 코스가 남아있어요")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.tteDarkGray)
                Text("\(course.courseName) · \(visitedPlaces.count)/\(orderedPlaces.count)곳 완료")
                    .font(.system(size: 14))
                    .foregroundColor(.tteMediumGray)
            }
            .padding(.bottom, 32)

            VStack(spacing: 12) {
                Button {
                    showResumeSheet = false
                    locationService.startTracking(places: orderedPlaces)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill").font(.system(size: 15))
                        Text("이어서 하기").font(.system(size: 16, weight: .semibold))
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
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 15))
                        Text("새로 시작하기").font(.system(size: 16, weight: .medium))
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
        sessionStore.clear()
        orderedPlaces = course.places
        visitedPlaces = []
        skippedPlaces = []
        currentPlaceIndex = 0
        locationService.startTracking(places: orderedPlaces)
        guard let uid = authService.currentUser?.uid else { return }
        let nickname = userService.currentUser?.nickname ?? "멤버"
        FCMService.shared.requestGroupNotification(
            type: .courseTripStart,
            senderUserId: uid,
            senderNickname: nickname,
            roomIds: Array(roomIds),
            courseName: course.courseName
        )
        if !roomIds.isEmpty {
            if let rid = roomIds.first {
                roomService.startListeningLocations(roomId: rid, myUserId: uid)
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
        let nickname = userService.currentUser?.nickname ?? "멤버"
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

// MARK: - Member Location Pin
struct MemberLocationPin: View {
    let nickname: String

    var body: some View {
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
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                            } else if isSkipped {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white.opacity(0.7))
                            } else {
                                Text("\(index + 1)")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(isCurrent ? .white : .tteDarkGray)
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(place.placeName)
                                .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                                .foregroundColor(isVisited || isSkipped ? .tteMediumGray : .tteDarkGray)
                                .strikethrough(isVisited || isSkipped)
                            if isCurrent {
                                Text("현재 목적지")
                                    .font(.system(size: 11))
                                    .foregroundColor(.tteOrange)
                            } else if isSkipped {
                                Text("건너뜀")
                                    .font(.system(size: 11))
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
                                    Text("취소")
                                        .font(.system(size: 12))
                                        .foregroundColor(.tteOrange)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Capsule().stroke(Color.tteOrange, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            } else if !isCurrent {
                                // 건너뛰기
                                Button {
                                    skippedPlaces.insert(place.order)
                                    updateCurrentIndex()
                                } label: {
                                    Text("건너뛰기")
                                        .font(.system(size: 12))
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
                    if let fromIdx = from.first {
                        if fromIdx == currentPlaceIndex {
                            currentPlaceIndex = to > fromIdx ? to - 1 : to
                        } else if fromIdx < currentPlaceIndex && to > currentPlaceIndex {
                            currentPlaceIndex -= 1
                        } else if fromIdx > currentPlaceIndex && to <= currentPlaceIndex {
                            currentPlaceIndex += 1
                        }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)
            .navigationTitle("코스 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("완료") { dismiss() }
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
