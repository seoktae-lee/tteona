import SwiftUI
import MapKit

struct RegionSearchView: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String, CLLocationCoordinate2D) -> Void

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                resultList
            }
            .navigationTitle("지역 검색")
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
            TextField("지역, 동네 검색 (예: 잠실, 홍대, 해운대)", text: $query)
                .autocorrectionDisabled()
                .onSubmit { Task { await search() } }
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
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
        .onChange(of: query) { _, newValue in
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                await search()
            }
        }
    }

    @ViewBuilder
    private var resultList: some View {
        if isSearching {
            ProgressView().padding(.top, 40)
            Spacer()
        } else if results.isEmpty && !query.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundColor(.tteMediumGray.opacity(0.4))
                Text("검색 결과가 없어요")
                    .foregroundColor(.tteMediumGray)
            }
            .padding(.top, 60)
            Spacer()
        } else if results.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "map.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.tteOrange.opacity(0.4))
                Text("동네나 지역을 검색해보세요")
                    .font(.system(size: 15))
                    .foregroundColor(.tteMediumGray)
            }
            .padding(.top, 60)
            Spacer()
        } else {
            List(results, id: \.self) { item in
                Button {
                    let coord = item.placemark.coordinate
                    let name = [item.name, item.placemark.locality, item.placemark.administrativeArea]
                        .compactMap { $0 }.first ?? "해당 지역"
                    onSelect(name, coord)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.tteOrange)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name ?? "")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.tteDarkGray)
                            let address = [item.placemark.administrativeArea, item.placemark.locality]
                                .compactMap { $0 }.joined(separator: " ")
                            if !address.isEmpty {
                                Text(address)
                                    .font(.system(size: 13))
                                    .foregroundColor(.tteMediumGray)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; return }
        isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        request.resultTypes = [.address, .pointOfInterest]
        do {
            let response = try await MKLocalSearch(request: request).start()
            results = response.mapItems
        } catch {
            results = []
        }
        isSearching = false
    }
}
