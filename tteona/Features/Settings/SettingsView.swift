import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @State private var showSignOutAlert = false
    @State private var showDeleteAccountAlert = false
    @State private var isDeletingAccount = false
    @State private var showDeleteFailedAlert = false
    @State private var deleteFailedMessage = "회원 탈퇴에 실패했어요. 잠시 후 다시 시도해주세요."
    @State private var notificationGranted: Bool? = nil

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
        .alert("회원 탈퇴", isPresented: $showDeleteAccountAlert) {
            Button("탈퇴", role: .destructive) {
                guard let uid = authService.currentUser?.uid else { return }
                isDeletingAccount = true
                Task {
                    defer { isDeletingAccount = false }
                    do {
                        try await authService.deleteAccount(userId: uid)
                    } catch {
                        deleteFailedMessage = authService.errorMessage ?? "회원 탈퇴에 실패했어요. 잠시 후 다시 시도해주세요."
                        showDeleteFailedAlert = true
                    }
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("탈퇴 시 코스, 그룹, 계정 정보가 모두 삭제되며 복구할 수 없어요.")
        }
        .alert("탈퇴 실패", isPresented: $showDeleteFailedAlert) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(deleteFailedMessage)
        }
        .task {
            await checkNotificationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await checkNotificationStatus() }
        }
        .overlay {
            if isDeletingAccount {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().tint(.white).scaleEffect(1.3)
                        Text("탈퇴 처리 중...")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                    }
                    .padding(28)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.7)))
                }
            }
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
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                    .foregroundColor(.tteMediumGray)
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack {
                    Label("푸시알림", systemImage: "bell")
                        .foregroundColor(.tteDarkGray)
                    Spacer()
                    if let granted = notificationGranted {
                        Text(granted ? "켜짐" : "꺼짐")
                            .foregroundColor(granted ? .tteMediumGray : .red)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack {
                    Label("언어", systemImage: "globe")
                        .foregroundColor(.tteDarkGray)
                    Spacer()
                    Text("한국어")
                        .foregroundColor(.tteMediumGray)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
            }
            Link(destination: URL(string: "https://tteona.kr/privacy.html")!) {
                Label("개인정보 처리방침", systemImage: "lock.shield")
                    .foregroundColor(.tteDarkGray)
            }
            Link(destination: URL(string: "https://tteona.kr/terms.html")!) {
                Label("이용약관", systemImage: "doc.text")
                    .foregroundColor(.tteDarkGray)
            }
            Link(destination: URL(string: "https://tteona.kr/child-safety.html")!) {
                Label("아동 안전 기준 정책", systemImage: "checkmark.shield")
                    .foregroundColor(.tteDarkGray)
            }
            Button {
                if let url = URL(string: "mailto:just.tteona@gmail.com") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("문의하기", systemImage: "envelope")
                    .foregroundColor(.tteDarkGray)
            }
        }
    }

    private func checkNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationGranted = settings.authorizationStatus == .authorized
    }

    private var accountSection: some View {
        Section("계정") {
            Button {
                showSignOutAlert = true
            } label: {
                Label("로그아웃", systemImage: "arrow.right.square")
                    .foregroundColor(.red)
            }
            Button {
                showDeleteAccountAlert = true
            } label: {
                Label("회원 탈퇴", systemImage: "person.crop.circle.badge.minus")
                    .foregroundColor(.red)
            }
        }
    }
}
