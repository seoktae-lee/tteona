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
                            Text("여행의 순간을 더 길게, 더 자유롭게")
                                .font(.tte(14))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding(.top, 12)

                        VStack(alignment: .leading, spacing: 14) {
                            featureRow(icon: "sparkles.rectangle.stack", title: "워터마크 제거",
                                       subtitle: "로고 없는 깨끗한 영상으로 저장돼요")
                            featureRow(icon: "rectangle.3.group", title: "멀티포맷 제공",
                                       subtitle: "릴스·유튜브·인스타 3가지 버전을 한 번에")
                            featureRow(icon: "music.note.list", title: "BGM 전체 라이브러리",
                                       subtitle: "모든 음악을 직접 골라 넣을 수 있어요")
                            featureRow(icon: "timer", title: "영상 길이 5분으로 확대",
                                       subtitle: "장소당 5초·총 30초 제한 없이 최대 5분까지")
                            featureRow(icon: "bolt.fill", title: "우선 렌더링",
                                       subtitle: "대기 없이 내 영상부터 먼저 만들어드려요")
                        }
                        .padding(20)
                        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.07)))
                        .padding(.horizontal, 24)

                        if packages.isEmpty {
                            VStack(spacing: 10) {
                                Text("요금제를 불러오지 못했어요")
                                    .font(.tte(14))
                                    .foregroundColor(.white.opacity(0.7))
                                Button("다시 시도") {
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
                        Button("구매 복원") { Task { await restore() } }
                        Link("이용약관", destination: URL(string: "https://tteona.kr/terms")!)
                        Link("개인정보처리방침", destination: URL(string: "https://tteona.kr/privacy")!)
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
        .alert("알림", isPresented: Binding(get: { alertMessage != nil },
                                          set: { if !$0 { alertMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var ctaTitle: String {
        guard let pkg = selectedPackage else { return "구독 시작하기" }
        if pkg.storeProduct.introductoryDiscount?.price == 0 {
            return "무료 체험 시작하기"
        }
        return "구독 시작하기"
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
                        Text(pkg.packageType == .annual ? "연간" : "월간")
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
                            Text("7일 무료")
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
        return pct > 0 ? "\(pct)% 할인" : nil
    }

    private func subtitleText(_ pkg: Package) -> String {
        if pkg.packageType == .annual {
            let perMonth = pkg.storeProduct.price / 12
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.locale = pkg.storeProduct.priceFormatter?.locale ?? .current
            if let s = f.string(from: NSDecimalNumber(decimal: perMonth)) {
                return "월 \(s) 꼴 · 1년에 한 번 결제"
            }
            return "1년에 한 번 결제"
        }
        return "언제든 해지 가능"
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
            alertMessage = "결제에 실패했어요. 잠시 후 다시 시도해주세요."
        }
    }

    private func restore() async {
        do {
            let active = try await pro.restore()
            alertMessage = active ? "구독이 복원됐어요!" : "복원할 구독을 찾지 못했어요."
        } catch {
            alertMessage = "복원에 실패했어요. 잠시 후 다시 시도해주세요."
        }
    }
}
