import SwiftUI

struct TravelStatsView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var stats: TravelStats?
    @State private var isLoading = true

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                if isLoading {
                    ProgressView().tint(.tteOrange).padding(.top, 60)
                } else if let stats {
                    LazyVGrid(columns: columns, spacing: 12) {
                        statCard(icon: "map.fill",            title: L("stats.coursesCreated"), value: L("stats.unit.count", stats.coursesCreated))
                        statCard(icon: "mappin.and.ellipse",  title: L("stats.placesRecorded"), value: L("stats.unit.places", stats.placesInCourses))
                        statCard(icon: "heart.fill",          title: L("stats.likesReceived"),  value: L("stats.unit.count", stats.likesReceived))
                        statCard(icon: "person.2.fill",       title: L("stats.groups"),         value: L("stats.unit.count", stats.groups))
                        statCard(icon: "figure.walk",         title: L("stats.placesVisited"),  value: L("stats.unit.places", stats.placesVisited))
                        statCard(icon: "calendar",            title: L("stats.activeDays"),     value: L("stats.unit.days", stats.activeDays))
                    }
                    .padding(.horizontal, 20)

                    Text(L("stats.disclaimer"))
                        .font(.tte(12))
                        .foregroundColor(.tteMediumGray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 4)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.slash")
                            .font(.tte(32))
                            .foregroundColor(.tteMediumGray)
                        Text(L("stats.loadFailed"))
                            .font(.tte(14))
                            .foregroundColor(.tteMediumGray)
                    }
                    .padding(.top, 60)
                }
            }
            .padding(.vertical, 20)
        }
        .navigationTitle(L("settings.travelStats"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let uid = authService.currentUser?.uid else { isLoading = false; return }
            stats = await StatsService.shared.fetchMyStats(userId: uid)
            isLoading = false
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image("tteoni-wink")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("stats.journeySoFar"))
                    .font(.tte(13, .medium))
                    .foregroundColor(.tteMediumGray)
                Text(L("stats.subtitle"))
                    .font(.tte(20, .bold))
                    .foregroundColor(.tteDarkGray)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func statCard(icon: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.tte(18))
                .foregroundColor(.tteOrange)
            Text(value)
                .font(.tte(24, .bold))
                .foregroundColor(.tteDarkGray)
            Text(title)
                .font(.tte(13))
                .foregroundColor(.tteMediumGray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemBackground)))
    }
}
