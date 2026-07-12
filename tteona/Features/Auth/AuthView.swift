import SwiftUI
import AuthenticationServices
import GoogleSignIn
import FirebaseAuth

struct AuthView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var isSignUp = false
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showResetAlert = false
    @State private var resetSent = false
    @State private var resendSent = false
    @State private var resendMessage = ""
    @State private var resendCooldown = 0
    @State private var cooldownTask: Task<Void, Never>? = nil
    @State private var isCheckingVerification = false
    @FocusState private var focusedField: AuthField?

    enum AuthField { case email, password, confirm }

    var body: some View {
        ZStack {
            TteonaSplashBackground()

            // 언어 선택 — 외국인 사용자가 가입 전부터 앱을 이해할 수 있게 첫 화면에서 고른다.
            // 언어 변경은 루트 .id(language) 재구성으로 즉시 전체 반영된다.
            VStack {
                HStack {
                    Spacer()
                    languagePicker
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .zIndex(1)

            if authService.verificationEmailSent {
                verificationSentView
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        logoSection
                            .padding(.top, 120)
                            .padding(.bottom, 48)

                        socialLoginSection
                            .padding(.horizontal, 24)
                            .padding(.bottom, 28)

                        inputSection
                            .padding(.horizontal, 24)

                        actionButton
                            .padding(.horizontal, 24)
                            .padding(.top, 16)

                        if !isSignUp {
                            Button {
                                showResetAlert = true
                            } label: {
                                Text(L("auth.forgotPassword"))
                                    .font(.tte(13))
                                    .foregroundColor(.tteMediumGray)
                                    .underline()
                            }
                            .padding(.top, 12)
                        }

                        toggleModeButton
                            .padding(.top, 16)
                            .padding(.bottom, 40)
                    }
                }
            }
        }
        .onTapGesture { focusedField = nil }
        .alert(L("auth.resetPassword"), isPresented: $showResetAlert) {
            TextField(L("auth.emailAddress"), text: $email)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(L("auth.send")) {
                Task {
                    let success = await authService.sendPasswordReset(email: email)
                    if success { resetSent = true }
                }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("auth.resetPassword.message"))
        }
        .alert(L("auth.emailSent.title"), isPresented: $resetSent) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(L("auth.emailSent.message"))
        }
        .alert(L("auth.verificationMail"), isPresented: $resendSent) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(resendMessage)
        }
    }

    // MARK: - 인증 메일 발송 완료 화면
    private var verificationSentView: some View {
        VStack(spacing: 0) {
            Spacer()

            // 온보딩 스타일 아이콘
            ZStack {
                Circle()
                    .fill(Color.tteOrange.opacity(0.08))
                    .frame(width: 160, height: 160)
                Circle()
                    .fill(Color.tteOrange.opacity(0.14))
                    .frame(width: 120, height: 120)
                Image(systemName: "envelope.badge.fill")
                    .font(.tte(48, .medium))
                    .foregroundColor(.tteOrange)
            }
            .padding(.bottom, 40)

            VStack(spacing: 12) {
                Text(L("auth.checkEmail.title"))
                    .font(.tte(24, .bold))
                    .foregroundColor(.tteDarkGray)
                Text(L("auth.checkEmail.message"))
                    .font(.tte(15))
                    .foregroundColor(.tteMediumGray)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                Text(L("auth.checkSpam"))
                    .font(.tte(12))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
                    .padding(.top, 4)
            }

            Spacer()

            VStack(spacing: 12) {
                if let error = authService.errorMessage {
                    Text(error)
                        .font(.tte(13))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }

                Button {
                    resendVerificationEmail()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.tte(13, .medium))
                        Text(resendCooldown > 0 ? L("auth.resendIn", resendCooldown) : L("auth.resendVerification"))
                            .font(.tte(14, .medium))
                    }
                    .foregroundColor(resendCooldown > 0 ? Color(UIColor.tertiaryLabel) : .tteOrange)
                }
                .disabled(resendCooldown > 0)
                .padding(.top, 4)

                Button {
                    Task { await verifyAndLogin() }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.tteOrange)
                            .frame(height: 54)
                        if isCheckingVerification {
                            ProgressView().tint(.white)
                        } else {
                            Text(L("auth.startAfterVerify"))
                                .font(.tte(17, .semibold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .disabled(isCheckingVerification)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
        .onAppear { startResendCooldown() }
        .onDisappear {
            cooldownTask?.cancel()
            cooldownTask = nil
        }
    }

    private func verifyAndLogin() async {
        isCheckingVerification = true
        defer { isCheckingVerification = false }

        do {
            if let user = Auth.auth().currentUser {
                try? await user.reload()
                if user.isEmailVerified {
                    cooldownTask?.cancel()
                    cooldownTask = nil
                    resendCooldown = 0
                    authService.currentUser = AppUser(uid: user.uid, email: user.email ?? "")
                    await authService.refreshOnboardingStatus(uid: user.uid)
                    authService.verificationEmailSent = false
                } else {
                    authService.errorMessage = L("auth.notVerifiedYet")
                }
                return
            }

            // currentUser가 없으면 (예: 앱 재실행) 입력된 계정으로 로그인 후 확인
            guard !email.isEmpty, !password.isEmpty else {
                authService.errorMessage = L("auth.reenterForVerify")
                return
            }

            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            try? await result.user.reload()
            if let verifiedUser = Auth.auth().currentUser, verifiedUser.isEmailVerified {
                cooldownTask?.cancel()
                cooldownTask = nil
                resendCooldown = 0
                authService.currentUser = AppUser(uid: verifiedUser.uid, email: verifiedUser.email ?? "")
                await authService.refreshOnboardingStatus(uid: verifiedUser.uid)
                authService.verificationEmailSent = false
            } else {
                try? Auth.auth().signOut()
                authService.errorMessage = L("auth.notVerifiedYet")
            }
        } catch {
            authService.errorMessage = L("auth.signInFailed")
        }
    }

    private func resendVerificationEmail() {
        Task {
            do {
                if let user = Auth.auth().currentUser {
                    try await user.sendEmailVerification()
                    await MainActor.run {
                        authService.errorMessage = nil
                        resendMessage = L("auth.resendDone")
                        resendSent = true
                    }
                    startResendCooldown()
                } else if !email.isEmpty, !password.isEmpty {
                    let result = try await Auth.auth().signIn(withEmail: email, password: password)
                    try await result.user.sendEmailVerification()
                    try? Auth.auth().signOut()
                    await MainActor.run {
                        authService.errorMessage = nil
                        resendMessage = L("auth.resendDone")
                        resendSent = true
                    }
                    startResendCooldown()
                } else {
                    await MainActor.run {
                        authService.errorMessage = L("auth.reenterForResend")
                    }
                }
            } catch {
                await MainActor.run {
                    authService.errorMessage = L("auth.resendFailed")
                }
            }
        }
    }

    private func startResendCooldown() {
        resendCooldown = 60
        cooldownTask?.cancel()
        cooldownTask = Task {
            while resendCooldown > 0 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run { resendCooldown -= 1 }
            }
        }
    }

    // MARK: - Language Picker (가입 전 언어 선택)
    private var languagePicker: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    guard language != LanguageManager.shared.language else { return }
                    Haptics.light()
                    LanguageManager.shared.setLanguage(language)
                } label: {
                    if language == LanguageManager.shared.language {
                        Label("\(language.flag) \(language.nativeName)", systemImage: "checkmark")
                    } else {
                        Text("\(language.flag) \(language.nativeName)")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.tte(13, .medium))
                Text(LanguageManager.shared.language.nativeName)
                    .font(.tte(13, .medium))
                Image(systemName: "chevron.down")
                    .font(.tte(10, .semibold))
            }
            .foregroundColor(.tteMediumGray)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(UIColor.systemBackground).opacity(0.7))
                    .overlay(Capsule().stroke(Color(UIColor.separator).opacity(0.5), lineWidth: 1))
            )
        }
    }

    // MARK: - Logo
    private var logoSection: some View {
        VStack(spacing: 12) {
            TteonaWordmarkLogo()

            Text(L("auth.tagline"))
                .font(.tte(15))
                .foregroundColor(.tteMediumGray)
        }
    }

    // MARK: - Social Login
    private var socialLoginSection: some View {
        VStack(spacing: 16) {
            Text(L("auth.socialLogin"))
                .font(.tte(13))
                .foregroundColor(.tteMediumGray)

            HStack(spacing: 24) {
                // Google
                SocialCircleButton(
                    background: .white,
                    border: Color(UIColor.separator)
                ) {
                    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                          let vc = windowScene.windows.first?.rootViewController else { return }
                    Task { await authService.signInWithGoogle(presenting: vc) }
                } label: {
                    // 구글 공식 표준 색상 G 로고 (미변형) — 브랜드 가이드 준수
                    Image("GoogleG")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                }
                .disabled(authService.isLoading)

                // Apple
                SocialCircleButton(
                    background: Color.tteDarkGray,
                    border: Color.clear
                ) {
                    AppleSignInCoordinator.shared.signIn(authService: authService)
                } label: {
                    Image(systemName: "apple.logo")
                        .font(.tte(22, .medium))
                        .foregroundColor(.white)
                }
                .disabled(authService.isLoading)

                // 카카오
                SocialCircleButton(
                    background: Color(hex: "#FEE500"),
                    border: Color.clear
                ) {
                    Task { await authService.signInWithKakao() }
                } label: {
                    // 카카오 공식 심볼(#FEE500 배경 위 검정 말풍선) — 가이드상 심볼은 변형·대체 불가.
                    // "KakaoSymbol" 에셋(공식 심볼 PNG)을 넣으면 자동 사용, 없으면 임시 폴백.
                    if UIImage(named: "KakaoSymbol") != nil {
                        Image("KakaoSymbol")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "message.fill")
                            .font(.tte(20))
                            .foregroundColor(Color(hex: "#191919"))
                    }
                }
                .disabled(authService.isLoading)
            }
        }
    }

    // MARK: - Divider
    private var dividerSection: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 1)
            Text(L("auth.orContinueWithEmail"))
                .font(.tte(12))
                .foregroundColor(.tteMediumGray)
                .fixedSize()
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 1)
        }
    }

    // MARK: - Email Input
    private var inputSection: some View {
        VStack(spacing: 14) {
            TteTextField(placeholder: L("auth.email"), text: $email, keyboardType: .emailAddress)
                .focused($focusedField, equals: .email)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }

            TteTextField(placeholder: L("auth.password"), text: $password, isSecure: true)
                .focused($focusedField, equals: .password)
                .submitLabel(isSignUp ? .next : .done)
                .onSubmit {
                    if isSignUp { focusedField = .confirm }
                    else { Task { await submit() } }
                }
            Text(L("auth.passwordHint"))
                .font(.tte(12))
                .foregroundColor(.tteMediumGray)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, -6)

            if isSignUp {
                TteTextField(placeholder: L("auth.confirmPassword"), text: $confirmPassword, isSecure: true)
                    .focused($focusedField, equals: .confirm)
                    .submitLabel(.done)
                    .onSubmit { Task { await submit() } }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let error = authService.errorMessage {
                Text(error)
                    .font(.tte(13))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSignUp)
    }

    // MARK: - Action Button
    private var actionButton: some View {
        Button {
            Task { await submit() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.tteOrange)
                    .frame(height: 54)

                if authService.isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(isSignUp ? L("auth.signUp") : L("auth.signIn"))
                        .font(.tte(17, .semibold))
                        .foregroundColor(.white)
                }
            }
        }
        .disabled(authService.isLoading)
    }

    // MARK: - Toggle Mode
    private var toggleModeButton: some View {
        Button {
            withAnimation { isSignUp.toggle() }
            authService.errorMessage = nil
            confirmPassword = ""
        } label: {
            HStack(spacing: 4) {
                Text(isSignUp ? L("auth.alreadyHaveAccount") : L("auth.noAccount"))
                    .foregroundColor(.tteMediumGray)
                Text(isSignUp ? L("auth.signIn") : L("auth.signUp"))
                    .foregroundColor(.tteOrange)
                    .fontWeight(.semibold)
            }
            .font(.tte(14))
        }
    }

    // MARK: - Submit
    private func submit() async {
        focusedField = nil
        if isSignUp {
            guard password == confirmPassword else {
                authService.errorMessage = L("auth.passwordMismatch")
                return
            }
            await authService.signUp(email: email, password: password)
        } else {
            await authService.signIn(email: email, password: password)
        }
    }
}

// MARK: - Social Circle Button
struct SocialCircleButton<Label: View>: View {
    let background: Color
    let border: Color
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(background)
                    .frame(width: 60, height: 60)
                    .overlay(Circle().stroke(border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                label()
            }
            .frame(height: 54)
        }
    }
}

// MARK: - Reusable Text Field
struct TteTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var isSecure = false

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
                    .keyboardType(keyboardType)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            }
        }
        .font(.tte(16))
        .foregroundColor(.tteDarkGray)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
}

#Preview {
    AuthView()
        .environmentObject(AuthService())
}
