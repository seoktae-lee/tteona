import SwiftUI
import PhotosUI
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
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false
    @ObservedObject private var pro = ProManager.shared
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            List {
                profileSection
                proSection
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
        .sheet(isPresented: $showPaywall) { ProPaywallView() }
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
                PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                    ZStack {
                        Circle()
                            .fill(Color.tteOrange.opacity(0.15))
                            .frame(width: 56, height: 56)
                        if let urlString = userService.currentUser?.profileImageUrl, let url = URL(string: urlString) {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Text(String(userService.currentUser?.nickname.prefix(1) ?? "?"))
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundColor(.tteOrange)
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(Circle())
                        } else {
                            Text(String(userService.currentUser?.nickname.prefix(1) ?? "?"))
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.tteOrange)
                        }
                        if isUploadingAvatar {
                            Circle()
                                .fill(Color.black.opacity(0.4))
                                .frame(width: 56, height: 56)
                            ProgressView().tint(.white)
                        }
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.tteOrange))
                            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                            .offset(x: 20, y: 20)
                    }
                }
                .disabled(isUploadingAvatar)
                .onChange(of: avatarPickerItem) { _, newItem in
                    Task { await uploadAvatar(from: newItem) }
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

            NavigationLink {
                TravelStatsView()
                    .environmentObject(authService)
            } label: {
                Label("내 여행 통계", systemImage: "chart.bar.fill")
            }
        }
    }

    private var proSection: some View {
        Section {
            Button {
                if !pro.isPro { showPaywall = true }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            LinearGradient(colors: [Color(red: 1, green: 0.7, blue: 0.3), .tteOrange],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pro.isPro ? "tteona PRO 이용 중" : "tteona PRO")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.tteDarkGray)
                        Text(pro.isPro
                             ? "모든 프리미엄 기능이 켜져 있어요"
                             : "워터마크 제거 · 멀티포맷 · 5분 영상 · 우선 렌더링")
                            .font(.system(size: 12))
                            .foregroundColor(.tteMediumGray)
                    }
                    Spacer()
                    if pro.isPro {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.tteOrange)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.tteMediumGray)
                    }
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .disabled(pro.isPro)
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

    private func uploadAvatar(from item: PhotosPickerItem?) async {
        guard let item, let uid = authService.currentUser?.uid else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }

        isUploadingAvatar = true
        defer { isUploadingAvatar = false }

        if let url = await ProfileImageService.shared.upload(uid: uid, image: image) {
            userService.setProfileImageUrl(url)
        }
    }

    private var accountSection: some View {
        Section("계정") {
            NavigationLink {
                BlockedUsersView()
                    .environmentObject(userService)
                    .environmentObject(authService)
            } label: {
                Label("차단된 사용자 관리", systemImage: "person.crop.circle.badge.xmark")
                    .foregroundColor(.tteDarkGray)
            }
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
