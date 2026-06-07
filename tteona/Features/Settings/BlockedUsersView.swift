import SwiftUI

struct BlockedUsersView: View {
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var authService: AuthService
    @State private var blockedUsers: [AppUser] = []
    @State private var isLoading = true

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
                        .font(.system(size: 44))
                        .foregroundColor(.tteMediumGray.opacity(0.4))
                    Text("차단한 사용자가 없습니다.")
                        .font(.system(size: 15))
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
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.tteDarkGray)
                            if !user.email.isEmpty {
                                Text(user.email)
                                    .font(.system(size: 12))
                                    .foregroundColor(.tteMediumGray)
                            }
                        }
                        Spacer()
                        Button("차단 해제") {
                            unblock(userId: user.uid)
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.tteOrange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.tteOrange.opacity(0.12)))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("차단된 사용자 관리")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadBlockedUsers()
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
                loadedUsers.append(AppUser(uid: uid, email: "", nickname: "탈퇴한 사용자"))
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
            } catch {}
        }
    }
}
