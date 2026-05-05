import SwiftUI
import MapKit

struct MainView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @State private var selectedCourse: Course?
    @State private var showCreateCourse = false
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 36.5, longitude: 127.8),
            span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
        )
    )

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer

            VStack(spacing: 0) {
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
        Map(position: $cameraPosition) {
            ForEach(courseService.courses) { course in
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
    }

    // MARK: - Course Card List
    private var courseCardList: some View {
        VStack(spacing: 0) {
            // 상단 핸들
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color(UIColor.tertiaryLabel))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 12)

            if courseService.isLoading {
                ProgressView()
                    .frame(height: 160)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(courseService.courses) { course in
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

    // MARK: - Create Course Button
    private var createCourseButton: some View {
        VStack {
            HStack {
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
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .background(
                        Capsule().fill(Color.tteOrange)
                    )
                    .shadow(color: .tteOrange.opacity(0.4), radius: 8, y: 4)
                }
                .padding(.trailing, 20)
            }
            Spacer()
                .frame(height: 220)
        }
    }

    private func moveCameraTo(course: Course) {
        guard let first = course.places.first else { return }
        withAnimation {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: first.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
            )
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
                .background(
                    Circle()
                        .fill(Color.tteOrange)
                        .shadow(color: .tteOrange.opacity(0.4), radius: 4)
                )

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
                    .background(
                        Capsule().fill(Color.tteOrange.opacity(0.12))
                    )

                Text(course.region)
                    .font(.system(size: 12))
                    .foregroundColor(.tteMediumGray)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color(UIColor.tertiarySystemBackground))
                    )

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
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
}

#Preview {
    MainView()
        .environmentObject(AuthService())
        .environmentObject(CourseService())
}
