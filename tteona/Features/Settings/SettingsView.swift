import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @State private var showSignOutAlert = false

    var body: some View {
        NavigationStack {
            List {
                profileSection
                appSection
                accountSection
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.large)
        }
        .alert("로그아웃", isPresented: $showSignOutAlert) {
            Button("로그아웃", role: .destructive) { authService.signOut() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("정말 로그아웃 하시겠어요?")
        }
    }

    private var profileSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.tteOrange.opacity(0.15))
                        .frame(width: 56, height: 56)
                    Text(String(userService.currentUser?.nickname.prefix(1) ?? "?"))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.tteOrange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(userService.currentUser?.nickname.isEmpty == false
                         ? userService.currentUser!.nickname : "닉네임 없음")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.tteDarkGray)
                    Text(authService.currentUser?.email ?? "")
                        .font(.system(size: 13))
                        .foregroundColor(.tteMediumGray)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var appSection: some View {
        Section("앱 정보") {
            HStack {
                Label("버전", systemImage: "info.circle")
                Spacer()
                Text("1.0.0")
                    .foregroundColor(.tteMediumGray)
            }
        }
    }

    private var accountSection: some View {
        Section("계정") {
            Button {
                showSignOutAlert = true
            } label: {
                Label("로그아웃", systemImage: "arrow.right.square")
                    .foregroundColor(.red)
            }
        }
    }
}
