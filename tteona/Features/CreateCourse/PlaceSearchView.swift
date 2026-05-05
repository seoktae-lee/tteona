import SwiftUI
import MapKit
import Combine

struct PlaceSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var searchService = PlaceSearchService()
    @Binding var places: [Place]
    var mapCenter: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 36.5, longitude: 127.8)
    @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                resultList
            }
            .navigationTitle("장소 검색")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { searchService.searchCoordinate = mapCenter }
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
            TextField("장소명 검색 (예: 홍대입구역, 을지로 카페)", text: $query)
                .autocorrectionDisabled()
                .onSubmit { Task { await searchService.search(query) } }
            if !query.isEmpty {
                Button {
                    query = ""
                    searchService.results = []
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
            searchService.searchDebounced(newValue)
        }
    }

    @ViewBuilder
    private var resultList: some View {
        if searchService.isSearching {
            ProgressView()
                .padding(.top, 40)
            Spacer()
        } else if searchService.results.isEmpty && !query.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundColor(.tteMediumGray.opacity(0.5))
                Text("검색 결과가 없어요")
                    .foregroundColor(.tteMediumGray)
            }
            .padding(.top, 60)
            Spacer()
        } else {
            List(searchService.results) { item in
                Button {
                    let place = Place(
                        order: places.count + 1,
                        placeName: item.name,
                        latitude: item.latitude,
                        longitude: item.longitude
                    )
                    places.append(place)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.tteOrange)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.tteDarkGray)
                            if !item.address.isEmpty {
                                Text(item.address)
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
}
