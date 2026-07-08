import SwiftUI
import CoreLocation
import AVFoundation
import UserNotifications
import Photos

struct OnboardingView: View {
    @EnvironmentObject private var authService: AuthService
    @StateObject private var userService = UserService()
    @State private var step = 0
    @State private var nickname = ""
    @State private var nicknameState: NicknameState = .idle
    @State private var debounceTask: Task<Void, Never>? = nil
    @State private var agreedTerms = false

    enum NicknameState {
        case idle, checking, available, taken, inappropriate
    }
    @State private var agreedPrivacy = false
    @State private var locationGranted = false
    @State private var notificationGranted = false
    @State private var cameraGranted = false
    @State private var photoLibraryGranted = false
    @State private var selectedStyle: CourseTag? = nil

    private let totalSteps = 6

    init() {
        #if DEBUG
        // 시각 검증용: -previewOnboardingStep N 런치 아규먼트로 특정 단계 바로 진입
        let previewStep = UserDefaults.standard.integer(forKey: "previewOnboardingStep")
        if previewStep > 0 { _step = State(initialValue: previewStep) }
        #endif
    }

    var body: some View {
        ZStack {
            Color.tteBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // 기능 소개(step 1)는 자체 페이지 도트가 있으므로 닉네임 단계부터 표시
                if step > 1 {
                    progressBar
                        .padding(.top, 56)
                        .padding(.horizontal, 24)
                }

                Group {
                    switch step {
                    case 0: splashStep
                    case 1: featureIntroStep
                    case 2: nicknameStep
                    case 3: styleStep
                    case 4: permissionStep
                    case 5: termsStep
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

    // MARK: - Progress Bar (step 2~4 전용)
    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(1..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i < step ? Color.tteOrange : Color(UIColor.tertiarySystemFill))
                    .frame(height: 4)
                    .animation(.easeInOut(duration: 0.3), value: step)
            }
        }
    }

    // MARK: - Step 0: 스플래시
    private var splashStep: some View {
        ZStack {
            AuroraBackground(tint: .tteOrange)

            VStack(spacing: 0) {
                Spacer()

                SplashHeroView()

                Spacer()

                nextButton(title: L("onboarding.start")) {
                    Haptics.light()
                    withAnimation { step = 1 }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
            }
        }
    }

    // MARK: - Step 1: 기능 소개 슬라이드
    private var featureIntroStep: some View {
        OnboardingFeatureShowcase {
            withAnimation { step = 2 }
        }
    }

    // MARK: - Step 2: 닉네임
    private var nicknameStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("onboarding.nickname.title"))
                    .font(.tte(30, .bold))
                    .foregroundColor(.tteDarkGray)
                    .padding(.top, 24)

                Text(L("onboarding.nickname.subtitle"))
                    .font(.tte(15))
                    .foregroundColor(.tteMediumGray)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 8) {
                TteTextField(placeholder: L("onboarding.nickname.placeholder"), text: $nickname)
                    .padding(.horizontal, 24)
                    .onChange(of: nickname) { _, newValue in
                        scheduleNicknameCheck(newValue)
                    }

                HStack(spacing: 6) {
                    switch nicknameState {
                    case .checking:
                        ProgressView().scaleEffect(0.7)
                        Text(L("onboarding.nickname.checking"))
                            .font(.tte(12))
                            .foregroundColor(.tteMediumGray)
                    case .available:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.tte(13))
                            .foregroundColor(.green)
                        Text(L("onboarding.nickname.available"))
                            .font(.tte(12))
                            .foregroundColor(.green)
                    case .taken:
                        Image(systemName: "xmark.circle.fill")
                            .font(.tte(13))
                            .foregroundColor(.red)
                        Text(L("onboarding.nickname.taken"))
                            .font(.tte(12))
                            .foregroundColor(.red)
                    case .inappropriate:
                        Image(systemName: "xmark.circle.fill")
                            .font(.tte(13))
                            .foregroundColor(.red)
                        Text(L("onboarding.nickname.inappropriate"))
                            .font(.tte(12))
                            .foregroundColor(.red)
                    case .idle:
                        EmptyView()
                    }
                    Spacer()
                    Text("\(nickname.count)/10")
                        .font(.tte(12))
                        .foregroundColor(nickname.count > 10 ? .red : .tteMediumGray)
                }
                .padding(.horizontal, 28)
                .frame(height: 20)
            }

            Spacer()

            let isInvalid = nickname.trimmingCharacters(in: .whitespaces).count < 2
                || nickname.count > 10
                || nicknameState != .available
            VStack(spacing: 12) {
                nextButton(title: L("common.next")) {
                    Task { await saveNickname() }
                }
                .disabled(isInvalid)
                .opacity(isInvalid ? 0.4 : 1)

            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Step 3: 여행 취향 (건너뛰기 가능 — 추천 개인화 시드)
    private var styleStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("onboarding.style.title"))
                    .font(.tte(30, .bold))
                    .foregroundColor(.tteDarkGray)
                    .padding(.top, 24)

                Text(L("onboarding.style.subtitle"))
                    .font(.tte(15))
                    .foregroundColor(.tteMediumGray)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)

            Spacer()

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                ForEach(CourseTag.allCases, id: \.self) { tag in
                    styleCard(tag)
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                nextButton(title: L("common.next")) {
                    Haptics.light()
                    withAnimation { step = 4 }
                }
                .disabled(selectedStyle == nil)
                .opacity(selectedStyle == nil ? 0.4 : 1)

                Button(L("onboarding.style.skip")) {
                    selectedStyle = nil
                    withAnimation { step = 4 }
                }
                .font(.tte(14))
                .foregroundColor(.tteMediumGray)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private func styleCard(_ tag: CourseTag) -> some View {
        let isOn = selectedStyle == tag
        return Button {
            Haptics.light()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedStyle = isOn ? nil : tag
            }
        } label: {
            VStack(spacing: 10) {
                Text(tag.emoji)
                    .font(.system(size: 40))
                Text(tag.displayName)
                    .font(.tte(15, .semibold))
                    .foregroundColor(isOn ? .tteOrange : .tteDarkGray)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(isOn ? Color.tteOrange.opacity(0.1) : Color(UIColor.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(isOn ? Color.tteOrange : Color.clear, lineWidth: 1.5)
                    )
            )
            .scaleEffect(isOn ? 1.03 : 1)
        }
    }

    // MARK: - Step 4: 권한
    private var permissionStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("onboarding.permission.title"))
                    .font(.tte(30, .bold))
                    .foregroundColor(.tteDarkGray)
                    .padding(.top, 48)

                Text(L("onboarding.permission.subtitle"))
                    .font(.tte(15))
                    .foregroundColor(.tteMediumGray)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 14) {
                PermissionRow(
                    icon: "location.fill",
                    title: L("onboarding.permission.location"),
                    description: L("onboarding.permission.location.desc"),
                    isGranted: locationGranted
                ) {
                    Task { await requestLocation() }
                }

                PermissionRow(
                    icon: "bell.fill",
                    title: L("onboarding.permission.notification"),
                    description: L("onboarding.permission.notification.desc"),
                    isGranted: notificationGranted
                ) {
                    Task { await requestNotification() }
                }

                PermissionRow(
                    icon: "video.fill",
                    title: L("onboarding.permission.camera"),
                    description: L("onboarding.permission.camera.desc"),
                    isGranted: cameraGranted
                ) {
                    Task { await requestCamera() }
                }

                PermissionRow(
                    icon: "photo.fill",
                    title: L("onboarding.permission.photos"),
                    description: L("onboarding.permission.photos.desc"),
                    isGranted: photoLibraryGranted
                ) {
                    Task { await requestPhotoLibrary() }
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            nextButton(title: L("common.next")) {
                Task { await requestAllPermissionsThenContinue() }
            }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
        }
    }

    // MARK: - Step 5: 약관
    private var termsStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("onboarding.terms.title"))
                    .font(.tte(30, .bold))
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
                            .font(.tte(24))
                            .foregroundColor((agreedTerms && agreedPrivacy) ? .tteOrange : Color(UIColor.tertiaryLabel))

                        Text(L("onboarding.terms.agreeAll"))
                            .font(.tte(16, .semibold))
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

                TermsRow(title: L("onboarding.terms.service"), isRequired: true, url: URL(string: "https://tteona.kr/terms.html")!, isChecked: $agreedTerms)
                TermsRow(title: L("onboarding.terms.privacy"), isRequired: true, url: URL(string: "https://tteona.kr/privacy.html")!, isChecked: $agreedPrivacy)
            }
            .padding(.horizontal, 24)

            Spacer()

            let allAgreed = agreedTerms && agreedPrivacy
            nextButton(title: L("onboarding.letsGo")) {
                Task { await finishOnboarding() }
            }
            .disabled(!allAgreed)
            .opacity(allAgreed ? 1 : 0.4)
            .scaleEffect(allAgreed ? 1 : 0.95)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: allAgreed)
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Reusable Next Button
    private func nextButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.tte(17, .semibold))
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
    private func scheduleNicknameCheck(_ value: String) {
        debounceTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.count <= 10 else {
            nicknameState = .idle
            return
        }
        nicknameState = .checking
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            // 부적절 표현 검사 (댓글·코스명과 동일 기준, 서버 검사 실패 시 통과)
            guard await StatsService.shared.isTextAllowed(trimmed) else {
                if !Task.isCancelled { nicknameState = .inappropriate }
                return
            }
            let taken = await userService.isNicknameTaken(trimmed)
            guard !Task.isCancelled else { return }
            nicknameState = taken ? .taken : .available
        }
    }

    private func saveNickname() async {
        guard nicknameState == .available else { return }
        withAnimation { step = 3 }
    }

    private func finishOnboarding() async {
        guard let uid = authService.currentUser?.uid else { return }
        let user = AppUser(
            uid: uid,
            email: authService.currentUser?.email ?? "",
            nickname: nickname.trimmingCharacters(in: .whitespaces),
            preferredTag: selectedStyle?.rawValue
        )
        try? await userService.saveUser(user)
        // Firestore users 문서가 있으면 기존 유저로 간주되어 RootView가 메인으로 전환
        authService.onboardingComplete = true
    }

    // MARK: - Permission Requests
    private func requestLocation() async {
        // 고정 1초 지연으로 판정하면 유저가 늦게 응답한 경우 허용해도 미허용으로 표시됨 —
        // 시스템 권한 변경 콜백을 기다려 정확히 판정
        locationGranted = await LocationPermissionRequester.shared.request()
    }

    private func requestNotification() async {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                DispatchQueue.main.async {
                    notificationGranted = granted
                    // 앱 실행 시점 요청을 온보딩으로 미뤘으므로 허용 즉시 원격 알림 등록 (FCM 푸시 의존)
                    if granted {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                    continuation.resume()
                }
            }
        }
    }

    private func requestCamera() async {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    cameraGranted = granted
                    continuation.resume()
                }
            }
        }
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                continuation.resume()
            }
        }
    }

    private func requestPhotoLibrary() async {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                DispatchQueue.main.async {
                    photoLibraryGranted = status == .authorized || status == .limited
                    continuation.resume()
                }
            }
        }
    }

    private func requestAllPermissionsThenContinue() async {
        await requestLocation()
        await requestNotification()
        await requestCamera()
        await requestPhotoLibrary()
        await MainActor.run {
            withAnimation { step = 5 }
        }
    }
}

// MARK: - 위치 권한 요청 헬퍼 (권한 다이얼로그 응답을 콜백으로 대기)
@MainActor
final class LocationPermissionRequester: NSObject, CLLocationManagerDelegate {
    static let shared = LocationPermissionRequester()
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Bool, Never>?

    private override init() {
        super.init()
        manager.delegate = self
    }

    func request() async -> Bool {
        let status = manager.authorizationStatus
        guard status == .notDetermined else {
            return status == .authorizedAlways || status == .authorizedWhenInUse
        }
        // 이미 진행 중인 요청이 있으면 현재 상태 반환 (중복 continuation 방지)
        guard continuation == nil else {
            return status == .authorizedAlways || status == .authorizedWhenInUse
        }
        return await withCheckedContinuation { cont in
            continuation = cont
            manager.requestAlwaysAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            // 요청 직후 notDetermined 상태로 오는 최초 콜백은 무시
            guard status != .notDetermined, let cont = self.continuation else { return }
            self.continuation = nil
            cont.resume(returning: status == .authorizedAlways || status == .authorizedWhenInUse)
        }
    }
}

// MARK: - Permission Row
struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.tte(22, .medium))
                .foregroundColor(.tteOrange)
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.tteOrange.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.tte(15, .semibold))
                    .foregroundColor(.tteDarkGray)
                Text(description)
                    .font(.tte(12))
                    .foregroundColor(.tteMediumGray)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(action: onTap) {
                Text(isGranted ? L("onboarding.permission.granted") : L("onboarding.permission.continue"))
                    .font(.tte(13, .semibold))
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
    let url: URL
    @Binding var isChecked: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button { withAnimation { isChecked.toggle() } } label: {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.tte(20))
                    .foregroundColor(isChecked ? .tteOrange : Color(UIColor.tertiaryLabel))
            }

            Text(title)
                .font(.tte(14))
                .foregroundColor(.tteDarkGray)

            if isRequired {
                Text(L("onboarding.terms.required"))
                    .font(.tte(11, .medium))
                    .foregroundColor(.tteOrange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.tteOrange.opacity(0.1)))
            }

            Spacer()

            Button {
                UIApplication.shared.open(url)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.tte(12))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
            }
        }
        .padding(.horizontal, 4)
    }
}


#Preview {
    OnboardingView()
        .environmentObject(AuthService())
}
