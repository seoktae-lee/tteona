import Foundation
import Combine
import FirebaseAuth
import FirebaseCore
import AuthenticationServices
import CryptoKit
import GoogleSignIn
import KakaoSDKCommon
import KakaoSDKAuth
import KakaoSDKUser

@MainActor
class AuthService: NSObject, ObservableObject {
    @Published var currentUser: AppUser?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var onboardingComplete = false
    @Published var isInitializing = true

    var isLoggedIn: Bool { currentUser != nil }

    private var authStateHandle: AuthStateDidChangeListenerHandle?
    private var currentNonce: String?

    override init() {
        super.init()
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                if let user {
                    self?.currentUser = AppUser(uid: user.uid, email: user.email ?? "")
                    self?.onboardingComplete = UserDefaults.standard.bool(forKey: "onboarding_\(user.uid)")
                } else {
                    self?.currentUser = nil
                    self?.onboardingComplete = false
                }
                self?.isInitializing = false
            }
        }
    }

    deinit {
        if let handle = authStateHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    // MARK: - 이메일 로그인
    func signIn(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard isValidEmail(email) else { errorMessage = "올바른 이메일 형식이 아닙니다."; return }
        guard password.count >= 6 else { errorMessage = "비밀번호는 6자 이상이어야 합니다."; return }

        do {
            try await Auth.auth().signIn(withEmail: email, password: password)
        } catch {
            errorMessage = firebaseErrorMessage(error)
        }
    }

    // MARK: - 이메일 회원가입
    func signUp(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard isValidEmail(email) else { errorMessage = "올바른 이메일 형식이 아닙니다."; return }
        guard password.count >= 6 else { errorMessage = "비밀번호는 6자 이상이어야 합니다."; return }

        do {
            try await Auth.auth().createUser(withEmail: email, password: password)
        } catch {
            errorMessage = firebaseErrorMessage(error)
        }
    }

    // MARK: - Apple 로그인
    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let nonce = currentNonce,
              let appleIDToken = credential.identityToken,
              let idTokenString = String(data: appleIDToken, encoding: .utf8) else {
            errorMessage = "Apple 로그인에 실패했습니다."
            return
        }

        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: nonce,
            fullName: credential.fullName
        )

        do {
            try await Auth.auth().signIn(with: firebaseCredential)
        } catch {
            errorMessage = firebaseErrorMessage(error)
        }
    }

    func prepareAppleSignIn() -> String {
        let nonce = randomNonceString()
        currentNonce = nonce
        return sha256(nonce)
    }

    // MARK: - Google 로그인
    func signInWithGoogle(presenting viewController: UIViewController) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let clientID = FirebaseApp.app()?.options.clientID else {
            errorMessage = "Google 로그인 설정 오류입니다."
            return
        }

        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: viewController)
            guard let idToken = result.user.idToken?.tokenString else {
                errorMessage = "Google 인증 토큰을 가져올 수 없습니다."
                return
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            try await Auth.auth().signIn(with: credential)
        } catch {
            errorMessage = firebaseErrorMessage(error)
        }
    }

    // MARK: - 카카오 로그인
    func signInWithKakao() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // 카카오톡 앱 설치 여부에 따라 분기
            let oauthToken: OAuthToken = try await withCheckedThrowingContinuation { cont in
                if UserApi.isKakaoTalkLoginAvailable() {
                    UserApi.shared.loginWithKakaoTalk { token, error in
                        if let error { cont.resume(throwing: error) }
                        else if let token { cont.resume(returning: token) }
                    }
                } else {
                    UserApi.shared.loginWithKakaoAccount { token, error in
                        if let error { cont.resume(throwing: error) }
                        else if let token { cont.resume(returning: token) }
                    }
                }
            }

            // 카카오 사용자 정보 가져오기
            let kakaoUser: KakaoSDKUser.User = try await withCheckedThrowingContinuation { cont in
                UserApi.shared.me { user, error in
                    if let error { cont.resume(throwing: error) }
                    else if let user { cont.resume(returning: user) }
                }
            }

            // Firebase 익명 로그인 후 카카오 UID 기반 커스텀 처리
            // (Firebase Custom Token 서버 없이 사용할 경우 익명 로그인 활용)
            let kakaoId = kakaoUser.id ?? 0
            let email = kakaoUser.kakaoAccount?.email ?? "\(kakaoId)@kakao.tteona"
            let _ = oauthToken

            // 이미 Firebase 계정이 있으면 로그인, 없으면 생성
            do {
                try await Auth.auth().signIn(withEmail: email, password: "kakao_\(kakaoId)_tteona")
            } catch {
                // 계정 없으면 자동 생성
                try await Auth.auth().createUser(withEmail: email, password: "kakao_\(kakaoId)_tteona")
            }
        } catch {
            errorMessage = "카카오 로그인에 실패했습니다."
        }
    }

    // MARK: - 로그아웃
    func signOut() {
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
    }

    // MARK: - Helpers
    private func isValidEmail(_ email: String) -> Bool {
        let regex = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return email.range(of: regex, options: .regularExpression) != nil
    }

    private func firebaseErrorMessage(_ error: Error) -> String {
        let code = AuthErrorCode(rawValue: (error as NSError).code)
        switch code {
        case .emailAlreadyInUse:    return "이미 사용 중인 이메일입니다."
        case .invalidEmail:          return "올바른 이메일 형식이 아닙니다."
        case .wrongPassword:         return "비밀번호가 올바르지 않습니다."
        case .userNotFound:          return "존재하지 않는 계정입니다."
        case .networkError:          return "네트워크 오류가 발생했습니다."
        case .weakPassword:          return "비밀번호는 6자 이상이어야 합니다."
        default:                     return "오류가 발생했습니다. 다시 시도해주세요."
        }
    }

    private func randomNonceString(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            randoms.forEach { random in
                if remainingLength == 0 { return }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

