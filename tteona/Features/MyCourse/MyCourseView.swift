import SwiftUI

struct MyCourseView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @State private var selectedTab: MyCourseTab = .liked
    @State private var selectedCourse: Course?

    enum MyCourseTab: String, CaseIterable {
        case liked = "좋아요한 코스"
        case mine = "내가 만든 코스"
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
                courseList
            }
            .navigationTitle("나의 코스")
            .navigationBarTitleDisplayMode(.large)
        }
        .sheet(item: $selectedCourse) { course in
            CourseDetailView(course: course)
                .environmentObject(authService)
                .environmentObject(courseService)
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
    private var courseList: some View {
        let courses = selectedTab == .liked ? likedCourses : myCourses

        if courses.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(courses) { course in
                        CourseListRow(course: course)
                            .onTapGesture { selectedCourse = course }
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
}

struct CourseListRow: View {
    let course: Course

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
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

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .foregroundColor(.red.opacity(0.8))
                        .font(.system(size: 12))
                    Text("\(course.likeCount)")
                        .font(.system(size: 12))
                        .foregroundColor(.tteMediumGray)
                }
            }

            Text(course.courseName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.tteDarkGray)

            HStack(spacing: 4) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundColor(.tteMediumGray)
                    .font(.system(size: 13))
                Text(course.places.map(\.placeName).joined(separator: " → "))
                    .font(.system(size: 13))
                    .foregroundColor(.tteMediumGray)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
}
