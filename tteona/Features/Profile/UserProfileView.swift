import SwiftUI

// MARK: - 다른 유저 프로필
/// 검색·코스에서 진입하는 타인의 공간 — 발자취 지도 + 올린 코스.
/// 여행 기록 타임라인(코스명·날짜)은 사생활이라 본인 프로필에서만 보여준다.
struct UserProfileView: View {
    let user: AppUser

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var roomService: RoomService

    @State private var summary = FootprintSummary()
    @State private var routes: [[FootprintPoint]] = []
    @State private var courses: [Course] = []
    @State private var thumbnails: [String: String] = [:]
    @State private var isLoaded = false
    @State private var selectedCourse: Course? = nil
    @State private var showBlockAlert = false
    @State private var isBlocked = false

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                header
                footprintSection
                coursesSection
            }
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Color.tteBackground)
        .navigationTitle(user.nickname)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showBlockAlert = true
                    } label: {
                        Label(L("profile.block"), systemImage: "person.crop.circle.badge.xmark")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.tte(15, .semibold))
                        .foregroundColor(.tteDarkGray)
                }
            }
        }
        .alert(L("profile.block"), isPresented: $showBlockAlert) {
            Button(L("profile.block"), role: .destructive) { blockUser() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("profile.block.confirm", user.nickname))
        }
        .sheet(item: $selectedCourse) { course in
            CourseDetailView(course: course)
                .environmentObject(authService)
                .environmentObject(courseService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
        .task { await load() }
    }

    private func load() async {
        guard !isLoaded else { return }
        async let summaryTask = FootprintService.shared.fetchSummary(userId: user.uid)
        async let recordsTask = FootprintService.shared.fetchFootprints(userId: user.uid)
        async let coursesTask = FootprintService.shared.fetchCourses(authorId: user.uid)
        async let thumbsTask = CourseThumbnailService.shared.fetchAllThumbnails()
        summary = await summaryTask
        routes = await recordsTask.map(\.points)
        courses = await coursesTask
        thumbnails = await thumbsTask
        isLoaded = true
    }

    private func blockUser() {
        guard let myUid = authService.currentUser?.uid else { return }
        Task {
            try? await userService.blockUser(uid: myUid, blockedUid: user.uid)
            isBlocked = true
            Haptics.light()
        }
    }

    // MARK: - 헤더

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.tteOrange.opacity(0.12))
                    .frame(width: 84, height: 84)
                if let urlString = user.profileImageUrl, let url = URL(string: urlString) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        initialLetter
                    }
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())
                } else {
                    initialLetter
                }
            }
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(user.nickname)
                        .font(.tte(21, .bold))
                        .foregroundColor(.tteDarkGray)
                    if user.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.tte(15))
                            .foregroundColor(.tteOrange)
                    }
                }
                if let label = user.creatorLabel, !label.isEmpty {
                    Text(label)
                        .font(.tte(12, .semibold))
                        .foregroundColor(.tteOrange)
                }
                if isBlocked {
                    Text(L("profile.blocked"))
                        .font(.tte(12, .semibold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.red.opacity(0.1)))
                }
            }

            // 발자취 요약 배지
            HStack(spacing: 14) {
                summaryBadge(count: summary.sigCodes.count, label: L("profile.stats.regions"))
                summaryBadge(count: summary.countryCodes.count, label: L("profile.stats.countries"))
                summaryBadge(count: courses.count, label: L("profile.stats.courses"))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private var initialLetter: some View {
        Text(String(user.nickname.prefix(1)))
            .font(.tte(32, .semibold))
            .foregroundColor(.tteOrange)
    }

    private func summaryBadge(count: Int, label: String) -> some View {
        HStack(spacing: 5) {
            Text("\(count)")
                .font(.tte(15, .bold))
                .foregroundColor(.tteDarkGray)
            Text(label)
                .font(.tte(12))
                .foregroundColor(.tteMediumGray)
        }
        .padding(.horizontal, 13).padding(.vertical, 7)
        .background(Capsule().fill(Color(UIColor.secondarySystemBackground)))
    }

    // MARK: - 발자취 지도

    private var footprintSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("profile.footprint.of", user.nickname))
                .font(.tte(18, .bold))
                .foregroundColor(.tteDarkGray)
                .padding(.horizontal, 20)

            FootprintMapView(
                summary: summary,
                routes: routes,
                interactive: true,
                initialFocus: initialFocus
            )
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color(hex: "#E8E2D6"), lineWidth: 1)
            )
            .padding(.horizontal, 20)
        }
    }

    /// 상대의 발자취가 있는 곳을 처음부터 보여준다 (한국 우선)
    private var initialFocus: FootprintMapFocus {
        if !summary.sigCodes.isEmpty { return .korea }
        if let country = summary.countryCodes.first(where: { $0 != "KOR" }) {
            return .country(country)
        }
        return summary.countryCodes.contains("KOR") ? .korea : .world
    }

    // MARK: - 올린 코스

    private var coursesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("profile.courses"))
                .font(.tte(18, .bold))
                .foregroundColor(.tteDarkGray)
                .padding(.horizontal, 20)

            if !isLoaded {
                ProgressView().tint(.tteOrange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else if courses.isEmpty {
                Text(L("profile.courses.empty"))
                    .font(.tte(13))
                    .foregroundColor(.tteMediumGray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(courses) { course in
                        ProfileCourseCard(course: course,
                                          thumbnailURL: thumbnails[course.courseId])
                            .onTapGesture { selectedCourse = course }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

// MARK: - 프로필 코스 카드 (3:4, 탐색탭 카드 축소판)
private struct ProfileCourseCard: View {
    let course: Course
    let thumbnailURL: String?

    @State private var placePhotoURL: String?

    var body: some View {
        Color(UIColor.secondarySystemBackground)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                thumbnailImage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.8)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 80)
                    .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(course.courseName)
                        .font(.tte(13, .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    HStack(spacing: 5) {
                        Text("\(course.region) · \(course.tag.displayName)")
                            .font(.tte(10))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        HStack(spacing: 2) {
                            Image(systemName: "heart.fill").font(.tte(9))
                            Text("\(course.likeCount)").font(.tte(10, .semibold))
                        }
                        .foregroundColor(.white.opacity(0.95))
                    }
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .task {
                guard thumbnailURL == nil, placePhotoURL == nil,
                      let main = course.mainPlace else { return }
                placePhotoURL = await PlacesPhotoService.shared.photoURL(
                    for: main.placeName, latitude: main.latitude, longitude: main.longitude)
            }
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let url = (thumbnailURL ?? placePhotoURL).flatMap(URL.init) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    DefaultCourseThumbnail(compact: true)
                default:
                    Color(UIColor.secondarySystemBackground)
                }
            }
        } else {
            DefaultCourseThumbnail(compact: true)
        }
    }
}
