import Foundation
import MapKit
import Combine
import CoreLocation

@MainActor
class PlaceSearchService: ObservableObject {
    @Published var results: [SearchResult] = []
    @Published var isSearching = false

    private let kakaoAPIKey = "b31c03c128d37a877e6cb407f59b8911"
    private var debounceTask: Task<Void, Never>?

    struct SearchResult: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let address: String
        let latitude: Double
        let longitude: Double
    }

    var searchCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 36.5, longitude: 127.8)

    func searchDebounced(_ query: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled {
                await search(query)
            }
        }
    }

    func search(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; return }

        isSearching = true

        if isKorea(searchCoordinate) {
            await searchKakao(q)
            if results.isEmpty {
                await searchMapKit(q)
            }
        } else {
            await searchMapKit(q)
        }

        isSearching = false
    }

    private func searchKakao(_ query: String) async {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://dapi.kakao.com/v2/local/search/keyword.json?query=\(encoded)&size=15") else { return }

        var request = URLRequest(url: url)
        request.setValue("KakaoAK \(kakaoAPIKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[Kakao] status: \(statusCode), query: \(query)")
            print("[Kakao] response: \(String(data: data, encoding: .utf8) ?? "nil")")
            let decoded = try JSONDecoder().decode(KakaoSearchResponse.self, from: data)
            results = decoded.documents.map {
                SearchResult(
                    name: $0.placeName,
                    address: $0.addressName,
                    latitude: Double($0.y) ?? 0,
                    longitude: Double($0.x) ?? 0
                )
            }
            print("[Kakao] results count: \(results.count)")
        } catch {
            print("[Kakao] error: \(error)")
            results = []
        }
    }

    private func searchMapKit(_ query: String) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]

        do {
            let response = try await MKLocalSearch(request: request).start()
            results = response.mapItems.map {
                let address = [$0.placemark.administrativeArea, $0.placemark.locality, $0.placemark.thoroughfare]
                    .compactMap { $0 }.joined(separator: " ")
                return SearchResult(
                    name: $0.name ?? "",
                    address: address,
                    latitude: $0.placemark.coordinate.latitude,
                    longitude: $0.placemark.coordinate.longitude
                )
            }
        } catch {
            results = []
        }
    }

    private func isKorea(_ coord: CLLocationCoordinate2D) -> Bool {
        (33.0...38.9).contains(coord.latitude) && (124.5...132.0).contains(coord.longitude)
    }
}

private struct KakaoSearchResponse: Decodable {
    let documents: [KakaoPlace]
}

private struct KakaoPlace: Decodable {
    let placeName: String
    let addressName: String
    let x: String
    let y: String

    enum CodingKeys: String, CodingKey {
        case placeName = "place_name"
        case addressName = "address_name"
        case x, y
    }
}
