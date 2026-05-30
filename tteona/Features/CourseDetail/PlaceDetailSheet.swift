import SwiftUI

struct PlaceDetailSheet: View {
    let place: Place

    @State private var detail: PlaceDetail?
    @State private var tteonaReviews: [TteonaPlaceReview] = []
    @State private var visitCount: Int = 0
    @State private var isLoadingDetail = true
    @State private var isLoadingReviews = true
    @State private var selectedTab: ReviewTab = .google

    enum ReviewTab { case google, tteona }

    var body: some View {
        VStack(spacing: 0) {
            handle
            ScrollView {
                VStack(spacing: 0) {
                    headerSection
                    photoGallery
                    tabBar
                    Divider()
                    reviewContent
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .task {
            async let detailFetch = PlaceDetailService.shared.fetchDetail(for: place.placeName)
            let key = PlaceDetailService.cacheKey(for: place.placeName)
            async let reviewFetch = PlaceReviewService.shared.fetchReviews(placeKey: key)
            let (d, r) = await (detailFetch, reviewFetch)
            detail = d
            isLoadingDetail = false
            tteonaReviews = r.reviews
            visitCount = r.visitCount
            isLoadingReviews = false
        }
    }

    // MARK: - Handle
    private var handle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.tteMediumGray.opacity(0.4))
            .frame(width: 40, height: 4)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(place.placeName)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.tteDarkGray)
                if let detail, let rating = detail.rating {
                    HStack(spacing: 5) {
                        starRow(rating: rating, color: .yellow, size: 12)
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.tteDarkGray)
                        Text("리뷰 \(detail.reviewCount)개")
                            .font(.system(size: 12))
                            .foregroundColor(.tteMediumGray)
                    }
                }
            }
            Spacer()
            if visitCount > 0 {
                VStack(spacing: 3) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.tteOrange)
                    Text("떠나 \(visitCount)명")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.tteMediumGray)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Photo Gallery
    @ViewBuilder
    private var photoGallery: some View {
        if isLoadingDetail {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.tteOrange.opacity(0.06))
                .frame(height: 150)
                .overlay(ProgressView().tint(.tteOrange))
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
        } else if let photos = detail?.photos, !photos.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { _, urlStr in
                        if let url = URL(string: urlStr) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().aspectRatio(contentMode: .fill)
                                default:
                                    Color.tteOrange.opacity(0.06)
                                }
                            }
                            .frame(width: 200, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 14)
        }
    }

    // MARK: - Tab Bar
    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("구글 리뷰", tab: .google)
            tabButton("떠나 후기", tab: .tteona)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private func tabButton(_ title: String, tab: ReviewTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
        } label: {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: selectedTab == tab ? .semibold : .regular))
                    .foregroundColor(selectedTab == tab ? .tteDarkGray : .tteMediumGray)
                Rectangle()
                    .fill(selectedTab == tab ? Color.tteOrange : Color.clear)
                    .frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Review Content
    @ViewBuilder
    private var reviewContent: some View {
        if selectedTab == .google {
            googleTab
        } else {
            tteonaTab
        }
    }

    private var googleTab: some View {
        VStack(spacing: 0) {
            if isLoadingDetail {
                ProgressView().padding(40)
            } else if let reviews = detail?.reviews, !reviews.isEmpty {
                ForEach(reviews) { review in
                    GoogleReviewRow(review: review)
                    Divider().padding(.horizontal, 20)
                }
            } else {
                emptyState(icon: "star.slash", message: "구글 리뷰가 없어요")
            }
        }
    }

    private var tteonaTab: some View {
        VStack(spacing: 0) {
            if isLoadingReviews {
                ProgressView().padding(40)
            } else if !tteonaReviews.isEmpty {
                ForEach(tteonaReviews) { review in
                    TteonaReviewRow(review: review)
                    Divider().padding(.horizontal, 20)
                }
            } else {
                emptyState(
                    icon: "mappin.slash",
                    message: "아직 떠나 방문 기록이 없어요\n이 코스를 따라가면 첫 번째가 되어보세요!"
                )
            }
        }
    }

    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(.tteMediumGray.opacity(0.35))
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.tteMediumGray)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 48)
        .padding(.horizontal, 20)
    }

    private func starRow(rating: Double, color: Color, size: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: Double(i) <= rating ? "star.fill"
                      : (Double(i) - 0.5 <= rating ? "star.leadinghalf.filled" : "star"))
                    .font(.system(size: size))
                    .foregroundColor(color)
            }
        }
    }
}

// MARK: - Google Review Row
struct GoogleReviewRow: View {
    let review: GooglePlaceReview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(UIColor.secondarySystemBackground))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(String(review.authorName.prefix(1)))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.tteDarkGray)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(review.authorName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.tteDarkGray)
                    HStack(spacing: 4) {
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { i in
                                Image(systemName: i <= review.rating ? "star.fill" : "star")
                                    .font(.system(size: 10))
                                    .foregroundColor(.yellow)
                            }
                        }
                        if !review.publishTime.isEmpty {
                            Text("·").foregroundColor(.tteMediumGray)
                            Text(review.publishTime)
                                .font(.system(size: 11))
                                .foregroundColor(.tteMediumGray)
                        }
                    }
                }
            }
            if !review.text.isEmpty {
                Text(review.text)
                    .font(.system(size: 13))
                    .foregroundColor(.tteDarkGray)
                    .lineLimit(4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - tteona Review Row
struct TteonaReviewRow: View {
    let review: TteonaPlaceReview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.tteOrange.opacity(0.1))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(String(review.nickname.prefix(1)))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.tteOrange)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(review.nickname)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.tteDarkGray)
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { i in
                            Image(systemName: i <= review.rating ? "star.fill" : "star")
                                .font(.system(size: 10))
                                .foregroundColor(.tteOrange)
                        }
                    }
                }
                Spacer()
                Text(review.createdAt, style: .relative)
                    .font(.system(size: 11))
                    .foregroundColor(.tteMediumGray)
            }
            if let comment = review.comment {
                Text(comment)
                    .font(.system(size: 13))
                    .foregroundColor(.tteDarkGray)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
