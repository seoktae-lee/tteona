import SwiftUI
import AuthenticationServices
import GoogleSignIn

struct AuthView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var isSignUp = false
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @FocusState private var focusedField: AuthField?

    enum AuthField { case email, password, confirm }

    var body: some View {
        ZStack {
            Color.tteBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    logoSection
                        .padding(.top, 80)
                        .padding(.bottom, 48)

                    socialLoginSection
                        .padding(.horizontal, 24)

                    dividerSection
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)

                    inputSection
                        .padding(.horizontal, 24)

                    actionButton
                        .padding(.horizontal, 24)
                        .padding(.top, 16)

                    toggleModeButton
                        .padding(.top, 20)
                        .padding(.bottom, 40)
                }
            }
        }
        .onTapGesture { focusedField = nil }
    }

    // MARK: - Logo
    private var logoSection: some View {
        VStack(spacing: 12) {
            Text("tteona")
                .font(.system(size: 52, weight: .bold))
                .foregroundColor(.tteOrange)

            Text("특별한 순간을 영상으로 기록하세요")
                .font(.system(size: 15))
                .foregroundColor(.tteMediumGray)
        }
    }

    // MARK: - Social Login
    private var socialLoginSection: some View {
        VStack(spacing: 12) {
            // Apple 로그인
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
                request.nonce = authService.prepareAppleSignIn()
            } onCompletion: { result in
                switch result {
                case .success(let auth):
                    if let credential = auth.credential as? ASAuthorizationAppleIDCredential {
                        Task { await authService.signInWithApple(credential: credential) }
                    }
                case .failure:
                    authService.errorMessage = "Apple 로그인에 실패했습니다."
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            // Google 로그인
            SocialLoginButton(
                icon: "google_logo",
                systemIcon: "g.circle.fill",
                title: "Google로 계속하기",
                background: Color.white,
                foreground: Color.tteDarkGray,
                border: Color(UIColor.separator)
            ) {
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let vc = windowScene.windows.first?.rootViewController else { return }
                Task { await authService.signInWithGoogle(presenting: vc) }
            }

            // 카카오 로그인
            SocialLoginButton(
                icon: nil,
                systemIcon: nil,
                title: "카카오로 계속하기",
                background: Color(hex: "#FEE500"),
                foreground: Color(hex: "#191919"),
                border: Color.clear,
                emoji: "💬"
            ) {
                Task { await authService.signInWithKakao() }
            }
        }
    }

    // MARK: - Divider
    private var dividerSection: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 1)
            Text("또는 이메일로 계속하기")
                .font(.system(size: 12))
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
            TteTextField(placeholder: "이메일", text: $email, keyboardType: .emailAddress)
                .focused($focusedField, equals: .email)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }

            TteTextField(placeholder: "비밀번호", text: $password, isSecure: true)
                .focused($focusedField, equals: .password)
                .submitLabel(isSignUp ? .next : .done)
                .onSubmit {
                    if isSignUp { focusedField = .confirm }
                    else { Task { await submit() } }
                }

            if isSignUp {
                TteTextField(placeholder: "비밀번호 확인", text: $confirmPassword, isSecure: true)
                    .focused($focusedField, equals: .confirm)
                    .submitLabel(.done)
                    .onSubmit { Task { await submit() } }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let error = authService.errorMessage {
                Text(error)
                    .font(.system(size: 13))
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
                    Text(isSignUp ? "회원가입" : "로그인")
                        .font(.system(size: 17, weight: .semibold))
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
                Text(isSignUp ? "이미 계정이 있으신가요?" : "계정이 없으신가요?")
                    .foregroundColor(.tteMediumGray)
                Text(isSignUp ? "로그인" : "회원가입")
                    .foregroundColor(.tteOrange)
                    .fontWeight(.semibold)
            }
            .font(.system(size: 14))
        }
    }

    // MARK: - Submit
    private func submit() async {
        focusedField = nil
        if isSignUp {
            guard password == confirmPassword else {
                authService.errorMessage = "비밀번호가 일치하지 않습니다."
                return
            }
            await authService.signUp(email: email, password: password)
        } else {
            await authService.signIn(email: email, password: password)
        }
    }
}

// MARK: - Social Login Button
struct SocialLoginButton: View {
    let icon: String?
    let systemIcon: String?
    let title: String
    let background: Color
    let foreground: Color
    let border: Color
    var emoji: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let emoji {
                    Text(emoji)
                        .font(.system(size: 20))
                } else if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: 20))
                        .foregroundColor(foreground)
                }

                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(foreground)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(border, lineWidth: 1)
                    )
            )
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
        .font(.system(size: 16))
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
