import SwiftUI

struct BlockedUsersView: View {
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var authService: AuthService
    @State private var blockedUsers: [AppUser] = []
    @State private var isLoading = true
    @State private var showUnblockErrorAlert = false

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView().tint(.tteOrange)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(.vertical, 20)
            } else if blockedUsers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.tte(44))
                        .foregroundColor(.tteMediumGray.opacity(0.4))
                    Text(L("blocked.empty"))
                        .font(.tte(15))
                        .foregroundColor(.tteMediumGray)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 48)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(blockedUsers, id: \.uid) { user in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(user.nickname)
                                .font(.tte(16, .semibold))
                                .foregroundColor(.tteDarkGray)
                            if !user.email.isEmpty {
                                Text(user.email)
                                    .font(.tte(12))
                                    .foregroundColor(.tteMediumGray)
                            }
                        }
                        Spacer()
                        Button(L("blocked.unblock")) {
                            unblock(userId: user.uid)
                        }
                        .font(.tte(13, .semibold))
                        .foregroundColor(.tteOrange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.tteOrange.opacity(0.12)))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(L("settings.blockedUsers"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadBlockedUsers()
        }
        .alert(L("blocked.unblockFailed"), isPresented: $showUnblockErrorAlert) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(L("common.tryAgainLater"))
        }
    }

    private func loadBlockedUsers() async {
        guard let blockedIds = userService.currentUser?.blockedUserIds, !blockedIds.isEmpty else {
            blockedUsers = []
            isLoading = false
            return
        }
        
        var loadedUsers: [AppUser] = []
        for uid in blockedIds {
            if let user = await userService.fetchAuthor(uid: uid) {
                loadedUsers.append(user)
            } else {
                loadedUsers.append(AppUser(uid: uid, email: "", nickname: L("user.deleted")))
            }
        }
        blockedUsers = loadedUsers
        isLoading = false
    }

    private func unblock(userId: String) {
        guard let currentUid = authService.currentUser?.uid else { return }
        Task {
            do {
                try await userService.unblockUser(uid: currentUid, blockedUid: userId)
                withAnimation {
                    blockedUsers.removeAll { $0.uid == userId }
                }
            } catch {
                showUnblockErrorAlert = true
            }
        }
    }
}
