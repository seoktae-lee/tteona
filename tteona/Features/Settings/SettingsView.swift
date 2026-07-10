import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @State private var showSignOutAlert = false
    @State private var showDeleteAccountAlert = false
    @State private var isDeletingAccount = false
    @State private var showDeleteFailedAlert = false
    @State private var deleteFailedMessage = L("settings.deleteFailed.message")
    @State private var notificationGranted: Bool? = nil
    @ObservedObject private var pro = ProManager.shared
    @State private var showPaywall = false

    var body: some View {
        // 프로필 탭에서 push되므로 자체 NavigationStack 없이 부모 스택을 사용한다
        List {
            personalSection
            proSection
            appSection
            accountSection
        }
        .navigationTitle(L("settings.title"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(L("settings.signOut"), isPresented: $showSignOutAlert) {
            Button(L("settings.signOut"), role: .destructive) {
                Task { await authService.signOut() }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("settings.signOut.confirm"))
        }
        .alert(L("settings.deleteAccount"), isPresented: $showDeleteAccountAlert) {
            Button(L("settings.deleteAccount.confirmButton"), role: .destructive) {
                guard let uid = authService.currentUser?.uid else { return }
                isDeletingAccount = true
                Task {
                    defer { isDeletingAccount = false }
                    do {
                        try await authService.deleteAccount(userId: uid)
                    } catch {
                        deleteFailedMessage = authService.errorMessage ?? L("settings.deleteFailed.message")
                        showDeleteFailedAlert = true
                    }
                }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("settings.deleteAccount.message"))
        }
        .alert(L("settings.deleteFailed.title"), isPresented: $showDeleteFailedAlert) {
            Button(L("common.ok"), role: .cancel) {}
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
                        Text(L("settings.deleting"))
                            .font(.tte(14))
                            .foregroundColor(.white)
                    }
                    .padding(28)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.7)))
                }
            }
        }
    }

    // 프로필(아바타·닉네임·통계)은 프로필 탭으로 이동 — 여기는 취향 설정만 남긴다
    private var personalSection: some View {
        Section {
            travelStyleRow
        }
    }

    // 여행 취향 — 온보딩에서 건너뛴 유저·기존 유저도 여기서 설정, 탐색 추천에 즉시 반영
    private var travelStyleRow: some View {
        Menu {
            ForEach(CourseTag.allCases, id: \.self) { tag in
                Button {
                    updatePreferredTag(tag)
                } label: {
                    if userService.currentUser?.preferredTag == tag.rawValue {
                        Label("\(tag.emoji) \(tag.displayName)", systemImage: "checkmark")
                    } else {
                        Text("\(tag.emoji) \(tag.displayName)")
                    }
                }
            }
            Divider()
            Button {
                updatePreferredTag(nil)
            } label: {
                Text(L("settings.travelStyle.none"))
            }
        } label: {
            HStack {
                Label(L("settings.travelStyle"), systemImage: "heart.text.square")
                    .foregroundColor(.tteDarkGray)
                Spacer()
                Text(currentStyleLabel)
                    .font(.tte(14))
                    .foregroundColor(.tteMediumGray)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.tte(11))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
            }
        }
    }

    private var currentStyleLabel: String {
        guard let raw = userService.currentUser?.preferredTag,
              let tag = CourseTag(rawValue: raw) else { return L("settings.travelStyle.none") }
        return "\(tag.emoji) \(tag.displayName)"
    }

    private func updatePreferredTag(_ tag: CourseTag?) {
        guard let uid = authService.currentUser?.uid else { return }
        Task {
            try? await userService.updatePreferredTag(uid: uid, tag: tag?.rawValue)
            Haptics.light()
        }
    }

    private var proSection: some View {
        Section {
            Button {
                if !pro.isPro { showPaywall = true }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "crown.fill")
                        .font(.tte(20))
                        .foregroundStyle(
                            LinearGradient(colors: [Color(red: 1, green: 0.7, blue: 0.3), .tteOrange],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pro.isPro ? L("settings.pro.active") : "tteona PRO")
                            .font(.tte(16, .semibold))
                            .foregroundColor(.tteDarkGray)
                        Text(pro.isPro
                             ? L("settings.pro.activeDesc")
                             : L("settings.pro.features"))
                            .font(.tte(12))
                            .foregroundColor(.tteMediumGray)
                    }
                    Spacer()
                    if pro.isPro {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.tteOrange)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.tte(13, .semibold))
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
        Section(L("settings.appInfo")) {
            HStack {
                Label(L("settings.version"), systemImage: "info.circle")
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
                    Label(L("settings.push"), systemImage: "bell")
                        .foregroundColor(.tteDarkGray)
                    Spacer()
                    if let granted = notificationGranted {
                        Text(granted ? L("common.on") : L("common.off"))
                            .foregroundColor(granted ? .tteMediumGray : .red)
                    }
                    Image(systemName: "chevron.right")
                        .font(.tte(12, .medium))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
            }
            NavigationLink {
                LanguageSettingsView()
            } label: {
                HStack {
                    Label(L("settings.language"), systemImage: "globe")
                        .foregroundColor(.tteDarkGray)
                    Spacer()
                    Text("\(LanguageManager.shared.language.flag) \(LanguageManager.shared.language.nativeName)")
                        .foregroundColor(.tteMediumGray)
                }
            }
            Link(destination: URL(string: "https://tteona.kr/privacy.html")!) {
                Label(L("settings.privacy"), systemImage: "lock.shield")
                    .foregroundColor(.tteDarkGray)
            }
            Link(destination: URL(string: "https://tteona.kr/terms.html")!) {
                Label(L("settings.terms"), systemImage: "doc.text")
                    .foregroundColor(.tteDarkGray)
            }
            Link(destination: URL(string: "https://tteona.kr/child-safety.html")!) {
                Label(L("settings.childSafety"), systemImage: "checkmark.shield")
                    .foregroundColor(.tteDarkGray)
            }
            Button {
                if let url = URL(string: "mailto:just.tteona@gmail.com") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label(L("settings.contact"), systemImage: "envelope")
                    .foregroundColor(.tteDarkGray)
            }
        }
    }

    private func checkNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationGranted = settings.authorizationStatus == .authorized
    }

    private var accountSection: some View {
        Section(L("settings.account")) {
            NavigationLink {
                BlockedUsersView()
                    .environmentObject(userService)
                    .environmentObject(authService)
            } label: {
                Label(L("settings.blockedUsers"), systemImage: "person.crop.circle.badge.xmark")
                    .foregroundColor(.tteDarkGray)
            }
            Button {
                showSignOutAlert = true
            } label: {
                Label(L("settings.signOut"), systemImage: "arrow.right.square")
                    .foregroundColor(.red)
            }
            Button {
                showDeleteAccountAlert = true
            } label: {
                Label(L("settings.deleteAccount"), systemImage: "person.crop.circle.badge.minus")
                    .foregroundColor(.red)
            }
        }
    }
}
