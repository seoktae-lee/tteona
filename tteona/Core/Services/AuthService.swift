import Foundation
import Combine
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import AuthenticationServices
import CryptoKit
import GoogleSignIn
import KakaoSDKCommon
import KakaoSDKAuth
import KakaoSDKUser

// GTMSessionFetcher 충돌 방지를 위해 Firebase Functions SDK 대신 URLSession으로 직접 호출
private func fetchKakaoCustomToken(kakaoAccessToken: String) async throws -> String {
    let url = URL(string: "https://us-central1-tteona-dev.cloudfunctions.net/createKakaoCustomToken")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body = ["data": ["kakaoAccessToken": kakaoAccessToken]]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

    guard statusCode == 200 else {
        throw NSError(domain: "tteona.kakao", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: L("auth.error.serverResponse", statusCode)])
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = json["result"] as? [String: Any],
          let token = result["customToken"] as? String, !token.isEmpty else {
        #if DEBUG
        let rawBody = String(data: data, encoding: .utf8) ?? "(empty)"
        print("[Kakao] 응답 파싱 실패: \(rawBody)")
        #endif
        throw NSError(domain: "tteona.kakao", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: L("auth.error.invalidResponse")])
    }
    return token
}

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
    private let db = Firestore.firestore()
    private var kakaoSignInTask: Task<Void, Never>?

    override init() {
        super.init()
        // 앱 재설치 시 Keychain에 남은 Firebase 토큰 제거
        if !UserDefaults.standard.bool(forKey: "app_installed") {
            try? Auth.auth().signOut()
            UserDefaults.standard.set(true, forKey: "app_installed")
        }
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] (_: FirebaseAuth.Auth, user: FirebaseAuth.User?) in
            Task { @MainActor in
                if let user {
                    let providerIDs = user.providerData.map { $0.providerID }
                    // 순수 이메일/비밀번호 계정만 이메일 인증 필요.
                    // 카카오(커스텀 토큰)는 providerData가 비어있어 allSatisfy가 true를 반환하는 함정을
                    // 피하기 위해 password provider가 실제로 존재하는지 먼저 확인한다.
                    let isEmailPassword = providerIDs.contains("password")
                        && providerIDs.allSatisfy { $0 == "password" }
                    let needsVerification = isEmailPassword && !user.isEmailVerified
                    #if DEBUG
                    print("[Auth] uid=\(user.uid) isEmailVerified=\(user.isEmailVerified) needsVerification=\(needsVerification) verificationEmailSent=\(self?.verificationEmailSent ?? false)")
                    #endif
                    if needsVerification {
                        // 미인증 이메일 계정 → currentUser 설정하지 않음
                        self?.isInitializing = false
                        return
                    }
                    self?.verificationEmailSent = false
                    self?.currentUser = AppUser(uid: user.uid, email: user.email ?? "")
                    await self?.refreshOnboardingStatus(uid: user.uid)
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

        guard isValidEmail(email) else { errorMessage = L("auth.error.invalidEmail"); return }
        guard password.count >= 6 else { errorMessage = L("auth.error.shortPassword"); return }

        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            if !result.user.isEmailVerified {
                verificationEmailSent = true
                errorMessage = nil
            } else {
                verificationEmailSent = false
                currentUser = AppUser(uid: result.user.uid, email: result.user.email ?? "")
                await refreshOnboardingStatus(uid: result.user.uid)
            }
        } catch {
            errorMessage = firebaseErrorMessage(error)
        }
    }

    // MARK: - 비밀번호 재설정
    func sendPasswordReset(email: String) async -> Bool {
        guard isValidEmail(email) else { errorMessage = L("auth.error.invalidEmail"); return false }
        do {
            try await Auth.auth().sendPasswordReset(withEmail: email)
            return true
        } catch {
            errorMessage = firebaseErrorMessage(error)
            return false
        }
    }

    // MARK: - 이메일 회원가입
    @Published var verificationEmailSent = false

    func signUp(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard isValidEmail(email) else { errorMessage = L("auth.error.invalidEmail"); return }
        guard password.count >= 6 else { errorMessage = L("auth.error.shortPassword"); return }

        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            try await result.user.sendEmailVerification()
            verificationEmailSent = true
        } catch let error as NSError {
            let code = AuthErrorCode(rawValue: error.code)
            if code == .emailAlreadyInUse {
                // 미인증 계정으로 재가입 시도 → 로그인해서 인증 여부 확인
                if let result = try? await Auth.auth().signIn(withEmail: email, password: password) {
                    if !result.user.isEmailVerified {
                        try? await result.user.sendEmailVerification()
                        verificationEmailSent = true
                        errorMessage = nil
                        return
                    } else {
                        try? Auth.auth().signOut()
                        errorMessage = L("auth.error.emailInUse")
                        return
                    }
                }
                // 비밀번호가 달라 로그인 실패한 경우
                errorMessage = L("auth.error.signupInProgress")
            } else {
                errorMessage = firebaseErrorMessage(error)
            }
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
            errorMessage = L("auth.error.appleFailed")
            return
        }

        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: nonce,
            fullName: credential.fullName
        )

        do {
            let result = try await Auth.auth().signIn(with: firebaseCredential)
            verificationEmailSent = false
            currentUser = AppUser(uid: result.user.uid, email: result.user.email ?? "")
            await refreshOnboardingStatus(uid: result.user.uid)
            // Apple revoke에 필요한 authorizationCode 저장
            if let authCodeData = credential.authorizationCode,
               let authCode = String(data: authCodeData, encoding: .utf8) {
                try? await Firestore.firestore()
                    .collection("userPrivate").document(result.user.uid)
                    .setData(["appleAuthCode": authCode], merge: true)
            }
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
            errorMessage = L("auth.error.googleConfig")
            return
        }

        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: viewController)
            guard let idToken = result.user.idToken?.tokenString else {
                errorMessage = L("auth.error.googleToken")
                return
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            let authResult = try await Auth.auth().signIn(with: credential)
            verificationEmailSent = false
            currentUser = AppUser(uid: authResult.user.uid, email: authResult.user.email ?? "")
            await refreshOnboardingStatus(uid: authResult.user.uid)
        } catch {
            errorMessage = firebaseErrorMessage(error)
        }
    }

    // MARK: - 카카오 로그인
    func signInWithKakao() async {
        if let existing = kakaoSignInTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            await self.runKakaoSignIn()
        }
        kakaoSignInTask = task
        await task.value
        kakaoSignInTask = nil
    }

    private func runKakaoSignIn() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // 카카오톡 앱 설치 여부에 따라 분기
            let oauthToken: OAuthToken = try await withCheckedThrowingContinuation { cont in
                let finish: (OAuthToken?, Error?) -> Void = { token, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let token {
                        cont.resume(returning: token)
                    } else {
                        cont.resume(throwing: NSError(
                            domain: "tteona.kakao",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: L("auth.error.kakaoEmpty")]
                        ))
                    }
                }
                if UserApi.isKakaoTalkLoginAvailable() {
                    UserApi.shared.loginWithKakaoTalk { token, error in
                        finish(token, error)
                    }
                } else {
                    UserApi.shared.loginWithKakaoAccount { token, error in
                        finish(token, error)
                    }
                }
            }

            // Cloud Function — 브로커로 직렬화 + 재시도 (GTMSessionFetcher 동시 호출 방지)
            let customToken = try await fetchKakaoCustomToken(kakaoAccessToken: oauthToken.accessToken)

            // Custom Token으로 Firebase 로그인
            #if DEBUG
            print("[Kakao] signIn with customToken start")
            #endif
            let result = try await Auth.auth().signIn(withCustomToken: customToken)
            #if DEBUG
            print("[Kakao] signIn success uid=\(result.user.uid)")
            #endif
            // authStateListener가 호출 안 될 경우를 대비해 직접 설정
            verificationEmailSent = false
            currentUser = AppUser(uid: result.user.uid, email: result.user.email ?? "")
            await refreshOnboardingStatus(uid: result.user.uid)
        } catch {
            #if DEBUG
            print("[Kakao] error domain=\((error as NSError).domain) code=\((error as NSError).code) msg=\(error.localizedDescription)")
            #endif
            errorMessage = kakaoLoginFailureMessage(for: error)
        }
    }

    /// Xcode 로그의 `No network route`, TCP error 50 등 — Callable까지 못 가거나 끊긴 경우 안내
    private func kakaoLoginFailureMessage(for error: Error) -> String {
        var current: Error? = error
        for _ in 0..<6 {
            guard let e = current else { break }
            let ns = e as NSError

            if ns.domain == NSURLErrorDomain {
                switch ns.code {
                case URLError.notConnectedToInternet.rawValue,
                     URLError.networkConnectionLost.rawValue,
                     URLError.cannotConnectToHost.rawValue,
                     URLError.cannotFindHost.rawValue,
                     URLError.timedOut.rawValue,
                     URLError.dnsLookupFailed.rawValue:
                    return L("auth.error.kakaoFirebase")
                default:
                    break
                }
            }
            if ns.domain == NSPOSIXErrorDomain, ns.code == 50 {
                return L("auth.error.kakaoNoRoute")
            }

            current = ns.userInfo[NSUnderlyingErrorKey] as? Error
        }

        let desc = (error as NSError).localizedDescription
        if desc.localizedCaseInsensitiveContains("network")
            || desc.localizedCaseInsensitiveContains("internet")
            || desc.localizedCaseInsensitiveContains("route") {
            return L("auth.error.kakaoNetwork")
        }
        if desc.localizedCaseInsensitiveContains("already running") {
            return L("auth.error.kakaoOverlap")
        }
        return L("auth.error.kakaoFailed", desc)
    }

    // MARK: - 로그아웃
    func signOut() {
        ActiveSessionStore.shared.clear()
        ImpromptuSessionStore.shared.clear()
        Task { @MainActor in FootprintService.shared.clear() }
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
    }

    // MARK: - 회원탈퇴
    func deleteAccount(userId: String) async throws {
        // 1) WAS 측 개인정보(푸시 토큰·통계·아바타·Vlog 파일) 삭제 —
        //    Auth 계정이 지워지기 전, 토큰이 유효할 때 먼저 호출
        if let url = URL(string: "https://tteona.kr/api/users/me/purge") {
            let req = await APIAuth.request(url: url, method: "POST")
            _ = try? await URLSession.shared.data(for: req)
        }

        // 2) 서버(Cloud Function)에서 Firestore 데이터 + Auth 계정을 일괄 삭제
        let functions = Functions.functions(region: "us-central1")
        _ = try await functions.httpsCallable("deleteMyAccount").call()

        // 로컬 데이터 정리
        UserDefaults.standard.removeObject(forKey: "onboarding_\(userId)")
        ActiveSessionStore.shared.clear()
        ImpromptuSessionStore.shared.clear()
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: docsDir.appendingPathComponent("Tteona"))

        // 클라이언트 세션 정리 — 각 소셜 로그인 연동 완전 해제
        try? await GIDSignIn.sharedInstance.disconnect()
        await withCheckedContinuation { continuation in
            UserApi.shared.unlink { _ in continuation.resume() }
        }
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
    }

    // MARK: - Helpers
    func refreshOnboardingStatus(uid: String) async {
        // 기존 가입 유저는 Firestore users 문서가 이미 존재하므로 온보딩을 다시 하지 않도록 처리
        let doc = try? await db.collection("users").document(uid).getDocument()
        onboardingComplete = doc?.exists ?? false
    }

    private func isValidEmail(_ email: String) -> Bool {
        let regex = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return email.range(of: regex, options: .regularExpression) != nil
    }

    private func firebaseErrorMessage(_ error: Error) -> String {
        let code = AuthErrorCode(rawValue: (error as NSError).code)
        switch code {
        case .emailAlreadyInUse:    return L("auth.error.emailInUse")
        case .invalidEmail:          return L("auth.error.invalidEmail")
        case .wrongPassword:         return L("auth.error.wrongPassword")
        case .userNotFound:          return L("auth.error.userNotFound")
        case .networkError:          return L("auth.error.network")
        case .weakPassword:          return L("auth.error.shortPassword")
        default:                     return L("auth.error.generic")
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

