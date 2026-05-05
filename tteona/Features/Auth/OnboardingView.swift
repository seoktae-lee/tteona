import SwiftUI
import CoreLocation
import AVFoundation
import UserNotifications

struct OnboardingView: View {
    @EnvironmentObject private var authService: AuthService
    @StateObject private var userService = UserService()
    @State private var step = 0
    @State private var nickname = ""
    @State private var agreedTerms = false
    @State private var agreedPrivacy = false
    @State private var locationGranted = false
    @State private var notificationGranted = false
    @State private var cameraGranted = false

    private let totalSteps = 4

    var body: some View {
        ZStack {
            Color.tteBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                progressBar
                    .padding(.top, 56)
                    .padding(.horizontal, 24)

                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: nicknameStep
                    case 2: permissionStep
                    case 3: termsStep
                    default: EmptyView()
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(.easeInOut(duration: 0.3), value: step)
            }
        }
    }

    // MARK: - Progress Bar
    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? Color.tteOrange : Color(UIColor.tertiarySystemFill))
                    .frame(height: 4)
                    .animation(.easeInOut(duration: 0.3), value: step)
            }
        }
    }

    // MARK: - Step 0: 환영
    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                Text("✈️")
                    .font(.system(size: 72))

                VStack(spacing: 10) {
                    Text("떠나에 오신 걸\n환영해요!")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.tteDarkGray)
                        .multilineTextAlignment(.center)

                    Text("GPS가 장소 도착을 감지하면\n자동으로 촬영 알림을 보내드려요.\n여행이 끝나면 Vlog가 완성됩니다.")
                        .font(.system(size: 16))
                        .foregroundColor(.tteMediumGray)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
            }

            Spacer()

            featurePreview
                .padding(.bottom, 48)

            nextButton(title: "시작하기") { step = 1 }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
        }
    }

    private var featurePreview: some View {
        HStack(spacing: 16) {
            ForEach([
                ("📍", "코스 탐색"),
                ("📹", "자동 촬영"),
                ("🎬", "Vlog 생성")
            ], id: \.0) { emoji, label in
                VStack(spacing: 8) {
                    Text(emoji)
                        .font(.system(size: 32))
                        .frame(width: 64, height: 64)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.tteOrange.opacity(0.1))
                        )
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.tteDarkGray)
                }
            }
        }
    }

    // MARK: - Step 1: 닉네임
    private var nicknameStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("닉네임을\n설정해주세요")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.tteDarkGray)
                    .padding(.top, 48)

                Text("코스를 만들 때 닉네임이 표시됩니다.")
                    .font(.system(size: 15))
                    .foregroundColor(.tteMediumGray)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 8) {
                TteTextField(placeholder: "닉네임 입력 (2~10자)", text: $nickname)
                    .padding(.horizontal, 24)

                HStack {
                    Spacer()
                    Text("\(nickname.count)/10")
                        .font(.system(size: 12))
                        .foregroundColor(nickname.count > 10 ? .red : .tteMediumGray)
                        .padding(.trailing, 28)
                }
            }

            Spacer()

            VStack(spacing: 12) {
                nextButton(title: "다음") {
                    Task { await saveNickname() }
                }
                .disabled(nickname.trimmingCharacters(in: .whitespaces).count < 2 || nickname.count > 10)
                .opacity(nickname.trimmingCharacters(in: .whitespaces).count < 2 || nickname.count > 10 ? 0.4 : 1)

                Button("나중에 설정하기") { step = 2 }
                    .font(.system(size: 14))
                    .foregroundColor(.tteMediumGray)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Step 2: 권한
    private var permissionStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("앱 사용을 위해\n권한이 필요해요")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.tteDarkGray)
                    .padding(.top, 48)

                Text("아래 권한들은 핵심 기능에 사용됩니다.")
                    .font(.system(size: 15))
                    .foregroundColor(.tteMediumGray)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 14) {
                PermissionRow(
                    emoji: "📍",
                    title: "위치 권한",
                    description: "장소 도착을 감지하고 지도에 현재 위치를 표시해요",
                    isGranted: locationGranted
                ) {
                    requestLocation()
                }

                PermissionRow(
                    emoji: "🔔",
                    title: "알림 권한",
                    description: "장소에 도착하면 촬영 알림을 보내드려요",
                    isGranted: notificationGranted
                ) {
                    requestNotification()
                }

                PermissionRow(
                    emoji: "📷",
                    title: "카메라 권한",
                    description: "각 장소에서 10초 영상을 촬영해요",
                    isGranted: cameraGranted
                ) {
                    requestCamera()
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            nextButton(title: "다음") { step = 3 }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
        }
    }

    // MARK: - Step 3: 약관
    private var termsStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("서비스 이용을\n동의해주세요")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.tteDarkGray)
                    .padding(.top, 48)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                // 전체 동의
                Button {
                    let newValue = !(agreedTerms && agreedPrivacy)
                    withAnimation { agreedTerms = newValue; agreedPrivacy = newValue }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: (agreedTerms && agreedPrivacy) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24))
                            .foregroundColor((agreedTerms && agreedPrivacy) ? .tteOrange : Color(UIColor.tertiaryLabel))

                        Text("전체 동의")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.tteDarkGray)
                        Spacer()
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill((agreedTerms && agreedPrivacy) ? Color.tteOrange.opacity(0.06) : Color(UIColor.secondarySystemBackground))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke((agreedTerms && agreedPrivacy) ? Color.tteOrange.opacity(0.3) : Color.clear, lineWidth: 1.5)
                            )
                    )
                }

                Divider().padding(.horizontal, 8)

                TermsRow(title: "서비스 이용약관 동의", isRequired: true, isChecked: $agreedTerms)
                TermsRow(title: "개인정보 처리방침 동의", isRequired: true, isChecked: $agreedPrivacy)
            }
            .padding(.horizontal, 24)

            Spacer()

            nextButton(title: "떠나기 시작! 🎉") {
                Task { await finishOnboarding() }
            }
            .disabled(!agreedTerms || !agreedPrivacy)
            .opacity(!agreedTerms || !agreedPrivacy ? 0.4 : 1)
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Reusable Next Button
    private func nextButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.tteOrange)
                )
        }
    }

    // MARK: - Actions
    private func saveNickname() async {
        guard let uid = authService.currentUser?.uid else { return }
        let user = AppUser(
            uid: uid,
            email: authService.currentUser?.email ?? "",
            nickname: nickname.trimmingCharacters(in: .whitespaces)
        )
        try? await userService.saveUser(user)
        step = 2
    }

    private func finishOnboarding() async {
        guard let uid = authService.currentUser?.uid else { return }
        // 닉네임만 설정하고 약관은 건너뛴 경우 users 문서 생성
        if userService.currentUser == nil {
            let user = AppUser(uid: uid, email: authService.currentUser?.email ?? "", nickname: "")
            try? await userService.saveUser(user)
        }
        // onboarding 완료 플래그 저장
        UserDefaults.standard.set(true, forKey: "onboarding_\(uid)")
        // AuthService의 currentUser를 업데이트하면 RootView가 메인으로 전환
        authService.onboardingComplete = true
    }

    // MARK: - Permission Requests
    private func requestLocation() {
        let manager = CLLocationManager()
        manager.requestAlwaysAuthorization()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let status = manager.authorizationStatus
            locationGranted = status == .authorizedAlways || status == .authorizedWhenInUse
        }
    }

    private func requestNotification() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { notificationGranted = granted }
        }
    }

    private func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { cameraGranted = granted }
        }
    }
}

// MARK: - Permission Row
struct PermissionRow: View {
    let emoji: String
    let title: String
    let description: String
    let isGranted: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(emoji)
                .font(.system(size: 28))
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.tteOrange.opacity(0.1))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.tteDarkGray)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.tteMediumGray)
                    .lineLimit(2)
            }

            Spacer()

            Button(action: onTap) {
                Text(isGranted ? "허용됨" : "허용")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isGranted ? .green : .white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(isGranted ? Color.green.opacity(0.12) : Color.tteOrange)
                    )
            }
            .disabled(isGranted)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
}

// MARK: - Terms Row
struct TermsRow: View {
    let title: String
    let isRequired: Bool
    @Binding var isChecked: Bool

    var body: some View {
        Button { withAnimation { isChecked.toggle() } } label: {
            HStack(spacing: 12) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isChecked ? .tteOrange : Color(UIColor.tertiaryLabel))

                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(.tteDarkGray)

                if isRequired {
                    Text("필수")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.tteOrange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.tteOrange.opacity(0.1)))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
            }
            .padding(.horizontal, 4)
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AuthService())
}
