import SwiftUI
import PhotosUI

struct MyCourseView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @State private var selectedTab: MyCourseTab = .liked
    @State private var selectedCourse: Course?
    @State private var courseToDelete: Course?
    @State private var showDeleteConfirm = false
    @State private var courseSessionInfo: CourseSessionInfo? = nil
    @State private var courseForThumbnail: Course?
    @State private var showThumbnailPicker = false
    @State private var thumbnailPickerItem: PhotosPickerItem?
    @State private var isUploadingThumbnail = false
    @State private var thumbnailResultMessage = ""
    @State private var showThumbnailResult = false

    enum MyCourseTab: String, CaseIterable {
        case liked = "좋아요"
        case mine = "내 코스"
        case group = "그룹"
    }

    private var likedCourses: [Course] {
        courseService.likedCourseIds.compactMap { id in
            courseService.courses.first { $0.courseId == id }
        }
    }

    private var myCourses: [Course] {
        courseService.courses.filter { $0.authorId == authService.currentUser?.uid }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabPicker
                tabContent
            }
            .navigationTitle("나의 코스")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if selectedTab == .group {
                    ToolbarItem(placement: .topBarTrailing) {
                        groupToolbarMenu
                    }
                }
            }
        }
        .sheet(item: $selectedCourse) { course in
            CourseDetailView(course: course) { roomIds in
                selectedCourse = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    courseSessionInfo = CourseSessionInfo(course: course, roomIds: roomIds)
                }
            }
            .environmentObject(authService)
            .environmentObject(courseService)
            .environmentObject(userService)
            .environmentObject(roomService)
        }
        .fullScreenCover(item: $courseSessionInfo) { info in
            ActiveSessionView(course: info.course, roomIds: info.roomIds)
                .environmentObject(AppNotificationManager.shared)
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
        .alert("코스를 삭제할까요?", isPresented: $showDeleteConfirm) {
            Button("삭제", role: .destructive) {
                guard let course = courseToDelete else { return }
                Task {
                    try? await courseService.deleteCourse(course)
                    courseToDelete = nil
                }
            }
            Button("취소", role: .cancel) { courseToDelete = nil }
        } message: {
            Text("삭제하면 복구할 수 없어요.")
        }
        .photosPicker(isPresented: $showThumbnailPicker, selection: $thumbnailPickerItem, matching: .images)
        .onChange(of: thumbnailPickerItem) { _, newItem in
            Task { await uploadThumbnail(from: newItem) }
        }
        .alert(thumbnailResultMessage, isPresented: $showThumbnailResult) {
            Button("확인", role: .cancel) {}
        }
        .overlay {
            if isUploadingThumbnail {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().tint(.white).scaleEffect(1.3)
                        Text("썸네일 업로드 중...")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                    }
                    .padding(28)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.7)))
                }
            }
        }
        .task {
            if let uid = authService.currentUser?.uid {
                await courseService.fetchLikedCourseIds(userId: uid)
            }
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(MyCourseTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
                } label: {
                    VStack(spacing: 8) {
                        Text(tab.rawValue)
                            .font(.system(size: 15, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundColor(selectedTab == tab ? .tteDarkGray : .tteMediumGray)
                        Rectangle()
                            .fill(selectedTab == tab ? Color.tteOrange : Color.clear)
                            .frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 4)
        .background(Color.tteBackground)
        .overlay(
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .liked, .mine:
            courseList
        case .group:
            GroupRoomList()
                .environmentObject(authService)
                .environmentObject(courseService)
                .environmentObject(roomService)
        }
    }

    @ViewBuilder
    private var courseList: some View {
        let courses = selectedTab == .liked ? likedCourses : myCourses
        let isMine = selectedTab == .mine

        if courses.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(courses) { course in
                        CourseListRow(course: course)
                            .onTapGesture { selectedCourse = course }
                            .contextMenu(isMine ? ContextMenu {
                                Button {
                                    courseForThumbnail = course
                                    showThumbnailPicker = true
                                } label: {
                                    Label("탐색탭 썸네일 변경", systemImage: "photo.on.rectangle.angled")
                                }
                                Button(role: .destructive) {
                                    courseToDelete = course
                                    showDeleteConfirm = true
                                } label: {
                                    Label("삭제", systemImage: "trash")
                                }
                            } : nil)
                    }
                }
                .padding(20)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: selectedTab == .liked ? "heart.slash" : "map.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.tteMediumGray.opacity(0.5))
            Text(selectedTab == .liked ? "좋아요한 코스가 없어요" : "아직 만든 코스가 없어요")
                .font(.system(size: 16))
                .foregroundColor(.tteMediumGray)
            Spacer()
        }
    }

    private var groupToolbarMenu: some View {
        GroupToolbarMenu()
            .environmentObject(authService)
            .environmentObject(roomService)
    }

    private func uploadThumbnail(from item: PhotosPickerItem?) async {
        guard let item, let course = courseForThumbnail else { return }
        defer {
            thumbnailPickerItem = nil
            courseForThumbnail = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            thumbnailResultMessage = "이미지를 불러오지 못했어요. 다시 시도해주세요."
            showThumbnailResult = true
            return
        }
        isUploadingThumbnail = true
        let url = await CourseThumbnailService.shared.upload(courseId: course.courseId, image: image)
        isUploadingThumbnail = false
        thumbnailResultMessage = url != nil
            ? "썸네일이 변경됐어요. 탐색탭에 곧 반영됩니다."
            : "업로드에 실패했어요. 네트워크 확인 후 다시 시도해주세요."
        showThumbnailResult = true
    }
}

// MARK: - GroupRoomList (그룹 탭 내용)
struct GroupRoomList: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @State private var showCreateRoom = false
    @State private var showJoinRoom = false
    @State private var selectedRoom: Room?

    var body: some View {
        Group {
            if roomService.myRooms.isEmpty {
                groupEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(roomService.myRooms) { room in
                            RoomCard(room: room)
                                .onTapGesture { selectedRoom = room }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationDestination(item: $selectedRoom) { room in
            RoomDetailView(room: room)
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
        .sheet(isPresented: $showCreateRoom) {
            CreateRoomView()
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
        .sheet(isPresented: $showJoinRoom) {
            JoinRoomView()
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCreateRoom)) { _ in showCreateRoom = true }
        .onReceive(NotificationCenter.default.publisher(for: .showJoinRoom)) { _ in showJoinRoom = true }
    }

    private var groupEmptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "person.3.fill")
                .font(.system(size: 52))
                .foregroundColor(.tteOrange.opacity(0.4))
            Text("아직 참여한 그룹이 없어요")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.tteDarkGray)
            Text("친구들과 함께 여행 코스를 공유하고\n투표로 최종 코스를 정해보세요!")
                .font(.system(size: 14))
                .foregroundColor(.tteMediumGray)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button { showCreateRoom = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("방 만들기").fontWeight(.semibold)
                    }
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .frame(height: 48).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.tteOrange))
                }
                Button { showJoinRoom = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "key.horizontal.fill")
                        Text("코드 입력").fontWeight(.semibold)
                    }
                    .font(.system(size: 15))
                    .foregroundColor(.tteOrange)
                    .frame(height: 48).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).stroke(Color.tteOrange, lineWidth: 1.5))
                }
            }
            .padding(.horizontal, 40)
            Spacer()
        }
    }
}

// MARK: - 툴바 메뉴 (그룹 탭일 때)
struct GroupToolbarMenu: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var roomService: RoomService

    var body: some View {
        Menu {
            Button {
                NotificationCenter.default.post(name: .showCreateRoom, object: nil)
            } label: {
                Label("방 만들기", systemImage: "plus.circle")
            }
            Button {
                NotificationCenter.default.post(name: .showJoinRoom, object: nil)
            } label: {
                Label("코드로 참여", systemImage: "key.horizontal")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.tteOrange)
        }
    }
}

extension Notification.Name {
    static let showCreateRoom = Notification.Name("showCreateRoom")
    static let showJoinRoom = Notification.Name("showJoinRoom")
}

struct CourseListRow: View {
    let course: Course
    @State private var photoURL: String?
    @State private var isLoading = true
    @State private var isAuthorVerified = false
    @State private var authorNickname: String = ""
    @EnvironmentObject private var userService: UserService

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 배경 사진
            if isLoading {
                cardLoadingPlaceholder
            } else if let urlStr = photoURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        cardFailurePlaceholder
                    default:
                        cardLoadingPlaceholder
                    }
                }
            } else {
                cardFailurePlaceholder
            }

            // 그라디언트
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )

            // 텍스트 콘텐츠
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(course.tag.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.tteOrange))
                    Text(course.region)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.2)))
                    if isAuthorVerified {
                        VerifiedBadge(creatorLabel: authorNickname)
                            .colorScheme(.dark)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill").font(.system(size: 12))
                        Text("\(course.likeCount)").font(.system(size: 12))
                    }
                    .foregroundColor(.white.opacity(0.85))
                    Button {
                        CourseShareHelper.share(course: course)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
                Text(course.courseName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 12))
                    Text(course.places.map(\.placeName).joined(separator: " → "))
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .foregroundColor(.white.opacity(0.75))
            }
            .padding(16)
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
        .task {
            async let photo: String? = {
                guard let name = course.places.first?.placeName else { return nil }
                return await PlacesPhotoService.shared.photoURL(for: name)
            }()
            async let author = userService.fetchAuthor(uid: course.authorId)
            let (p, a) = await (photo, author)
            photoURL = p
            isAuthorVerified = a?.isVerified ?? false
            authorNickname = a?.nickname ?? ""
            isLoading = false
        }
    }

    private var cardLoadingPlaceholder: some View {
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

    private var cardFailurePlaceholder: some View {
        ZStack {
            Color.tteOrange.opacity(0.06)
            Image("tteona-no-image")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 90)
        }
    }
}
