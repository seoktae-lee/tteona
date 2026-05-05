import SwiftUI
import MapKit

struct CreateCourseView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @Environment(\.dismiss) private var dismiss

    @State private var courseName = ""
    @State private var selectedTag: CourseTag = .couple
    @State private var places: [Place] = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showPlaceSearch = false
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    nameSection
                    tagSection
                    mapPreviewSection
                    placesSection
                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .navigationTitle("코스 만들기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") { dismiss() }
                        .foregroundColor(.tteDarkGray)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await saveCourse() }
                    } label: {
                        if isSaving {
                            ProgressView().tint(.tteOrange)
                        } else {
                            Text("등록")
                                .fontWeight(.semibold)
                                .foregroundColor(.tteOrange)
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .sheet(isPresented: $showPlaceSearch) {
            PlaceSearchView(places: $places)
        }
        .onChange(of: places) { _, newPlaces in
            updateMapCamera(places: newPlaces)
        }
    }

    // MARK: - Name
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("코스 이름")
            TteTextField(placeholder: "예) 홍대 감성 데이트 코스", text: $courseName)
        }
    }

    // MARK: - Tag
    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("태그")
            HStack(spacing: 10) {
                ForEach(CourseTag.allCases, id: \.self) { tag in
                    Button {
                        selectedTag = tag
                    } label: {
                        Text(tag.rawValue)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(selectedTag == tag ? .white : .tteDarkGray)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(selectedTag == tag ? Color.tteOrange : Color(UIColor.secondarySystemBackground))
                            )
                    }
                }
            }
        }
    }

    // MARK: - Map Preview
    private var mapPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("코스 지도 미리보기")

            Map(position: $cameraPosition) {
                ForEach(places) { place in
                    Annotation(place.placeName, coordinate: place.coordinate) {
                        PlacePin(order: place.order)
                    }
                }
                if places.count >= 2 {
                    MapPolyline(coordinates: places.map(\.coordinate))
                        .stroke(Color.tteOrange, lineWidth: 2)
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .disabled(true)
        }
    }

    // MARK: - Places
    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("장소 목록 (\(places.count)곳)")
                Spacer()
                Button {
                    showPlaceSearch = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("장소 추가")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.tteOrange)
                }
            }

            if places.isEmpty {
                Button {
                    showPlaceSearch = true
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 32))
                            .foregroundColor(.tteOrange.opacity(0.6))
                        Text("장소를 추가해서 코스를 만들어보세요")
                            .font(.system(size: 14))
                            .foregroundColor(.tteMediumGray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.tteOrange.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    )
                }
            } else {
                ForEach(Array(places.enumerated()), id: \.element.id) { idx, place in
                    PlaceRowEdit(place: place) {
                        places.remove(at: idx)
                        reorderPlaces()
                    }
                }
                .onMove { from, to in
                    places.move(fromOffsets: from, toOffset: to)
                    reorderPlaces()
                }
            }
        }
    }

    // MARK: - Helpers
    private func reorderPlaces() {
        for i in places.indices {
            places[i] = Place(
                order: i + 1,
                placeName: places[i].placeName,
                latitude: places[i].latitude,
                longitude: places[i].longitude
            )
        }
    }

    private func updateMapCamera(places: [Place]) {
        guard !places.isEmpty else { return }
        if places.count == 1 {
            cameraPosition = .region(MKCoordinateRegion(
                center: places[0].coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
        } else {
            let lats = places.map(\.latitude)
            let lons = places.map(\.longitude)
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2,
                    longitude: ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: max(((lats.max() ?? 0) - (lats.min() ?? 0)) * 2, 0.02),
                    longitudeDelta: max(((lons.max() ?? 0) - (lons.min() ?? 0)) * 2, 0.02)
                )
            ))
        }
    }

    private func regionFromPlaces(_ places: [Place]) -> String {
        guard let first = places.first else { return "기타" }
        let geocoder = CLGeocoder()
        // 저장 시 지역을 첫 번째 장소의 시/도로 자동 추출
        // 비동기 처리가 복잡하므로 좌표 기반으로 간단히 추정
        let lat = first.latitude
        let lon = first.longitude
        if lat > 37.4 && lat < 37.7 && lon > 126.7 && lon < 127.2 { return "서울" }
        if lat > 35.0 && lat < 35.3 && lon > 128.9 && lon < 129.3 { return "부산" }
        if lat > 33.1 && lat < 33.6 && lon > 126.1 && lon < 126.9 { return "제주" }
        if lat > 35.7 && lat < 36.0 && lon > 129.1 && lon < 129.4 { return "경주" }
        if lat > 37.7 && lat < 37.9 && lon > 128.8 && lon < 129.0 { return "강릉" }
        if lat > 35.7 && lat < 35.9 && lon > 126.9 && lon < 127.2 { return "전주" }
        return "기타"
    }

    private func saveCourse() async {
        let name = courseName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { errorMessage = "코스 이름을 입력해주세요."; return }
        guard places.count >= 2 else { errorMessage = "장소를 2곳 이상 추가해주세요."; return }

        isSaving = true
        errorMessage = nil

        let course = Course(
            courseId: UUID().uuidString,
            authorId: authService.currentUser?.uid ?? "",
            courseName: name,
            tag: selectedTag,
            region: regionFromPlaces(places),
            likeCount: 0,
            createdAt: Date(),
            places: places
        )

        do {
            try await courseService.saveCourse(course)
            dismiss()
        } catch {
            errorMessage = "저장에 실패했습니다. 다시 시도해주세요."
        }
        isSaving = false
    }
}

// MARK: - Place Row (Edit Mode)
struct PlaceRowEdit: View {
    let place: Place
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.tteMediumGray)
                .font(.system(size: 14))

            Text("\(place.order)")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.tteOrange))

            VStack(alignment: .leading, spacing: 2) {
                Text(place.placeName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.tteDarkGray)
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red.opacity(0.7))
                    .font(.system(size: 20))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.tteDarkGray)
    }
}

#Preview {
    CreateCourseView()
        .environmentObject(AuthService())
        .environmentObject(CourseService())
}
