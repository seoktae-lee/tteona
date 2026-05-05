import SwiftUI
import MapKit
import Combine

struct PlaceSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var searcher = PlaceSearcher()
    @Binding var places: [Place]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                resultList
            }
            .navigationTitle("장소 검색")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                        .foregroundColor(.tteDarkGray)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.tteMediumGray)
            TextField("장소명 검색 (예: 홍대입구역)", text: $searcher.query)
                .autocorrectionDisabled()
                .onSubmit { searcher.search() }
            if !searcher.query.isEmpty {
                Button {
                    searcher.query = ""
                    searcher.results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.tteMediumGray)
                }
            }
        }
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onChange(of: searcher.query) { _, _ in searcher.searchDebounced() }
    }

    @ViewBuilder
    private var resultList: some View {
        if searcher.isSearching {
            ProgressView().padding(.top, 40)
            Spacer()
        } else if searcher.results.isEmpty && !searcher.query.isEmpty {
            Text("검색 결과가 없어요")
                .foregroundColor(.tteMediumGray)
                .padding(.top, 40)
            Spacer()
        } else {
            List(searcher.results, id: \.self) { item in
                Button {
                    let nextOrder = places.count + 1
                    let coord = item.placemark.coordinate
                    let place = Place(
                        order: nextOrder,
                        placeName: item.name ?? item.placemark.name ?? "장소",
                        latitude: coord.latitude,
                        longitude: coord.longitude
                    )
                    places.append(place)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name ?? "")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.tteDarkGray)
                        Text([item.placemark.locality, item.placemark.thoroughfare]
                            .compactMap { $0 }.joined(separator: " "))
                            .font(.system(size: 13))
                            .foregroundColor(.tteMediumGray)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
        }
    }
}

@MainActor
class PlaceSearcher: ObservableObject {
    @Published var query = ""
    @Published var results: [MKMapItem] = []
    @Published var isSearching = false

    private var debounceTask: Task<Void, Never>?

    func searchDebounced() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { search() }
        }
    }

    func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; return }

        isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 36.5, longitude: 127.8),
            span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8)
        )

        Task {
            let search = MKLocalSearch(request: request)
            let response = try? await search.start()
            self.results = response?.mapItems ?? []
            self.isSearching = false
        }
    }
}
