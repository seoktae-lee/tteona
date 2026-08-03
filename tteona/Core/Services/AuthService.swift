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
        dlog("[Kakao] 응답 파싱 실패: \(rawBody)")
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

    /// 익명(게스트)으로 앱을 쓰는 중 — 서버에 쓸 신원은 있지만 계정은 없다
    @Published private(set) var isGuest = false

    /// **로컬 저장 경로에 쓰는 신원 uid.** 화면 게이팅과는 다른 질문에 답한다.
    ///
    /// `isLoggedIn`은 "진짜 계정인가"를 묻고, 이 값은 "지금 이 기기에서 찍고 있는 사람이
    /// 누구인가"를 묻는다. 둘을 하나로 쓰면 과도기에 저장 경로가 통째로 바뀐다 —
    /// 이메일 가입 직후 인증 대기 상태에서 `currentUser`를 비우자 세션 경로가
    /// `free_{uid}`에서 `free_`로 미끄러졌고, 무결성 검사가 "파일이 없다"며
    /// 그날 기록을 지워버렸다. 익명이든 인증 대기든 Firebase 유저가 있으면 유지한다.
    @Published private(set) var identityUid: String = ""

    /// **진짜 계정**으로 로그인했는가. 익명은 false.
    ///
    /// 익명 인증을 켜면 `Auth.auth().currentUser`가 항상 채워져, 예전 정의(`!= nil`)는
    /// 언제나 true가 된다 — 탭 게이팅도 결제 게이트도 통째로 열린다. 아무것도 안 깨지고
    /// 조용히 열리기 때문에 특히 위험하다.
    /// 이름을 그대로 두고 정의만 좁혀, 이 값을 보고 있던 곳들이 자동으로 옳게 동작하게 한다.
    var isLoggedIn: Bool { currentUser != nil && !isGuest }

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
                // 저장 경로용 신원은 게이팅과 별개로 유지한다 (익명·인증 대기 포함)
                self?.identityUid = user?.uid ?? ""
                if let user {
                    // 게스트 — Firestore는 규칙상 익명을 막으므로 조회를 시도조차 하지 않는다.
                    // uid는 채워 둔다: 세션 폴더·서버 브이로그가 이걸 신원으로 쓴다.
                    if user.isAnonymous {
                        self?.isGuest = true
                        self?.currentUser = AppUser(uid: user.uid, email: "")
                        self?.onboardingComplete = false
                        self?.isInitializing = false
                        return
                    }
                    self?.isGuest = false
                    let providerIDs = user.providerData.map { $0.providerID }
                    // 순수 이메일/비밀번호 계정만 이메일 인증 필요.
                    // 카카오(커스텀 토큰)는 providerData가 비어있어 allSatisfy가 true를 반환하는 함정을
                    // 피하기 위해 password provider가 실제로 존재하는지 먼저 확인한다.
                    let isEmailPassword = providerIDs.contains("password")
                        && providerIDs.allSatisfy { $0 == "password" }
                    let needsVerification = isEmailPassword && !user.isEmailVerified
                    #if DEBUG
                    dlog("[Auth] uid=\(user.uid) isEmailVerified=\(user.isEmailVerified) needsVerification=\(needsVerification) verificationEmailSent=\(self?.verificationEmailSent ?? false)")
                    #endif
                    if needsVerification {
                        // 미인증 이메일 계정 → currentUser 설정하지 않음.
                        // 익명 계정을 승격시킨 직후라면 currentUser에 게스트 신원이 남아 있다.
                        // 그대로 두면 isGuest=false + currentUser≠nil이 되어 인증도 안 한 계정이
                        // 로그인으로 잡힌다 — 명시적으로 비운다. (uid는 link로 보존되므로
                        // 인증을 마치면 같은 uid로 돌아온다)
                        self?.currentUser = nil
                        self?.isInitializing = false
                        return
                    }
                    self?.verificationEmailSent = false
                    self?.currentUser = AppUser(uid: user.uid, email: user.email ?? "")
                    await self?.refreshOnboardingStatus(uid: user.uid)
                } else {
                    self?.currentUser = nil
                    self?.isGuest = false
                    self?.onboardingComplete = false
                    // 로그인 상태가 없으면 게스트 신원을 만든다.
                    //
                    // 여기서 isInitializing을 내리면 uid가 빈 채로 화면이 잠깐 뜨고,
                    // 그 사이 세션 폴더가 `free_`로 잡혔다가 익명 uid를 받으면 `free_{uid}`로
                    // 바뀐다 — 그 순간 찍어둔 클립이 어긋난다. 신원이 정해질 때까지 기다린다.
                    if Auth.auth().currentUser == nil, self?.wantsGuestIdentity == true {
                        await self?.signInAnonymously()
                        return   // 성공하면 리스너가 다시 불려 위 게스트 분기로 이어진다
                    }
                }
                self?.isInitializing = false
            }
        }
    }

    /// 자격증명으로 계정에 들어간다. **게스트라면 갈아타지 않고 승격시킨다.**
    ///
    /// `signIn`은 "이 사람으로 갈아타라"는 명령이라 현재 익명 세션을 통째로 버린다.
    /// 그러면 uid가 바뀌면서 게스트가 찍어둔 클립(`Sessions/free_{uid}`)과 브이로그 쿼터가
    /// 함께 사라진다. `link`는 같은 uid에 로그인 수단만 붙이므로 전부 그대로 이어진다.
    ///
    /// 이미 그 자격증명을 쓰는 계정이 있으면 link는 실패한다. 그때는 기존 계정으로 들어가야
    /// 하므로 `signIn`으로 물러나고, 익명 계정은 버려진다 — 그 경우의 데이터 승계는
    /// 세션 이관이 따로 받는다. (카카오는 커스텀 토큰이라 애초에 이 경로를 못 탄다)
    private func signInOrLink(with credential: AuthCredential) async throws -> AuthDataResult {
        guard let user = Auth.auth().currentUser, user.isAnonymous else {
            return try await Auth.auth().signIn(with: credential)
        }
        do {
            let result = try await user.link(with: credential)
            // link는 uid를 바꾸지 않아 **상태 리스너가 불리지 않는다**
            // (리스너는 로그인/로그아웃·uid 변경에만 반응한다).
            // 직접 내려주지 않으면 승격했는데도 isGuest가 true로 남아, 인증을 마쳐도
            // 앱이 계속 게스트로 취급한다 — 화면이 안 넘어가던 원인이었다.
            isGuest = false
            identityUid = result.user.uid
            return result
        } catch let error as NSError {
            let code = AuthErrorCode(rawValue: error.code)
            guard code == .credentialAlreadyInUse || code == .emailAlreadyInUse
                    || code == .providerAlreadyLinked else { throw error }
            // 이미 쓰이는 자격증명 — Firebase가 로그인에 쓸 최신 credential을 실어 준다
            let fallback = error.userInfo[AuthErrorUserInfoUpdatedCredentialKey] as? AuthCredential
            dlog("[Auth] 익명 승격 불가 — 기존 계정으로 로그인")
            let guestUid = user.uid
            let result = try await Auth.auth().signIn(with: fallback ?? credential)
            // uid가 바뀌었다 — 게스트로 찍어둔 영상을 새 계정 폴더로 옮겨 준다
            migrateGuestSession(from: guestUid, to: result.user.uid)
            return result
        }
    }

    /// 게스트로 찍어둔 클립을 새 계정 폴더로 옮긴다.
    ///
    /// 카카오(커스텀 토큰)와 '이미 있는 계정으로 로그인'은 link가 불가능해 uid가 바뀐다.
    /// 그러면 `Sessions/free_{옛uid}`에 남은 영상을 앱이 영영 못 찾는다 — 장소 목록은
    /// UserDefaults라 살아남는데 파일만 사라져, "3곳인데 영상 없음" 상태가 된다.
    ///
    /// 통째로 옮기지 않고 **파일 단위로** 옮기는 이유: 대상 계정에 이미 오늘 기록이 있으면
    /// 폴더째 덮어써서 그쪽 영상을 지우게 된다. 같은 이름은 손대지 않고 건너뛴다.
    private func migrateGuestSession(from oldUid: String, to newUid: String) {
        guard !oldUid.isEmpty, !newUid.isEmpty, oldUid != newUid else { return }
        let fm = FileManager.default
        let root = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tteona/Sessions")
        let src = root.appendingPathComponent("free_\(oldUid)")
        let dst = root.appendingPathComponent("free_\(newUid)")
        guard fm.fileExists(atPath: src.path) else { return }

        if !fm.fileExists(atPath: dst.path) {
            try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        }
        var movedAll = true
        for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] {
            let from = src.appendingPathComponent(name)
            let to = dst.appendingPathComponent(name)
            if fm.fileExists(atPath: to.path) { continue }
            do { try fm.moveItem(at: from, to: to) } catch { movedAll = false }
        }
        // 전부 옮긴 뒤에만 원본을 지운다 — 옮기다 실패했는데 원본까지 지우면 영상이 사라진다
        if movedAll { try? fm.removeItem(at: src) }
        dlog("[Guest] 세션 이관 \(oldUid) → \(newUid) (원본정리=\(movedAll))")
    }

    /// 게스트 신원을 새로 만들어도 되는 시점인지. 앱 시작과 명시적 로그아웃에서만 켠다.
    ///
    /// 리스너가 nil을 볼 때마다 무조건 만들면, 화면 안에서 상태를 정리하려고 부른 signOut까지
    /// 새 게스트 계정을 낳는다. 그러면 uid가 바뀌며 찍어둔 클립이 끊기고, 사용자는 가입도
    /// 로그인도 아닌 상태로 튕긴다 — 실제로 그렇게 됐다.
    private var wantsGuestIdentity = true

    /// 게스트 신원 발급. 화면도 팝업도 없다 — 사용자는 이런 게 있는지 모른다.
    private func signInAnonymously() async {
        do {
            try await Auth.auth().signInAnonymously()
        } catch {
            // 오프라인 첫 실행 등. 신원이 없어도 촬영·로컬 합성은 되어야 하므로
            // 여기서 막으면 스플래시에 갇힌다 — 신원 없이 진행시킨다.
            dlog("[Auth] 익명 로그인 실패(신원 없이 진행): \(error.localizedDescription)")
            isInitializing = false
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
            // 게스트가 가입하는 중이면 새 계정을 만들지 않고 익명 계정에 이메일을 붙인다
            let result: AuthDataResult
            if let user = Auth.auth().currentUser, user.isAnonymous {
                result = try await user.link(
                    with: EmailAuthProvider.credential(withEmail: email, password: password))
                // 위와 같은 이유로 리스너가 불리지 않는다. 게스트 상태를 내리되,
                // 이메일은 인증 전까지 로그인으로 치지 않으므로 currentUser는 비워 둔다.
                isGuest = false
                identityUid = result.user.uid
                currentUser = nil
            } else {
                result = try await Auth.auth().createUser(withEmail: email, password: password)
            }
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
                        // 로그인은 이미 성공했다. 예전엔 여기서 로그아웃하고 "이미 쓰는 이메일"이라
                        // 안내했는데, 익명 인증이 켜진 지금은 그 로그아웃이 새 게스트 계정을 낳아
                        // 가입도 로그인도 아닌 상태로 튕긴다. 원하던 계정에 들어온 것이니 그대로 둔다.
                        verificationEmailSent = false
                        currentUser = AppUser(uid: result.user.uid, email: result.user.email ?? "")
                        await refreshOnboardingStatus(uid: result.user.uid)
                        errorMessage = nil
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
            let result = try await signInOrLink(with: firebaseCredential)
            verificationEmailSent = false
            currentUser = AppUser(uid: result.user.uid, email: result.user.email ?? "")
            await refreshOnboardingStatus(uid: result.user.uid)
            // Apple revoke 대비: authorizationCode를 서버에서 refresh token으로 교환해 둔다.
            // authorizationCode는 발급 후 약 5분 만료·1회용이라, 로그인 직후(지금) 교환하지 않으면
            // 탈퇴 시점엔 죽어 있어 revoke가 실패한다. 교환 결과(refresh token)는 함수가 저장한다.
            if let authCodeData = credential.authorizationCode,
               let authCode = String(data: authCodeData, encoding: .utf8) {
                let functions = Functions.functions(region: "us-central1")
                _ = try? await functions.httpsCallable("exchangeAppleAuthCode")
                    .call(["authorizationCode": authCode])
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
            let authResult = try await signInOrLink(with: credential)
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
            dlog("[Kakao] signIn with customToken start")
            #endif
            // 카카오는 uid가 kakao_{id}로 고정된 커스텀 토큰이라 link 자체가 불가능하다.
            // 익명 계정은 버려지므로, 그 전에 찍어둔 영상을 옮길 수 있게 uid를 붙잡아 둔다.
            let guestUid = (Auth.auth().currentUser?.isAnonymous == true)
                ? Auth.auth().currentUser?.uid : nil
            let result = try await Auth.auth().signIn(withCustomToken: customToken)
            #if DEBUG
            dlog("[Kakao] signIn success uid=\(result.user.uid)")
            #endif
            if let guestUid { migrateGuestSession(from: guestUid, to: result.user.uid) }
            // authStateListener가 호출 안 될 경우를 대비해 직접 설정
            verificationEmailSent = false
            isGuest = false
            identityUid = result.user.uid
            currentUser = AppUser(uid: result.user.uid, email: result.user.email ?? "")
            await refreshOnboardingStatus(uid: result.user.uid)
        } catch {
            #if DEBUG
            dlog("[Kakao] error domain=\((error as NSError).domain) code=\((error as NSError).code) msg=\(error.localizedDescription)")
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
    func signOut() async {
        // 기기 토큰 해제가 먼저다 — Firebase 세션이 끊기면 WAS 인증을 통과하지 못하고,
        // 토큰이 남으면 이 기기에 로그인하는 다음 계정에게 내 알림이 배달된다.
        await PushService.shared.unregisterDeviceToken()

        wantsGuestIdentity = true   // 명시적 로그아웃 — 게스트로 돌아간다
        ActiveSessionStore.shared.clear()
        ImpromptuSessionStore.shared.clear()
        Task { @MainActor in FootprintService.shared.clear() }
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
    }

    // MARK: - 회원탈퇴
    func deleteAccount(userId: String) async throws {
        // 탈퇴가 끝날 때까지는 게스트 신원을 자동으로 만들지 않는다.
        //
        // 서버가 Auth 계정을 지우는 순간 로그아웃이 한 번 감지되고, 아래 signOut()에서 또
        // 한 번 감지된다. 그때마다 익명 계정이 새로 발급돼 **탈퇴 한 번에 두 개**가 생겼다.
        // 정리가 다 끝난 뒤 아래에서 딱 하나만 만든다.
        wantsGuestIdentity = false
        defer { wantsGuestIdentity = true }

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

        // 정리가 끝났다 — 게스트로 돌아간다.
        // 플래그를 먼저 되돌리면, signOut으로 대기 중이던 리스너 콜백이 그 값을 보고
        // 하나를 더 만든다(같은 초에 두 개가 생겼다). 플래그는 defer에 맡기고
        // 여기서는 직접 하나만 발급한다.
        await signInAnonymously()
    }

    // MARK: - Helpers
    func refreshOnboardingStatus(uid: String) async {
        // 기존 가입 유저는 Firestore users 문서가 이미 존재하므로 온보딩을 다시 하지 않도록 처리.
        // ⚠️ 네트워크 오류로 조회가 실패했을 때 onboardingComplete=false로 떨어뜨리면,
        //    기존 유저가 온보딩 화면으로 밀려나고 거기서 저장 시 프로필이 덮어써질 위험이 있다.
        //    따라서 "문서 없음"(정상 조회 후 exists=false)과 "조회 실패"(throw)를 반드시 구분한다.
        do {
            let doc = try await db.collection("users").document(uid).getDocument()
            onboardingComplete = doc.exists
        } catch {
            // 조회 실패 — 문서 존재 여부를 확신할 수 없으므로 상태를 함부로 바꾸지 않는다.
            // (기존 유저를 온보딩으로 되돌리지 않는다. 실제 신규 유저면 users 문서가 없어
            //  이후 온라인 복구 시 재조회로 자연히 온보딩이 이어진다.)
            #if DEBUG
            dlog("[Auth] refreshOnboardingStatus 조회 실패 — 상태 유지: \(error.localizedDescription)")
            #endif
        }
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
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
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

