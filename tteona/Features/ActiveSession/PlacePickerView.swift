import SwiftUI
import MapKit
import CoreLocation

struct PlacePickerView: View {
    let location: CLLocation
    let onSelect: (String) -> Void

    @State private var nearbyPlaces: [MKMapItem] = []
    @State private var isLoading = true
    @State private var customName = ""
    @State private var showCustomInput = false
    @FocusState private var customFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 핸들
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.tteMediumGray.opacity(0.4))
                .frame(width: 40, height: 4)
                .padding(.top, 12)

            Text("어디서 찍으셨나요?")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.tteDarkGray)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    if isLoading {
                        ProgressView()
                            .padding(40)
                    } else {
                        // 주변 장소 목록
                        ForEach(nearbyPlaces, id: \.self) { item in
                            PlaceRow(
                                name: item.name ?? "알 수 없음",
                                category: item.pointOfInterestCategory?.displayName,
                                distance: item.placemark.location.flatMap {
                                    location.distance(from: $0)
                                }
                            ) {
                                onSelect(item.name ?? "알 수 없음")
                            }
                            Divider().padding(.leading, 56)
                        }

                        // 직접 입력
                        if showCustomInput {
                            HStack(spacing: 14) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 16))
                                    .foregroundColor(.tteOrange)
                                    .frame(width: 28)

                                TextField("장소명 직접 입력", text: $customName)
                                    .font(.system(size: 15))
                                    .focused($customFocused)
                                    .submitLabel(.done)
                                    .onSubmit {
                                        let name = customName.trimmingCharacters(in: .whitespaces)
                                        guard !name.isEmpty else { return }
                                        onSelect(name)
                                    }

                                if !customName.isEmpty {
                                    Button {
                                        let name = customName.trimmingCharacters(in: .whitespaces)
                                        guard !name.isEmpty else { return }
                                        onSelect(name)
                                    } label: {
                                        Image(systemName: "arrow.right.circle.fill")
                                            .font(.system(size: 22))
                                            .foregroundColor(.tteOrange)
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                        } else {
                            Button {
                                showCustomInput = true
                                customFocused = true
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 16))
                                        .foregroundColor(.tteOrange)
                                        .frame(width: 28)
                                    Text("직접 입력하기")
                                        .font(.system(size: 15))
                                        .foregroundColor(.tteOrange)
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)
                            }
                        }
                    }
                }
            }
        }
        .task { await fetchNearbyPlaces() }
    }

    private func fetchNearbyPlaces() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "장소"
        request.resultTypes = [.pointOfInterest]
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 400,
            longitudinalMeters: 400
        )

        let results = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []

        // 200m 이내, 최대 8개, 거리순 정렬
        nearbyPlaces = results
            .filter { item in
                guard let loc = item.placemark.location else { return false }
                return location.distance(from: loc) <= 200
            }
            .sorted { a, b in
                let da = a.placemark.location.map { location.distance(from: $0) } ?? 9999
                let db = b.placemark.location.map { location.distance(from: $0) } ?? 9999
                return da < db
            }
            .prefix(8)
            .map { $0 }

        isLoading = false
    }
}

// MARK: - 장소 행
struct PlaceRow: View {
    let name: String
    let category: String?
    let distance: CLLocationDistance?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.tteOrange)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.tteDarkGray)
                        .lineLimit(1)
                    if let cat = category {
                        Text(cat)
                            .font(.system(size: 12))
                            .foregroundColor(.tteMediumGray)
                    }
                }

                Spacer()

                if let dist = distance {
                    Text(dist < 1000 ? "\(Int(dist))m" : String(format: "%.1fkm", dist / 1000))
                        .font(.system(size: 12))
                        .foregroundColor(.tteMediumGray)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
}

// MARK: - POI 카테고리 한국어
extension MKPointOfInterestCategory {
    var displayName: String {
        switch self {
        case .restaurant: return "음식점"
        case .cafe: return "카페"
        case .store: return "쇼핑"
        case .hotel: return "숙박"
        case .museum: return "박물관"
        case .park: return "공원"
        case .hospital: return "병원"
        case .school: return "학교"
        case .bank: return "은행"
        case .pharmacy: return "약국"
        case .gasStation: return "주유소"
        case .publicTransport: return "대중교통"
        case .theater: return "공연장"
        case .nightlife: return "나이트라이프"
        case .fitnessCenter: return "피트니스"
        case .laundry: return "세탁소"
        default: return "장소"
        }
    }
}
