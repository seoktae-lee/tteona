import SwiftUI
import AVFoundation

/// 촬영 탭 상단 칩을 누르면 올라오는 "오늘 찍은 곳" 시트.
///
/// 예전엔 칩을 누르면 곧바로 '오늘 마치기'로 갔는데, 우상단 ✓와 하는 일이 같았고
/// 진행바에 `>`가 달려 "자세히 보기"로 읽히는 것과도 어긋났다. 칩은 확인·정리를,
/// ✓는 종료를 맡게 나눈다.
///
/// **개별 삭제가 이 화면의 존재 이유다.** 촬영 예산이 30초로 빡빡한데 지금까지는
/// 잘못 찍은 컷 하나를 되돌리려면 '오늘 기록 버리기'로 전부 날리는 수밖에 없었다.
/// 여기서 하나를 지우면 그만큼 예산이 돌아온다.
struct CaptureListSheet: View {
    let places: [Place]
    let sessionId: String
    let usedSeconds: Double
    let budgetSeconds: Double
    let onDelete: (Place) -> Void
    /// 오늘 기록을 통째로 버린다 — 예산이 찬 채로 아무것도 못 하게 갇혔을 때의 탈출구
    let onDiscardAll: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// clipFileName → 길이(초). 파일에서 읽어오므로 비동기.
    @State private var durations: [String: Double] = [:]
    @State private var pendingDelete: Place?
    @State private var showDiscardAll = false

    private var budgetRatio: Double {
        guard budgetSeconds > 0 else { return 0 }
        return min(1, usedSeconds / budgetSeconds)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            if places.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(places) { place in
                        row(place)
                            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 12))
                    }
                }
                .listStyle(.plain)
            }

            closeButton
            discardAllButton
        }
        .alert(L("impromptu.discardToday"), isPresented: $showDiscardAll) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("impromptu.discardToday"), role: .destructive) {
                onDiscardAll()
                dismiss()
            }
        } message: {
            Text(L("capture.list.discardAllMessage"))
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await loadDurations() }
        .alert(L("capture.list.deleteTitle"), isPresented: .constant(pendingDelete != nil)) {
            Button(L("common.cancel"), role: .cancel) { pendingDelete = nil }
            Button(L("common.delete"), role: .destructive) {
                if let p = pendingDelete { onDelete(p) }
                pendingDelete = nil
            }
        } message: {
            Text(L("capture.list.deleteMessage", pendingDelete?.placeName ?? ""))
        }
    }

    // MARK: - 헤더 (개수 + 예산)

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("capture.list.title"))
                    .font(.tte(18, .bold))
                    .foregroundColor(.tteDarkGray)
                Spacer()
                Text(L("capture.list.count", places.count))
                    .font(.tte(14, .semibold))
                    .foregroundColor(.tteOrange)
            }

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.tteMediumGray.opacity(0.18))
                        Capsule()
                            .fill(budgetRatio >= 1 ? Color.red.opacity(0.8) : Color.tteOrange)
                            .frame(width: max(4, geo.size.width * budgetRatio))
                    }
                }
                .frame(height: 6)

                Text(L("capture.list.budget",
                       Int(usedSeconds.rounded()), Int(budgetSeconds.rounded())))
                    .font(.tte(12))
                    .foregroundColor(budgetRatio >= 1 ? .red : .tteMediumGray)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - 한 줄

    private func row(_ place: Place) -> some View {
        HStack(spacing: 12) {
            Text("\(place.order)")
                .font(.tte(12, .bold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.tteOrange))

            VStack(alignment: .leading, spacing: 2) {
                Text(place.placeName)
                    .font(.tte(15, .medium))
                    .foregroundColor(.tteDarkGray)
                    .lineLimit(1)
                if let sec = place.clipFileName.flatMap({ durations[$0] }) {
                    Text(L("capture.list.seconds", String(format: "%.1f", sec)))
                        .font(.tte(12))
                        .foregroundColor(.tteMediumGray)
                }
            }

            Spacer(minLength: 8)

            Button {
                Haptics.light()
                pendingDelete = place
            } label: {
                Image(systemName: "trash")
                    .font(.tte(15))
                    .foregroundColor(.tteMediumGray)
                    .frame(width: 44, height: 44)   // 손가락이 닿는 최소 크기
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("common.delete"))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "camera")
                .font(.tte(28))
                .foregroundColor(.tteMediumGray.opacity(0.5))
            Text(L("capture.list.empty"))
                .font(.tte(14))
                .foregroundColor(.tteMediumGray)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var closeButton: some View {
        Button {
            Haptics.light()
            dismiss()
        } label: {
            Text(L("capture.list.keepShooting"))
                .font(.tte(16, .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 15).fill(Color.tteOrange))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    /// 하나씩 지우기 번거로울 때를 위한 탈출구. 눈에 띄지 않게 아래에 작게 둔다.
    private var discardAllButton: some View {
        Button(role: .destructive) {
            showDiscardAll = true
        } label: {
            Text(L("impromptu.discardToday"))
                .font(.tte(13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .opacity(places.isEmpty ? 0 : 1)
    }

    // MARK: - 길이 읽기

    /// 세션 폴더의 클립 길이를 한 번에 읽어 둔다.
    /// 줄마다 읽으면 스크롤할 때마다 디스크를 때리므로 진입 시 한 번만 훑는다.
    private func loadDurations() async {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tteona/Sessions/\(sessionId)")
        var result: [String: Double] = [:]
        for place in places {
            guard let name = place.clipFileName else { continue }
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let d = try? await AVURLAsset(url: url).load(.duration) {
                result[name] = CMTimeGetSeconds(d)
            }
        }
        durations = result
    }
}
