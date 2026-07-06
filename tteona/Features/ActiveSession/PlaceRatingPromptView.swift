import SwiftUI

struct PlaceRatingPromptView: View {
    let place: Place
    let userId: String
    let nickname: String
    var onDismiss: () -> Void

    @State private var selectedRating = 0
    @State private var comment = ""
    @State private var isSubmitting = false
    @FocusState private var commentFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.tteMediumGray.opacity(0.4))
                .frame(width: 40, height: 4)
                .padding(.top, 12)

            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text(L("rating.title"))
                        .font(.tte(15, .semibold))
                        .foregroundColor(.tteDarkGray)
                    Text(place.placeName)
                        .font(.tte(13))
                        .foregroundColor(.tteMediumGray)
                }
                .padding(.top, 16)

                HStack(spacing: 16) {
                    ForEach(1...5, id: \.self) { i in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                selectedRating = i
                            }
                        } label: {
                            Image(systemName: i <= selectedRating ? "star.fill" : "star")
                                .font(.tte(30))
                                .foregroundColor(i <= selectedRating ? .tteOrange : .tteMediumGray.opacity(0.3))
                                .scaleEffect(i == selectedRating ? 1.15 : 1.0)
                                .animation(.spring(response: 0.2, dampingFraction: 0.5), value: selectedRating)
                        }
                    }
                }

                if selectedRating > 0 {
                    TextField(L("rating.commentPlaceholder"), text: $comment)
                        .font(.tte(14))
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(Color(UIColor.secondarySystemBackground)))
                        .focused($commentFocused)
                        .submitLabel(.done)
                        .onSubmit { submit() }
                        .padding(.horizontal, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                HStack(spacing: 12) {
                    Button { onDismiss() } label: {
                        Text(L("rating.later"))
                            .font(.tte(15))
                            .foregroundColor(.tteMediumGray)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(Color(UIColor.secondarySystemBackground)))
                    }

                    Button { submit() } label: {
                        Group {
                            if isSubmitting {
                                ProgressView().tint(.white)
                            } else {
                                Text(selectedRating > 0 ? L("rating.submit") : L("common.skip"))
                                    .font(.tte(15, .semibold))
                                    .foregroundColor(.white)
                            }
                        }
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selectedRating > 0 ? Color.tteOrange : Color.tteMediumGray.opacity(0.4))
                        )
                    }
                    .disabled(isSubmitting)
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .animation(.easeInOut(duration: 0.2), value: selectedRating > 0)
        }
        .presentationDetents([.height(selectedRating > 0 ? 280 : 230)])
        .presentationDragIndicator(.hidden)
    }

    private func submit() {
        guard selectedRating > 0 else { onDismiss(); return }
        isSubmitting = true
        let key = PlaceDetailService.cacheKey(for: place.placeName)
        Task {
            await PlaceReviewService.shared.saveReview(
                placeKey: key,
                userId: userId,
                nickname: nickname,
                rating: selectedRating,
                comment: comment.isEmpty ? nil : comment
            )
            await MainActor.run { onDismiss() }
        }
    }
}
