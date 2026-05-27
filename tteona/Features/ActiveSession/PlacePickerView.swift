import SwiftUI
import MapKit
import CoreLocation

struct PlacePickerView: View {
    let location: CLLocation
    let onSelect: (String) -> Void

    @State private var nearbyPlaces: [KakaoNearbyPlace] = []
    @State private var isLoading = true
    @State private var customName = ""
    @State private var showCustomInput = false
    @State private var isPreciseLocation: Bool = true
    @FocusState private var customFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.tteMediumGray.opacity(0.4))
                .frame(width: 40, height: 4)
                .padding(.top, 12)

            Text("어디서 찍으셨나요?")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.tteDarkGray)
                .padding(.top, 16)
                .padding(.bottom, 12)

            SwiftUI.Divider()

            // 정확한 위치 꺼져있을 때 안내 배너
            if !isPreciseLocation {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "location.slash.fill")
                            .foregroundColor(.tteOrange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("정확한 위치가 꺼져 있어요")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.tteDarkGray)
                            Text("설정에서 켜면 주변 장소를 더 정확하게 찾아요")
                                .font(.system(size: 12))
                                .foregroundColor(.tteMediumGray)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.tteMediumGray)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.tteOrange.opacity(0.07))
                }
                SwiftUI.Divider()
            }

            ScrollView {
                VStack(spacing: 0) {
                    // 직접 입력 (상단 고정)
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

                    SwiftUI.Divider()

                    if isLoading {
                        ProgressView()
                            .padding(40)
                    } else {
                        ForEach(nearbyPlaces, id: \.placeName) { place in
                            PlacePickerRow(
                                name: place.placeName,
                                category: place.categoryName.components(separatedBy: " > ").last,
                                distance: Double(place.distance)
                            ) {
                                onSelect(place.placeName)
                            }
                            SwiftUI.Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        }
        .task { await fetchNearbyPlaces() }
    }

    private func fetchNearbyPlaces() async {
        // 정확한 위치 권한 직접 체크 (일시적 GPS 신호 문제와 구분)
        let manager = CLLocationManager()
        isPreciseLocation = manager.accuracyAuthorization == .fullAccuracy

        let lat = location.coordinate.latitude
        let lng = location.coordinate.longitude
        // 카카오 카테고리 코드: MT1(대형마트) CS2(편의점) SW8(지하철) BK9(은행) OL7(주유소)
        // PO3(공공기관) AT4(관광명소) AD5(숙박) FD6(음식점) CE7(카페) HP8(병원) PM9(약국)
        let categories = ["FD6", "CE7", "AT4", "AD5", "MT1", "CS2", "SW8"]
        var seen = Set<String>()
        var collected: [KakaoNearbyPlace] = []

        // 역지오코딩으로 건물/아파트명 먼저 추가 (가장 위)
        if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first,
           let name = placemark.name {
            collected.append(KakaoNearbyPlace(placeName: name, categoryName: "현재 위치", distance: "0", x: "\(lng)", y: "\(lat)"))
            seen.insert(name)
        }

        await withTaskGroup(of: [KakaoNearbyPlace].self) { group in
            for code in categories {
                group.addTask {
                    await Self.fetchKakaoCategory(code: code, lat: lat, lng: lng, radius: 200)
                }
            }
            for await places in group {
                for place in places {
                    guard !seen.contains(place.placeName) else { continue }
                    seen.insert(place.placeName)
                    collected.append(place)
                }
            }
        }

        nearbyPlaces = collected.sorted { (Double($0.distance) ?? 9999) < (Double($1.distance) ?? 9999) }
        isLoading = false
    }

    private static func fetchKakaoCategory(code: String, lat: Double, lng: Double, radius: Int) async -> [KakaoNearbyPlace] {
        let key = "b31c03c128d37a877e6cb407f59b8911"
        let urlStr = "https://dapi.kakao.com/v2/local/search/category.json?category_group_code=\(code)&x=\(lng)&y=\(lat)&radius=\(radius)&size=5&sort=distance"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("KakaoAK \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return [] }
        return (try? JSONDecoder().decode(KakaoCategoryResponse.self, from: data))?.documents.map { $0.asNearbyPlace } ?? []
    }
}

// MARK: - 장소 행
struct PlacePickerRow: View {
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

// MARK: - Kakao 응답 모델
struct KakaoNearbyPlace {
    let placeName: String
    let categoryName: String
    let distance: String
    let x: String
    let y: String
}

struct KakaoCategoryResponse: Decodable {
    let documents: [KakaoCategoryPlace]
}

struct KakaoCategoryPlace: Decodable {
    let placeName: String
    let categoryName: String
    let distance: String
    let x: String
    let y: String

    enum CodingKeys: String, CodingKey {
        case placeName = "place_name"
        case categoryName = "category_name"
        case distance, x, y
    }
}

extension KakaoCategoryPlace {
    var asNearbyPlace: KakaoNearbyPlace {
        KakaoNearbyPlace(placeName: placeName, categoryName: categoryName, distance: distance, x: x, y: y)
    }
}
