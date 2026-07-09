import SwiftUI

// MARK: - 유저 검색
/// 닉네임으로 다른 유저를 찾아 프로필(발자취·코스)로 이동한다.
struct UserSearchView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService

    @State private var query = ""
    @State private var results: [AppUser] = []
    @State private var isSearching = false
    @State private var didSearch = false
    @State private var searchTask: Task<Void, Never>? = nil
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 20)
                .padding(.top, 8)

            if isSearching {
                Spacer()
                ProgressView().tint(.tteOrange)
                Spacer()
            } else if results.isEmpty && didSearch {
                emptyState
            } else if results.isEmpty {
                idleState
            } else {
                List(results, id: \.uid) { user in
                    NavigationLink {
                        UserProfileView(user: user)
                    } label: {
                        userRow(user)
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .background(Color.tteBackground)
        .navigationTitle(L("profile.searchUsers"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: - 검색바

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.tte(15))
                .foregroundColor(.tteMediumGray)
            TextField(L("profile.search.placeholder"), text: $query)
                .font(.tte(15))
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    didSearch = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.tte(15))
                        .foregroundColor(.tteMediumGray)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .onChange(of: query) { _, newValue in
            scheduleSearch(newValue)
        }
    }

    /// 타이핑 멈춘 뒤 0.35초 디바운스 검색
    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            didSearch = false
            isSearching = false
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            var found = await FootprintService.shared.searchUsers(nickname: trimmed)
            // 본인·차단 유저 제외
            let myUid = authService.currentUser?.uid
            let blocked = Set(userService.currentUser?.blockedUserIds ?? [])
            found.removeAll { $0.uid == myUid || blocked.contains($0.uid) }
            guard !Task.isCancelled else { return }
            results = found
            didSearch = true
            isSearching = false
        }
    }

    // MARK: - 행/상태

    private func userRow(_ user: AppUser) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.tteOrange.opacity(0.12))
                    .frame(width: 46, height: 46)
                if let urlString = user.profileImageUrl, let url = URL(string: urlString) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Text(String(user.nickname.prefix(1)))
                            .font(.tte(18, .semibold))
                            .foregroundColor(.tteOrange)
                    }
                    .frame(width: 46, height: 46)
                    .clipShape(Circle())
                } else {
                    Text(String(user.nickname.prefix(1)))
                        .font(.tte(18, .semibold))
                        .foregroundColor(.tteOrange)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(user.nickname)
                        .font(.tte(15, .semibold))
                        .foregroundColor(.tteDarkGray)
                    if user.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.tte(12))
                            .foregroundColor(.tteOrange)
                    }
                }
                if let label = user.creatorLabel, !label.isEmpty {
                    Text(label)
                        .font(.tte(12))
                        .foregroundColor(.tteOrange)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var idleState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.2")
                .font(.tte(36))
                .foregroundColor(Color(UIColor.quaternaryLabel))
            Text(L("profile.search.hint"))
                .font(.tte(14))
                .foregroundColor(.tteMediumGray)
                .multilineTextAlignment(.center)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.tte(36))
                .foregroundColor(Color(UIColor.quaternaryLabel))
            Text(L("profile.search.empty"))
                .font(.tte(14))
                .foregroundColor(.tteMediumGray)
            Spacer()
            Spacer()
        }
    }
}
