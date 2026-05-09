import SwiftUI
import AuthenticationServices
import GoogleSignIn

struct AuthView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var isSignUp = false
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showResetAlert = false
    @State private var resetSent = false
    @FocusState private var focusedField: AuthField?

    enum AuthField { case email, password, confirm }

    var body: some View {
        ZStack {
            Color.tteBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    logoSection
                        .padding(.top, 80)
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
                            Text("비밀번호를 잊으셨나요?")
                                .font(.system(size: 13))
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
        .onTapGesture { focusedField = nil }
        .alert("비밀번호 재설정", isPresented: $showResetAlert) {
            TextField("이메일 주소", text: $email)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("전송") {
                Task {
                    let success = await authService.sendPasswordReset(email: email)
                    if success { resetSent = true }
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("가입한 이메일 주소를 입력하면 비밀번호 재설정 링크를 보내드려요.")
        }
        .alert("이메일을 보냈어요", isPresented: $resetSent) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("입력하신 이메일로 비밀번호 재설정 링크를 전송했어요. 메일함을 확인해주세요.")
        }
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
        VStack(spacing: 16) {
            Text("소셜 계정으로 로그인")
                .font(.system(size: 13))
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
                    Text("G")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .red, .yellow, .green],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                // Apple
                SocialCircleButton(
                    background: Color.tteDarkGray,
                    border: Color.clear
                ) {
                    AppleSignInCoordinator.shared.signIn(authService: authService)
                } label: {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white)
                }

                // 카카오
                SocialCircleButton(
                    background: Color(hex: "#FEE500"),
                    border: Color.clear
                ) {
                    Task { await authService.signInWithKakao() }
                } label: {
                    Image(systemName: "message.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color(hex: "#3A1D1D"))
                }
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
            Text("6자 이상 입력해주세요")
                .font(.system(size: 12))
                .foregroundColor(.tteMediumGray)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, -6)

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
