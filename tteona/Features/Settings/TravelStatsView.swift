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
                        statCard(icon: "map.fill",            title: "만든 코스",     value: "\(stats.coursesCreated)개")
                        statCard(icon: "mappin.and.ellipse",  title: "기록한 장소",   value: "\(stats.placesInCourses)곳")
                        statCard(icon: "heart.fill",          title: "받은 좋아요",   value: "\(stats.likesReceived)개")
                        statCard(icon: "person.2.fill",       title: "함께한 그룹",   value: "\(stats.groups)개")
                        statCard(icon: "figure.walk",         title: "방문한 장소",   value: "\(stats.placesVisited)곳")
                        statCard(icon: "calendar",            title: "활동한 날",     value: "\(stats.activeDays)일")
                    }
                    .padding(.horizontal, 20)

                    Text("방문한 장소와 활동한 날은 앱 업데이트 이후의 활동부터 집계돼요.")
                        .font(.system(size: 12))
                        .foregroundColor(.tteMediumGray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 4)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 32))
                            .foregroundColor(.tteMediumGray)
                        Text("통계를 불러오지 못했어요")
                            .font(.system(size: 14))
                            .foregroundColor(.tteMediumGray)
                    }
                    .padding(.top, 60)
                }
            }
            .padding(.vertical, 20)
        }
        .navigationTitle("내 여행 통계")
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
                Text("지금까지의 여정")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.tteMediumGray)
                Text("떠난 만큼 쌓여요")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.tteDarkGray)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func statCard(icon: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.tteOrange)
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.tteDarkGray)
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.tteMediumGray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemBackground)))
    }
}
