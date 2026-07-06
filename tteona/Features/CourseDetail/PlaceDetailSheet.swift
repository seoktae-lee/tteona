import SwiftUI

struct PlaceDetailSheet: View {
    let place: Place

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService

    @State private var detail: PlaceDetail?
    @State private var tteonaReviews: [TteonaPlaceReview] = []
    @State private var visitCount: Int = 0
    @State private var isLoadingDetail = true
    @State private var isLoadingReviews = true
    @State private var selectedTab: ReviewTab = .google

    @State private var showReportAlert = false
    @State private var showBlockAlert = false
    @State private var showReportSuccessAlert = false
    @State private var showBlockSuccessAlert = false
    @State private var selectedReviewForAction: TteonaPlaceReview?

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
            async let detailFetch = PlaceDetailService.shared.fetchDetail(
                for: place.placeName, latitude: place.latitude, longitude: place.longitude)
            let key = PlaceDetailService.cacheKey(for: place.placeName)
            let blockedIds = userService.currentUser?.blockedUserIds ?? []
            async let reviewFetch = PlaceReviewService.shared.fetchReviews(placeKey: key, blockedUserIds: blockedIds)
            let (d, r) = await (detailFetch, reviewFetch)
            detail = d
            isLoadingDetail = false
            tteonaReviews = r.reviews
            visitCount = r.visitCount
            isLoadingReviews = false
        }
        .confirmationDialog("신고 사유를 선택해주세요", isPresented: $showReportAlert, titleVisibility: .visible) {
            ForEach(["영리목적/홍보", "음란성/선정성", "욕설/비하", "아동 유해 콘텐츠", "기타"], id: \.self) { reason in
                Button(reason) {
                    submitReviewReport(reason: reason)
                }
            }
            Button("취소", role: .cancel) {}
        }
        .alert("리뷰 작성자 차단", isPresented: $showBlockAlert) {
            Button("차단", role: .destructive) {
                blockReviewer()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 리뷰 작성자를 차단하시겠어요? 차단하시면 이 작성자가 등록한 모든 코스와 후기가 숨겨집니다.")
        }
        .alert("신고 완료", isPresented: $showReportSuccessAlert) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("신고가 정상 접수되었습니다. 24시간 이내에 검토 및 삭제 처리됩니다.")
        }
        .alert("차단 완료", isPresented: $showBlockSuccessAlert) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("작성자가 차단되었습니다. 목록에서 후기가 삭제되었습니다.")
        }
    }

    private func submitReviewReport(reason: String) {
        guard let currentUid = authService.currentUser?.uid,
              let review = selectedReviewForAction else { return }
        let key = PlaceDetailService.cacheKey(for: place.placeName)
        Task {
            do {
                try await ReportService.shared.reportContent(
                    reporterId: currentUid,
                    targetType: "review",
                    targetId: "\(key)/\(review.userId)",
                    targetAuthorId: review.userId,
                    reason: reason
                )
                showReportSuccessAlert = true
            } catch {}
        }
    }

    private func blockReviewer() {
        guard let currentUid = authService.currentUser?.uid,
              let review = selectedReviewForAction else { return }
        Task {
            do {
                try await userService.blockUser(uid: currentUid, blockedUid: review.userId)
                withAnimation {
                    tteonaReviews.removeAll { $0.userId == review.userId }
                }
                showBlockSuccessAlert = true
            } catch {}
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
                    .font(.tte(19, .semibold))
                    .foregroundColor(.tteDarkGray)
                if let detail, let rating = detail.rating {
                    HStack(spacing: 5) {
                        starRow(rating: rating, color: .yellow, size: 12)
                        Text(String(format: "%.1f", rating))
                            .font(.tte(13, .medium))
                            .foregroundColor(.tteDarkGray)
                        Text("리뷰 \(detail.reviewCount)개")
                            .font(.tte(12))
                            .foregroundColor(.tteMediumGray)
                    }
                }
            }
            Spacer()
            if visitCount > 0 {
                VStack(spacing: 3) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.tte(22))
                        .foregroundColor(.tteOrange)
                    Text("떠나 \(visitCount)명")
                        .font(.tte(10, .medium))
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
                    .font(.tte(14, selectedTab == tab ? .semibold : .regular))
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
                    TteonaReviewRow(
                        review: review,
                        currentUserId: authService.currentUser?.uid,
                        onReport: {
                            selectedReviewForAction = review
                            showReportAlert = true
                        },
                        onBlock: {
                            selectedReviewForAction = review
                            showBlockAlert = true
                        }
                    )
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
                .font(.tte(36))
                .foregroundColor(.tteMediumGray.opacity(0.35))
            Text(message)
                .font(.tte(14))
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
                            .font(.tte(14, .semibold))
                            .foregroundColor(.tteDarkGray)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(review.authorName)
                        .font(.tte(14, .medium))
                        .foregroundColor(.tteDarkGray)
                    HStack(spacing: 4) {
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { i in
                                Image(systemName: i <= review.rating ? "star.fill" : "star")
                                    .font(.tte(10))
                                    .foregroundColor(.yellow)
                            }
                        }
                        if !review.publishTime.isEmpty {
                            Text("·").foregroundColor(.tteMediumGray)
                            Text(review.publishTime)
                                .font(.tte(11))
                                .foregroundColor(.tteMediumGray)
                        }
                    }
                }
            }
            if !review.text.isEmpty {
                Text(review.text)
                    .font(.tte(13))
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
    let currentUserId: String?
    var onReport: (() -> Void)? = nil
    var onBlock: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.tteOrange.opacity(0.1))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(String(review.nickname.prefix(1)))
                            .font(.tte(14, .semibold))
                            .foregroundColor(.tteOrange)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(review.nickname)
                        .font(.tte(14, .medium))
                        .foregroundColor(.tteDarkGray)
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { i in
                            Image(systemName: i <= review.rating ? "star.fill" : "star")
                                .font(.tte(10))
                                .foregroundColor(.tteOrange)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(review.createdAt, style: .relative)
                        .font(.tte(11))
                        .foregroundColor(.tteMediumGray)
                    if let currentUserId, review.userId != currentUserId {
                        Menu {
                            Button(role: .destructive) {
                                onReport?()
                            } label: {
                                Label("신고하기", systemImage: "exclamationmark.bubble")
                            }
                            Button {
                                onBlock?()
                            } label: {
                                Label("작성자 차단하기", systemImage: "person.crop.circle.badge.xmark")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.tte(14))
                                .foregroundColor(.tteMediumGray)
                        }
                    }
                }
            }
            if let comment = review.comment {
                Text(comment)
                    .font(.tte(13))
                    .foregroundColor(.tteDarkGray)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
