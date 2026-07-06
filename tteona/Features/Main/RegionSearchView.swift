import SwiftUI
import CoreLocation

struct RegionSearchView: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String, CLLocationCoordinate2D) -> Void

    @StateObject private var search = PlaceSearchService()
    @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                resultList
            }
            .navigationTitle(L("region.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.close")) { dismiss() }
                        .foregroundColor(.tteDarkGray)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.tteMediumGray)
            TextField(L("region.placeholder"), text: $query)
                .autocorrectionDisabled()
                .onSubmit { Task { await search.search(query) } }
            if !query.isEmpty {
                Button {
                    query = ""
                    search.results = []
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
            search.searchDebounced(newValue)
        }
    }

    @ViewBuilder
    private var resultList: some View {
        if search.isSearching {
            ProgressView().padding(.top, 40)
            Spacer()
        } else if search.results.isEmpty && !query.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.tte(36))
                    .foregroundColor(.tteMediumGray.opacity(0.4))
                Text(L("region.noResults"))
                    .foregroundColor(.tteMediumGray)
            }
            .padding(.top, 60)
            Spacer()
        } else if search.results.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "map.fill")
                    .font(.tte(36))
                    .foregroundColor(.tteOrange.opacity(0.4))
                Text(L("region.hint"))
                    .font(.tte(15))
                    .foregroundColor(.tteMediumGray)
            }
            .padding(.top, 60)
            Spacer()
        } else {
            List(search.results) { item in
                Button {
                    onSelect(item.name, CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude))
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "location.fill")
                            .font(.tte(20))
                            .foregroundColor(.tteOrange)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.tte(15, .medium))
                                .foregroundColor(.tteDarkGray)
                            if !item.address.isEmpty {
                                Text(item.address)
                                    .font(.tte(13))
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
