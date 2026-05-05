import SwiftUI
import MapKit

struct CreateCourseView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @Environment(\.dismiss) private var dismiss

    @State private var courseName = ""
    @State private var selectedTag: CourseTag = .couple
    @State private var selectedRegion = courseRegions[0]
    @State private var places: [Place] = []
    @State private var newPlaceName = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showMapPicker = false
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    )
    @State private var pendingCoordinate: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    nameSection
                    tagSection
                    regionSection
                    mapPickerSection
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
    }

    // MARK: - Name
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("코스 이름")
            TteTextField(placeholder: "코스 이름을 입력하세요", text: $courseName)
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

    // MARK: - Region
    private var regionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("지역")
            Menu {
                ForEach(courseRegions, id: \.self) { region in
                    Button(region) { selectedRegion = region }
                }
            } label: {
                HStack {
                    Text(selectedRegion)
                        .foregroundColor(.tteDarkGray)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .foregroundColor(.tteMediumGray)
                        .font(.system(size: 14))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(UIColor.secondarySystemBackground))
                )
            }
        }
    }

    // MARK: - Map Picker
    private var mapPickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("지도에서 장소 추가")

            ZStack(alignment: .bottomTrailing) {
                Map(position: $cameraPosition) {
                    ForEach(places) { place in
                        Annotation(place.placeName, coordinate: place.coordinate) {
                            PlacePin(order: place.order)
                        }
                    }
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .onTapGesture { location in
                    // MapKit onTapGesture coordinate 변환은 MapReader 필요
                }
                .overlay(
                    Text("지도를 탭하여 장소 추가")
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.5)))
                        .padding(12),
                    alignment: .bottom
                )
            }

            // 장소 이름 입력 + 추가 버튼
            HStack(spacing: 10) {
                TteTextField(placeholder: "장소 이름 입력", text: $newPlaceName)

                Button {
                    addPlace()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.tteOrange)
                }
                .disabled(newPlaceName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Places List
    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("장소 목록 (\(places.count)곳)")

            if places.isEmpty {
                Text("아직 추가된 장소가 없어요")
                    .font(.system(size: 14))
                    .foregroundColor(.tteMediumGray)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(Array(places.enumerated()), id: \.element.id) { idx, place in
                    HStack(spacing: 12) {
                        Text("\(idx + 1)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.tteOrange))

                        Text(place.placeName)
                            .font(.system(size: 15))
                            .foregroundColor(.tteDarkGray)

                        Spacer()

                        Button {
                            removePlace(at: idx)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundColor(.red.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(UIColor.secondarySystemBackground))
                    )
                }
                .onMove { from, to in
                    places.move(fromOffsets: from, toOffset: to)
                    reorderPlaces()
                }
            }
        }
    }

    // MARK: - Actions
    private func addPlace() {
        let name = newPlaceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        // 현재 지도 중심 좌표를 기본값으로 사용
        let coordinate = CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)

        let place = Place(
            order: places.count + 1,
            placeName: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        places.append(place)
        newPlaceName = ""
    }

    private func removePlace(at index: Int) {
        places.remove(at: index)
        reorderPlaces()
    }

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

    private func saveCourse() async {
        let name = courseName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            errorMessage = "코스 이름을 입력해주세요."
            return
        }
        guard places.count >= 1 else {
            errorMessage = "장소를 1곳 이상 추가해주세요."
            return
        }

        isSaving = true
        errorMessage = nil

        let course = Course(
            courseId: UUID().uuidString,
            authorId: authService.currentUser?.uid ?? "",
            courseName: name,
            tag: selectedTag,
            region: selectedRegion,
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
