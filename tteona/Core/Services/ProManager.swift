import Foundation
import Combine
import RevenueCat

/// tteona PRO 구독 상태 관리 — RevenueCat "pro" 엔타이틀먼트 기준.
/// 앱 시작 시 configure(), 로그인 시 logIn()으로 Firebase uid와 동기화한다.
@MainActor
final class ProManager: ObservableObject {
    static let shared = ProManager()

    /// RevenueCat Apple 공개 SDK 키(appl_...) — Info.plist의 REVENUECAT_API_KEY에 설정.
    /// 미설정(빈 값)이면 무료 모드로 동작하고 결제 UI는 잠긴다.
    private static var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "REVENUECAT_API_KEY") as? String ?? ""
    }
    static let entitlementId = "pro"

    @Published private(set) var isPro = false
    @Published private(set) var offerings: Offerings?

    /// 브이로그 촬영 총 길이 예산 (초) — 무료 30초, PRO 5분
    var vlogBudgetSeconds: Double { isPro ? 300 : 30 }

    /// 유저가 고른 한 장소당 촬영 길이. PRO 전용을 고른 채 구독이 끝나면 무료 기본값으로 되돌린다.
    @Published var clipLength: VlogClipLength = {
        let raw = UserDefaults.standard.string(forKey: "vlog.clipLength") ?? ""
        return VlogClipLength(rawValue: raw) ?? .freeDefault
    }() {
        didSet { UserDefaults.standard.set(clipLength.rawValue, forKey: "vlog.clipLength") }
    }

    /// 실제로 적용되는 길이 — 권한 없는 선택은 무료 기본값으로 강등한다
    var effectiveClipLength: VlogClipLength {
        (clipLength.requiresPro && !isPro) ? .freeDefault : clipLength
    }

    /// 이 길이를 지금 쓸 수 있는가 (칩 잠금 표시용)
    func canUse(_ length: VlogClipLength) -> Bool { isPro || !length.requiresPro }

    /// 한 장소(클립)당 최대 촬영 길이 (초). nil = 수동 종료(무제한, PRO)
    var vlogClipMaxSeconds: Double? { effectiveClipLength.seconds }

    /// 세션 예산을 클립 단위로 나눈 칸 수 — 무료는 6칸(30÷5) 분절 링,
    /// PRO는 클립 제한이 없어 분절이 의미 없으므로 nil(연속 링)을 반환한다.
    var vlogSegmentCount: Int? {
        guard let clip = vlogClipMaxSeconds, clip > 0 else { return nil }
        return Int((vlogBudgetSeconds / clip).rounded())
    }

    private var isConfigured: Bool { Purchases.isConfigured }
    private var streamTask: Task<Void, Never>?

    private init() {}

    func configure(userId: String?) {
        let key = Self.apiKey
        guard !key.isEmpty, key.hasPrefix("appl_") else {
            dlog("[Pro] RevenueCat API 키 미설정 — 무료 모드로 동작 (Info.plist REVENUECAT_API_KEY 확인)")
            return
        }
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: key, appUserID: userId)
        observeCustomerInfo()
        Task {
            await refresh()
            await loadOfferings()
        }
    }

    /// RevenueCat이 구독 상태 변화(구매·만료·갱신·복원)를 밀어줄 때마다 isPro를 갱신한다.
    /// 이게 없으면 앱을 재시작하기 전까지 만료/갱신이 반영되지 않는다.
    private func observeCustomerInfo() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                self?.apply(info)   // @MainActor 클래스라 메인에서 안전하게 반영
            }
        }
    }

    func logIn(userId: String) {
        guard isConfigured else { return }
        Task {
            if let (info, _) = try? await Purchases.shared.logIn(userId) { apply(info) }
        }
    }

    func logOut() {
        guard isConfigured else { return }
        Task {
            if let info = try? await Purchases.shared.logOut() { apply(info) }
        }
    }

    func refresh() async {
        guard isConfigured else { return }
        apply(try? await Purchases.shared.customerInfo())
    }

    func loadOfferings() async {
        guard isConfigured else { return }
        offerings = try? await Purchases.shared.offerings()
    }

    /// 반환값: 구매 후 PRO 활성 여부 (유저가 결제 시트를 닫으면 false)
    @discardableResult
    func purchase(_ package: Package) async throws -> Bool {
        guard isConfigured else { return false }
        let result = try await Purchases.shared.purchase(package: package)
        apply(result.customerInfo)
        return isPro
    }

    @discardableResult
    func restore() async throws -> Bool {
        guard isConfigured else { return false }
        apply(try await Purchases.shared.restorePurchases())
        return isPro
    }

    private func apply(_ info: CustomerInfo?) {
        isPro = info?.entitlements[Self.entitlementId]?.isActive == true
    }
}
