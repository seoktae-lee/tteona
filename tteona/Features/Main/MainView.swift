import SwiftUI
import MapKit

struct MainView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @State private var selectedCourse: Course?
    @State private var showCreateCourse = false
    @State private var selectedRegion: String? = nil
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
            let inRegion = mapRegion.contains(first.coordinate)
            let inTag = selectedRegion == nil || course.region == selectedRegion
            return inRegion && inTag
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer

            VStack(spacing: 0) {
                regionFilterBar
                    .padding(.bottom, 8)
                Spacer()
                courseCardList
            }

            createCourseButton
        }
        .ignoresSafeArea()
        .task { await courseService.fetchCourses() }
        .sheet(item: $selectedCourse) { course in
            CourseDetailView(course: course)
                .environmentObject(authService)
                .environmentObject(courseService)
        }
        .fullScreenCover(isPresented: $showCreateCourse) {
            CreateCourseView()
                .environmentObject(authService)
                .environmentObject(courseService)
        }
    }

    // MARK: - Map
    private var mapLayer: some View {
        MapReader { proxy in
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
    }

    // MARK: - Region Filter Bar
    private var regionFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "전체", isSelected: selectedRegion == nil) {
                    selectedRegion = nil
                }
                ForEach(courseRegions, id: \.self) { region in
                    FilterChip(title: region, isSelected: selectedRegion == region) {
                        selectedRegion = selectedRegion == region ? nil : region
                        if selectedRegion == region {
                            moveCameraToRegion(region)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 56)
        }
    }

    // MARK: - Course Card List
    @ViewBuilder
    private var courseCardList: some View {
        if courseService.isLoading || !visibleCourses.isEmpty {
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color(UIColor.tertiaryLabel))
                    .frame(width: 36, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 12)

                if courseService.isLoading {
                    ProgressView().frame(height: 160)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(visibleCourses) { course in
                                CourseCardView(course: course)
                                    .onTapGesture {
                                        selectedCourse = course
                                        moveCameraTo(course: course)
                                    }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.tteBackground)
                    .shadow(color: .black.opacity(0.1), radius: 16, y: -4)
            )
        }
    }

    // MARK: - Create Course Button
    private var createCourseButton: some View {
        VStack {
            Spacer()
            Button {
                showCreateCourse = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                    Text("코스 만들기")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Capsule().fill(Color.tteOrange))
                .shadow(color: .tteOrange.opacity(0.4), radius: 8, y: 4)
            }
            .padding(.bottom, visibleCourses.isEmpty ? 100 : 220)
        }
    }

    // MARK: - Helpers
    private func moveCameraTo(course: Course) {
        guard let first = course.places.first else { return }
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: first.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            ))
        }
    }

    private func moveCameraToRegion(_ region: String) {
        let coords: [String: CLLocationCoordinate2D] = [
            "서울": CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780),
            "부산": CLLocationCoordinate2D(latitude: 35.1796, longitude: 129.0756),
            "제주": CLLocationCoordinate2D(latitude: 33.4996, longitude: 126.5312),
            "경주": CLLocationCoordinate2D(latitude: 35.8562, longitude: 129.2247),
            "강릉": CLLocationCoordinate2D(latitude: 37.7519, longitude: 128.8760),
            "전주": CLLocationCoordinate2D(latitude: 35.8242, longitude: 127.1480),
        ]
        guard let coord = coords[region] else { return }
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)
            ))
        }
    }
}

// MARK: - Filter Chip
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .tteDarkGray)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isSelected ? Color.tteOrange : Color.tteBackground)
                )
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
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

// MARK: - Course Card
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
