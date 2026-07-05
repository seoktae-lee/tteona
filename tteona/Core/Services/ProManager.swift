import Foundation
import Combine
import RevenueCat

/// tteona PRO 구독 상태 관리 — RevenueCat "pro" 엔타이틀먼트 기준.
/// 앱 시작 시 configure(), 로그인 시 logIn()으로 Firebase uid와 동기화한다.
final class ProManager: ObservableObject {
    static let shared = ProManager()

    /// RevenueCat 콘솔 → 프로젝트 → API Keys의 Apple 공개 SDK 키(appl_...)로 교체할 것
    private static let apiKey = "appl_REPLACE_WITH_REVENUECAT_KEY"
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
        guard !Self.apiKey.contains("REPLACE") else {
            print("[Pro] RevenueCat API 키 미설정 — 무료 모드로 동작")
            return
        }
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: Self.apiKey, appUserID: userId)
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
