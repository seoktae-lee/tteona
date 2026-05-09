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

    // MARK: - 비밀번호 재설정
    func sendPasswordReset(email: String) async -> Bool {
        guard isValidEmail(email) else { errorMessage = "올바른 이메일 형식이 아닙니다."; return false }
        do {
            try await Auth.auth().sendPasswordReset(withEmail: email)
            return true
        } catch {
            errorMessage = firebaseErrorMessage(error)
            return false
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

            // Cloud Function으로 Custom Token 발급
            let functions = Functions.functions(region: "us-central1")
            let result = try await functions.httpsCallable("createKakaoCustomToken")
                .call(["kakaoAccessToken": oauthToken.accessToken])

            guard let data = result.data as? [String: Any],
                  let customToken = data["customToken"] as? String else {
                errorMessage = "카카오 로그인에 실패했습니다."
                return
            }

            // Custom Token으로 Firebase 로그인
            try await Auth.auth().signIn(withCustomToken: customToken)
        } catch {
            print("[Kakao] error: \(error)")
            errorMessage = "카카오 로그인에 실패했습니다. (\(error.localizedDescription))"
        }
    }

    // MARK: - 로그아웃
    func signOut() {
        ActiveSessionStore.shared.clear()
        ImpromptuSessionStore.shared.clear()
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
    }

    // MARK: - 회원탈퇴
    func deleteAccount(userId: String) async throws {
        let db = Firestore.firestore()

        // 1. 내가 만든 코스 삭제
        let coursesSnapshot = try await db.collection("courses")
            .whereField("authorId", isEqualTo: userId)
            .getDocuments()
        for doc in coursesSnapshot.documents {
            try await doc.reference.delete()
        }

        // 2. 내가 속한 방에서 제거 + 내가 작성한 피드 삭제
        let roomsSnapshot = try await db.collection("rooms")
            .whereField("memberIds", arrayContains: userId)
            .getDocuments()
        for doc in roomsSnapshot.documents {
            let roomId = doc.documentID
            try await db.collection("rooms").document(roomId)
                .updateData(["memberIds": FieldValue.arrayRemove([userId])])
            try await db.collection("rooms").document(roomId)
                .collection("members").document(userId).delete()
            try await db.collection("rooms").document(roomId)
                .collection("locations").document(userId).delete()
            let feedSnapshot = try? await db.collection("rooms").document(roomId)
                .collection("feed")
                .whereField("userId", isEqualTo: userId)
                .getDocuments()
            for feedDoc in feedSnapshot?.documents ?? [] {
                try? await feedDoc.reference.delete()
            }
        }

        // 3. users 문서 삭제 (likedCourseIds, fcmToken 등 포함)
        try await db.collection("users").document(userId).delete()
        // 3-1. 민감정보 문서 삭제 (FCM 토큰 등)
        try? await db.collection("userPrivate").document(userId).delete()

        // 4. 기기 로컬 데이터 정리
        UserDefaults.standard.removeObject(forKey: "onboarding_\(userId)")
        ActiveSessionStore.shared.clear()
        ImpromptuSessionStore.shared.clear()
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: docsDir.appendingPathComponent("Tteona"))

        // 5. Firebase Auth 계정 삭제
        try await Auth.auth().currentUser?.delete()
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

