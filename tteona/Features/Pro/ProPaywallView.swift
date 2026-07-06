import SwiftUI
import RevenueCat

/// tteona PRO 구독 페이월 — RevenueCat offerings의 연간/월간 패키지 표시
struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pro = ProManager.shared

    @State private var selectedPackage: Package?
    @State private var isPurchasing = false
    @State private var alertMessage: String?

    private var packages: [Package] {
        pro.offerings?.current?.availablePackages ?? []
    }
    private var annual: Package? { packages.first { $0.packageType == .annual } }
    private var monthly: Package? { packages.first { $0.packageType == .monthly } }

    var body: some View {
        ZStack {
            VlogAuroraBackground()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.tte(15, .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        VStack(spacing: 14) {
                            Image("tteona-pro-logo")
                                .resizable()
                                .renderingMode(.original)
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 34)
                            Text(L("paywall.tagline"))
                                .font(.tte(14))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding(.top, 12)

                        VStack(alignment: .leading, spacing: 14) {
                            featureRow(icon: "sparkles.rectangle.stack", title: L("paywall.feature.watermark"),
                                       subtitle: L("paywall.feature.watermark.sub"))
                            featureRow(icon: "rectangle.3.group", title: L("paywall.feature.multiformat"),
                                       subtitle: L("paywall.feature.multiformat.sub"))
                            featureRow(icon: "music.note.list", title: L("paywall.feature.bgm"),
                                       subtitle: L("paywall.feature.bgm.sub"))
                            featureRow(icon: "timer", title: L("paywall.feature.duration"),
                                       subtitle: L("paywall.feature.duration.sub"))
                            featureRow(icon: "bolt.fill", title: L("paywall.feature.priority"),
                                       subtitle: L("paywall.feature.priority.sub"))
                        }
                        .padding(20)
                        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.07)))
                        .padding(.horizontal, 24)

                        if packages.isEmpty {
                            VStack(spacing: 10) {
                                Text(L("paywall.loadFailed"))
                                    .font(.tte(14))
                                    .foregroundColor(.white.opacity(0.7))
                                Button(L("paywall.retry")) {
                                    Task { await pro.loadOfferings() }
                                }
                                .font(.tte(14, .semibold))
                                .foregroundColor(.tteOrange)
                            }
                            .padding(.vertical, 12)
                        } else {
                            VStack(spacing: 10) {
                                if let annual { packageCard(annual, isBest: true) }
                                if let monthly { packageCard(monthly, isBest: false) }
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                    .padding(.bottom, 12)
                }

                VStack(spacing: 12) {
                    Button {
                        Task { await purchase() }
                    } label: {
                        ZStack {
                            if isPurchasing {
                                ProgressView().tint(.white)
                            } else {
                                Text(ctaTitle)
                                    .font(.tte(17, .bold))
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                    }
                    .disabled(isPurchasing || selectedPackage == nil)
                    .padding(.horizontal, 24)

                    HStack(spacing: 16) {
                        Button(L("paywall.restore")) { Task { await restore() } }
                        Link(L("settings.terms"), destination: URL(string: "https://tteona.kr/terms")!)
                        Link(L("paywall.privacyPolicy"), destination: URL(string: "https://tteona.kr/privacy")!)
                    }
                    .font(.tte(12))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear {
            if selectedPackage == nil { selectedPackage = annual ?? packages.first }
            Task { await pro.loadOfferings() }
        }
        .onChange(of: packages.count) { _, _ in
            if selectedPackage == nil { selectedPackage = annual ?? packages.first }
        }
        .onChange(of: pro.isPro) { _, active in
            if active { dismiss() }
        }
        .alert(L("common.notice"), isPresented: Binding(get: { alertMessage != nil },
                                          set: { if !$0 { alertMessage = nil } })) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var ctaTitle: String {
        guard let pkg = selectedPackage else { return L("paywall.subscribe") }
        if pkg.storeProduct.introductoryDiscount?.price == 0 {
            return L("paywall.startFreeTrial")
        }
        return L("paywall.subscribe")
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.tte(18))
                .foregroundColor(.tteOrange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.tte(15, .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.tte(12))
                    .foregroundColor(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
    }

    private func packageCard(_ pkg: Package, isBest: Bool) -> some View {
        let isOn = selectedPackage?.identifier == pkg.identifier
        let product = pkg.storeProduct
        return Button {
            selectedPackage = pkg
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(pkg.packageType == .annual ? L("paywall.annual") : L("paywall.monthly"))
                            .font(.tte(16, .bold))
                            .foregroundColor(.white)
                        if let badge = savingsBadge(pkg) {
                            Text(badge)
                                .font(.tte(11, .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.tteOrange))
                        }
                        if product.introductoryDiscount?.price == 0 {
                            Text(L("paywall.freeTrial7"))
                                .font(.tte(11, .bold))
                                .foregroundColor(.tteOrange)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.tteOrange.opacity(0.18)))
                        }
                    }
                    Text(subtitleText(pkg))
                        .font(.tte(12))
                        .foregroundColor(.white.opacity(0.55))
                }
                Spacer()
                Text(product.localizedPriceString)
                    .font(.tte(17, .bold))
                    .foregroundColor(.white)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(isOn ? 0.13 : 0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isOn ? Color.tteOrange : Color.clear, lineWidth: 1.5)
            )
        }
    }

    /// 연간 패키지의 월간 대비 절약률 배지 (월간 패키지가 함께 있을 때만)
    private func savingsBadge(_ pkg: Package) -> String? {
        guard pkg.packageType == .annual,
              let monthlyPrice = monthly?.storeProduct.price, monthlyPrice > 0 else { return nil }
        let yearAtMonthly = monthlyPrice * 12
        let saving = (yearAtMonthly - pkg.storeProduct.price) / yearAtMonthly * 100
        let pct = NSDecimalNumber(decimal: saving).intValue
        return pct > 0 ? L("paywall.discount", pct) : nil
    }

    private func subtitleText(_ pkg: Package) -> String {
        if pkg.packageType == .annual {
            let perMonth = pkg.storeProduct.price / 12
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.locale = pkg.storeProduct.priceFormatter?.locale ?? .current
            if let s = f.string(from: NSDecimalNumber(decimal: perMonth)) {
                return L("paywall.perMonthAnnual", s)
            }
            return L("paywall.billedAnnually")
        }
        return L("paywall.cancelAnytime")
    }

    private func purchase() async {
        guard let pkg = selectedPackage else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let active = try await pro.purchase(pkg)
            if !active { return }   // 유저가 결제 시트를 닫음
            Haptics.success()
        } catch {
            alertMessage = L("paywall.purchaseFailed")
        }
    }

    private func restore() async {
        do {
            let active = try await pro.restore()
            alertMessage = active ? L("paywall.restored") : L("paywall.nothingToRestore")
        } catch {
            alertMessage = L("paywall.restoreFailed")
        }
    }
}
