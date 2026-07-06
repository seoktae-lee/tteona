import Foundation
import Combine
import RevenueCat

/// tteona PRO 구독 상태 관리 — RevenueCat "pro" 엔타이틀먼트 기준.
/// 앱 시작 시 configure(), 로그인 시 logIn()으로 Firebase uid와 동기화한다.
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

    /// 한 장소(클립)당 최대 촬영 길이 (초) — 무료 5초, PRO는 제한 없음(총 예산 내)
    var vlogClipMaxSeconds: Double? { isPro ? nil : 5 }

    private var isConfigured: Bool { Purchases.isConfigured }

    private init() {}

    func configure(userId: String?) {
        let key = Self.apiKey
        guard !key.isEmpty, key.hasPrefix("appl_") else {
            print("[Pro] RevenueCat API 키 미설정 — 무료 모드로 동작 (Info.plist REVENUECAT_API_KEY 확인)")
            return
        }
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: key, appUserID: userId)
        Task {
            await refresh()
            await loadOfferings()
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
