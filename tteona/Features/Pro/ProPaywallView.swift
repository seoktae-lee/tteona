import SwiftUI
import RevenueCat

/// tteona PRO 구독 페이월 — RevenueCat offerings의 연간/월간 패키지 표시.
/// 연간 플랜을 기본 선택 + 할인율·월환산가·정가 비교로 강조하고,
/// 등장 스태거·선택 스프링·CTA 슈머 등 가벼운 인터랙션으로 결제 전환을 돕는다.
struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pro = ProManager.shared

    @State private var selectedPackage: Package?
    /// 결제는 계정에 묶여야 한다. 게스트로 사면 기기를 바꾸거나 앱을 지웠을 때
    /// 복원할 방법이 없어 "돈은 냈는데 사라졌다"가 된다 — 구매 직전에 가입을 받는다.
    @EnvironmentObject private var authService: AuthService
    @State private var showAuthForPurchase = false
    @State private var isPurchasing = false
    @State private var alertMessage: String?
    @State private var appeared = false        // 등장 스태거 트리거
    @State private var shimmer = false         // CTA 하이라이트 스윕
    @State private var badgePulse = false      // 할인 배지 맥동

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
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)

                        VStack(alignment: .leading, spacing: 14) {
                            let features: [(String, String, String)] = [
                                ("sparkles.rectangle.stack", L("paywall.feature.watermark"), L("paywall.feature.watermark.sub")),
                                ("rectangle.3.group", L("paywall.feature.multiformat"), L("paywall.feature.multiformat.sub")),
                                ("music.note.list", L("paywall.feature.bgm"), L("paywall.feature.bgm.sub")),
                                ("timer", L("paywall.feature.duration"), L("paywall.feature.duration.sub")),
                                ("bolt.fill", L("paywall.feature.priority"), L("paywall.feature.priority.sub")),
                            ]
                            ForEach(Array(features.enumerated()), id: \.offset) { index, f in
                                featureRow(icon: f.0, title: f.1, subtitle: f.2)
                                    .opacity(appeared ? 1 : 0)
                                    .offset(x: appeared ? 0 : 18)
                                    .animation(.spring(response: 0.5, dampingFraction: 0.85)
                                        .delay(0.12 + Double(index) * 0.07), value: appeared)
                            }
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
                            VStack(spacing: 14) {
                                if let annual { annualCard(annual) }
                                if let monthly { monthlyCard(monthly) }
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 4)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 16)
                            .animation(.spring(response: 0.55, dampingFraction: 0.85).delay(0.4), value: appeared)
                        }
                    }
                    .padding(.bottom, 24)
                }

                VStack(spacing: 10) {
                    ctaButton
                        .padding(.horizontal, 24)

                    // 결제 심리 안전판 — 체험이면 '지금 결제 안 됨'을 명시해 진입 장벽을 낮춘다
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.tte(11, .bold))
                        Text(hasFreeTrial
                             ? "\(L("paywall.noPaymentNow")) · \(L("paywall.cancelAnytime"))"
                             : L("paywall.cancelAnytime"))
                            .font(.tte(12, .medium))
                    }
                    .foregroundColor(.white.opacity(0.75))

                    // 자동 갱신 조건 고지 — 심사 지침 3.1.2가 인앱 표시를 요구한다
                    Text(L("paywall.autoRenewNotice"))
                        .font(.tte(11))
                        .foregroundColor(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)

                    HStack(spacing: 16) {
                        Button(L("paywall.restore")) { Task { await restore() } }
                        // EULA는 App Store Connect에 Apple 표준으로 선언돼 있다. 자체 약관(tteona.kr/terms)엔
                        // 구독 조항이 없어 EULA 역할을 못 하므로, 여기서는 선언된 원문을 그대로 링크한다.
                        Link(L("paywall.eula"),
                             destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        Link(L("paywall.privacyPolicy"), destination: URL(string: "https://tteona.kr/privacy.html")!)
                    }
                    .font(.tte(12))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear {
            if selectedPackage == nil { selectedPackage = annual ?? packages.first }
            Task { await pro.loadOfferings() }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { shimmer = true }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { badgePulse = true }
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

    private var hasFreeTrial: Bool {
        selectedPackage?.storeProduct.introductoryDiscount?.price == 0
    }

    private var ctaTitle: String {
        guard selectedPackage != nil else { return L("paywall.subscribe") }
        return hasFreeTrial ? L("paywall.startFreeTrial") : L("paywall.subscribe")
    }

    // MARK: - CTA (슈머 스윕 하이라이트)
    private var ctaButton: some View {
        Button {
            guard authService.isLoggedIn else {
                Haptics.light()
                showAuthForPurchase = true
                return
            }
            Task { await purchase() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(colors: [Color.tteOrange, Color.tteOrange.opacity(0.85)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .shadow(color: Color.tteOrange.opacity(0.45), radius: 14, y: 4)

                // 좌→우로 흐르는 밝은 띠 — 버튼에 시선을 잡아둔다
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.35), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.45)
                        .offset(x: shimmer ? geo.size.width * 1.2 : -geo.size.width * 0.6)
                        .blendMode(.plusLighter)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .allowsHitTesting(false)

                if isPurchasing {
                    ProgressView().tint(.white)
                } else {
                    Text(ctaTitle)
                        .font(.tte(17, .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 56)
        }
        .disabled(isPurchasing || selectedPackage == nil)
        .fullScreenCover(isPresented: $showAuthForPurchase) { AuthView(isDismissable: true) }
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

    // MARK: - 연간 카드 (기본 선택 · 할인 강조)
    private func annualCard(_ pkg: Package) -> some View {
        let isOn = selectedPackage?.identifier == pkg.identifier
        let product = pkg.storeProduct
        return Button {
            select(pkg)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    selectionCircle(isOn)
                    Text(L("paywall.annual"))
                        .font(.tte(17, .bold))
                        .foregroundColor(.white)
                    if product.introductoryDiscount?.price == 0 {
                        Text(L("paywall.freeTrial7"))
                            .font(.tte(11, .bold))
                            .foregroundColor(.tteOrange)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.tteOrange.opacity(0.18)))
                    }
                    Spacer()
                    if let pct = savingsPercent {
                        Text(L("paywall.discount", pct))
                            .font(.tte(12, .heavy))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.tteOrange))
                            .scaleEffect(badgePulse ? 1.06 : 1.0)
                            .shadow(color: Color.tteOrange.opacity(badgePulse ? 0.55 : 0.2), radius: 8)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // 월간×12 정가 취소선 — 절약분을 한눈에
                    if let compareAt = compareAtPriceString {
                        Text(compareAt)
                            .font(.tte(14, .medium))
                            .strikethrough()
                            .foregroundColor(.white.opacity(0.45))
                    }
                    Text(product.localizedPriceString)
                        .font(.tte(26, .heavy))
                        .foregroundColor(.white)
                }

                Text(subtitleText(pkg))
                    .font(.tte(12))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.white.opacity(isOn ? 0.14 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(isOn ? Color.tteOrange : Color.white.opacity(0.15), lineWidth: isOn ? 2 : 1)
            )
            .overlay(alignment: .top) {
                // '가장 인기' 리본 — 카드 상단 테두리에 걸쳐 띄운다
                Text(L("paywall.bestValue"))
                    .font(.tte(11, .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Capsule().fill(Color.tteOrange))
                    .offset(y: -12)
            }
            .scaleEffect(isOn ? 1.0 : 0.98)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: selectedPackage?.identifier)
        .padding(.top, 10)   // 리본이 위 요소와 겹치지 않게
    }

    // MARK: - 월간 카드 (컴팩트)
    private func monthlyCard(_ pkg: Package) -> some View {
        let isOn = selectedPackage?.identifier == pkg.identifier
        let product = pkg.storeProduct
        return Button {
            select(pkg)
        } label: {
            HStack(spacing: 8) {
                selectionCircle(isOn)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(L("paywall.monthly"))
                            .font(.tte(16, .bold))
                            .foregroundColor(.white)
                        if product.introductoryDiscount?.price == 0 {
                            Text(L("paywall.freeTrial7"))
                                .font(.tte(11, .bold))
                                .foregroundColor(.tteOrange)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.tteOrange.opacity(0.18)))
                        }
                    }
                    Text(L("paywall.monthlyBilling"))
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
                    .stroke(isOn ? Color.tteOrange : Color.white.opacity(0.12), lineWidth: isOn ? 2 : 1)
            )
            .scaleEffect(isOn ? 1.0 : 0.98)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: selectedPackage?.identifier)
    }

    private func selectionCircle(_ isOn: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(isOn ? Color.tteOrange : Color.white.opacity(0.35), lineWidth: 1.8)
                .frame(width: 22, height: 22)
            if isOn {
                Circle().fill(Color.tteOrange).frame(width: 22, height: 22)
                Image(systemName: "checkmark")
                    .font(.tte(11, .bold))
                    .foregroundColor(.white)
            }
        }
    }

    private func select(_ pkg: Package) {
        guard selectedPackage?.identifier != pkg.identifier else { return }
        Haptics.light()
        selectedPackage = pkg
    }

    /// 연간의 월간 대비 절약률 (월간 패키지가 함께 있을 때만).
    /// 주의: 나눗셈 결과 Decimal을 NSDecimalNumber.intValue로 바로 뽑으면
    /// 지수 표현에 따라 0이 나오는 함정이 있어 doubleValue 경유로 계산한다.
    private var savingsPercent: Int? {
        guard let annualPrice = annual?.storeProduct.price,
              let monthlyPrice = monthly?.storeProduct.price, monthlyPrice > 0 else { return nil }
        let annualValue = NSDecimalNumber(decimal: annualPrice).doubleValue
        let yearAtMonthly = NSDecimalNumber(decimal: monthlyPrice).doubleValue * 12
        guard yearAtMonthly > 0 else { return nil }
        let pct = Int(((1 - annualValue / yearAtMonthly) * 100).rounded())
        return pct > 0 ? pct : nil
    }

    /// 월간×12 정가 문자열 — 연간가 옆 취소선 비교용
    private var compareAtPriceString: String? {
        guard let monthly, let annual else { return nil }
        let yearAtMonthly = monthly.storeProduct.price * 12
        guard yearAtMonthly > annual.storeProduct.price else { return nil }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = annual.storeProduct.priceFormatter?.locale ?? .current
        return f.string(from: NSDecimalNumber(decimal: yearAtMonthly))
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
        return L("paywall.monthlyBilling")
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
