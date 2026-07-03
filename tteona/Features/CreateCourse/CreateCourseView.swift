import SwiftUI
import GoogleMaps
import CoreLocation
import PhotosUI

struct CreateCourseView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var courseService: CourseService
    @Environment(\.dismiss) private var dismiss

    @State private var courseName = ""
    @State private var selectedTag: CourseTag = .couple
    @State private var places: [Place] = []
    @State private var mainPlaceName: String?   // 유저가 지정한 대표 장소 (nil이면 자동 선택)
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showPlaceSearch = false
    @State private var thumbnailItem: PhotosPickerItem?
    @State private var thumbnailImage: UIImage?
    @State private var mapCenter: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
    @State private var cameraCommand: GMSCameraPosition?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    nameSection
                    tagSection
                    mapPreviewSection
                    placesSection
                    thumbnailSection
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
            PlaceSearchView(places: $places, mapCenter: mapCenter)
        }
        .onChange(of: places) { _, newPlaces in
            updateMapCamera(places: newPlaces)
        }
        .onChange(of: thumbnailItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run { thumbnailImage = img }
                }
            }
        }
    }

    // MARK: - 대표 이미지 (탐색 탭 썸네일)
    private var thumbnailSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("대표 이미지")
            Text("탐색 탭에 노출될 코스 커버 이미지예요. 건너뛰면 기본 이미지가 사용돼요.")
                .font(.system(size: 12))
                .foregroundColor(.tteMediumGray)

            PhotosPicker(selection: $thumbnailItem, matching: .images) {
                if let thumbnailImage {
                    ZStack(alignment: .bottomTrailing) {
                        Image(uiImage: thumbnailImage)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                            Text("변경")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(12)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 32))
                            .foregroundColor(.tteOrange.opacity(0.6))
                        Text("갤러리에서 대표 이미지 선택")
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
            }
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

            GoogleMapView(
                markers: places.map { GoogleMapMarker(id: $0.id, coordinate: $0.coordinate, badgeNumber: $0.order) },
                polyline: places.count >= 2 ? places.map(\.coordinate) : nil,
                initialCamera: GMSCameraPosition(latitude: 37.5665, longitude: 126.9780, zoom: 11),
                interactive: false,
                cameraCommand: $cameraCommand,
                onCameraIdle: { pos in mapCenter = pos.target }
            )
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 16))
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
                Text("📍 핀을 눌러 지도 핀·썸네일 기준이 될 대표 장소를 정하세요 (미지정 시 자동 선택)")
                    .font(.system(size: 12))
                    .foregroundColor(.tteMediumGray)
                    .padding(.horizontal, 2)
                ForEach(Array(places.enumerated()), id: \.element.id) { idx, place in
                    PlaceRowEdit(
                        place: place,
                        isMain: place.placeName == effectiveMainName,
                        onSetMain: { mainPlaceName = place.placeName },
                        onDelete: {
                            if mainPlaceName == place.placeName { mainPlaceName = nil }
                            places.remove(at: idx)
                            reorderPlaces()
                        }
                    )
                }
                .onMove { from, to in
                    places.move(fromOffsets: from, toOffset: to)
                    reorderPlaces()
                }
            }
        }
    }

    // 현재 화면에 표시할 대표 장소명 — 수동 지정이 유효하면 그것, 아니면 자동 선택
    private var effectiveMainName: String? {
        if let n = mainPlaceName, places.contains(where: { $0.placeName == n }) { return n }
        return Course.autoPickMainPlace(places)?.placeName
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
            cameraCommand = GMSCameraPosition(latitude: places[0].latitude, longitude: places[0].longitude, zoom: 14)
        } else {
            cameraCommand = GoogleMapView.fittingCamera(for: places.map(\.coordinate))
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

        // 콘텐츠 모더레이션 (서버 검사, 네트워크 실패 시 통과)
        guard await StatsService.shared.isTextAllowed(name) else {
            errorMessage = "코스 이름에 부적절한 표현이 포함되어 있어요."
            isSaving = false
            return
        }

        // 유저가 대표 장소를 직접 지정했을 때만 order 저장 (미지정 시 nil → 자동 선택)
        let mainOrder: Int? = mainPlaceName.flatMap { n in places.first(where: { $0.placeName == n })?.order }

        let course = Course(
            courseId: UUID().uuidString,
            authorId: authService.currentUser?.uid ?? "",
            courseName: name,
            tag: selectedTag,
            region: regionFromPlaces(places),
            likeCount: 0,
            createdAt: Date(),
            places: places,
            mainPlaceOrder: mainOrder
        )

        do {
            try await courseService.saveCourse(course)
            // 대표 이미지가 선택됐으면 WAS에 업로드 (실패해도 코스 저장은 유지)
            if let thumbnailImage {
                await CourseThumbnailService.shared.upload(courseId: course.courseId, image: thumbnailImage)
            }
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
    var isMain: Bool = false
    var onSetMain: () -> Void = {}
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
                if isMain {
                    Text("대표 장소")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.tteOrange)
                }
            }

            Spacer()

            Button(action: onSetMain) {
                Image("tteona-pin")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .opacity(isMain ? 1.0 : 0.28)
                    .grayscale(isMain ? 0 : 1)
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red.opacity(0.7))
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.tteOrange.opacity(isMain ? 0.5 : 0), lineWidth: 1.5)
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
