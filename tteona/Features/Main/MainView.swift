import SwiftUI
import MapKit

struct MainView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @State private var selectedCourse: Course?
    @State private var showCreateCourse = false
    @State private var showImpromptu = false
    @State private var searchedRegionName: String? = nil
    @State private var showRegionSearch = false
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 36.5, longitude: 127.8),
        span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
    )
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 36.5, longitude: 127.8),
            span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
        )
    )

    private var visibleCourses: [Course] {
        courseService.courses.filter { course in
            guard let first = course.places.first else { return false }
            return mapRegion.contains(first.coordinate)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
            topBar
            createCourseButton
        }
        .ignoresSafeArea()
        .task { await courseService.fetchCourses() }
        .sheet(item: $selectedCourse) { course in
            CourseDetailView(course: course)
                .environmentObject(authService)
                .environmentObject(courseService)
                .environmentObject(userService)
        }
        .sheet(isPresented: $showRegionSearch) {
            RegionSearchView { name, coord in
                searchedRegionName = name
                withAnimation {
                    cameraPosition = .region(MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    ))
                }
            }
        }
        .fullScreenCover(isPresented: $showCreateCourse) {
            CreateCourseView()
                .environmentObject(authService)
                .environmentObject(courseService)
        }
        .fullScreenCover(isPresented: $showImpromptu) {
            ImpromptuSessionView()
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(courseService)
                .environmentObject(roomService)
        }
    }

    // MARK: - Map
    private var mapLayer: some View {
        Map(position: $cameraPosition) {
            ForEach(visibleCourses) { course in
                if let first = course.places.first {
                    Annotation(course.courseName, coordinate: first.coordinate) {
                        CourseMapPin(course: course)
                            .onTapGesture {
                                withAnimation { selectedCourse = course }
                            }
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .onMapCameraChange { context in
            mapRegion = context.region
        }
    }

    // MARK: - Top Bar
    private var topBar: some View {
        VStack {
            HStack(spacing: 10) {
                // 지역 검색 버튼
                Button {
                    showRegionSearch = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .medium))
                        Text(searchedRegionName ?? "지역 검색")
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                        if searchedRegionName != nil {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.tteMediumGray)
                                .onTapGesture {
                                    searchedRegionName = nil
                                    cameraPosition = .region(MKCoordinateRegion(
                                        center: CLLocationCoordinate2D(latitude: 36.5, longitude: 127.8),
                                        span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
                                    ))
                                }
                        }
                    }
                    .foregroundColor(searchedRegionName != nil ? .tteOrange : .tteDarkGray)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color.tteBackground)
                            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                    )
                }

                Spacer()

                // 코스 만들기
                Button {
                    showCreateCourse = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("코스 만들기")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.tteDarkGray)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color.tteBackground)
                            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                    )
                }

            }
            .padding(.horizontal, 16)
            .padding(.top, 56)

            Spacer()
        }
    }

    // MARK: - Bottom Buttons
    private var createCourseButton: some View {
        VStack {
            Spacer()
            Button {
                showImpromptu = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 17, weight: .semibold))
                    Text("나의 오늘")
                        .font(.system(size: 17, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
                .background(
                    Capsule()
                        .fill(Color.tteOrange)
                        .shadow(color: .tteOrange.opacity(0.45), radius: 12, y: 4)
                )
            }
            .padding(.bottom, 104)
        }
    }

}

// MARK: - Map Pin
struct CourseMapPin: View {
    let course: Course

    var body: some View {
        VStack(spacing: 0) {
            Text(course.tag.emoji)
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.tteOrange).shadow(color: .tteOrange.opacity(0.4), radius: 4))
            Triangle()
                .fill(Color.tteOrange)
                .frame(width: 10, height: 6)
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.closeSubpath()
        }
    }
}

// MARK: - Course Card (나의 코스 탭용으로 유지)
struct CourseCardView: View {
    let course: Course

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
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
            }
            Text(course.courseName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.tteDarkGray)
                .lineLimit(2)
            HStack(spacing: 4) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundColor(.tteMediumGray)
                    .font(.system(size: 13))
                Text("\(course.places.count)곳")
                    .font(.system(size: 13))
                    .foregroundColor(.tteMediumGray)
                Spacer()
                Image(systemName: "heart.fill")
                    .foregroundColor(.red.opacity(0.8))
                    .font(.system(size: 13))
                Text("\(course.likeCount)")
                    .font(.system(size: 13))
                    .foregroundColor(.tteMediumGray)
            }
        }
        .padding(16)
        .frame(width: 220)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemBackground)))
    }
}

extension MKCoordinateRegion {
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let latOK = abs(coordinate.latitude - center.latitude) <= span.latitudeDelta / 2
        let lonOK = abs(coordinate.longitude - center.longitude) <= span.longitudeDelta / 2
        return latOK && lonOK
    }
}

#Preview {
    MainView()
        .environmentObject(AuthService())
        .environmentObject(CourseService())
}
