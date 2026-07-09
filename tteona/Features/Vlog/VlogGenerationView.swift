import SwiftUI
import AVKit
import Photos
import PhotosUI
import FirebaseAuth

struct VlogGenerationView: View {
    let course: Course
    let sessionId: String
    // 이번 세션에서 새로 저장된 코스일 때만 전달 — 프리뷰에 탐색탭 썸네일 선택 노출
    var thumbnailCourseId: String? = nil
    var onDismissToHome: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pro = ProManager.shared
    @State private var showPaywall = false

    @State private var phase: Phase = .chooseFormat
    @State private var vlogURL: URL?
    @State private var errorMessage: String?
    @State private var progress: Double = 0
    @State private var stageText = L("vlog.creating")
    @State private var savedFormatsCount = 1
    @State private var selectedFormats: Set<String> = []   // 기본 포맷 외 추가 선택

    // 생성 시도 관리 — attempt를 올리면 generatingView의 task가 다시 돈다
    @State private var attempt = 0
    // 서버를 건너뛰고 즉시 로컬 합성 (오류 화면에서 "음악 없이 지금 저장" 선택 시)
    @State private var forceLocal = false
    // 서버가 아직 렌더링 중이라 이어받기가 가능한 상태
    @State private var canResume = false
    // 저장된 영상이 서버본이 아니라 로컬 폴백본(BGM·워터마크·자막 없음)인가
    @State private var didFallback = false

    // 촬영 방향 판별 — 클립 다수 방향 (nil = 판별 중, 기본 세로 가정)
    @State private var shotPortrait: Bool? = nil

    // BGM 선택 — "auto"(태그 기반 자동) | "none"(음악 없음) | "mood/파일명"(지정 트랙)
    @State private var bgmTracks: [BgmTrack] = []
    @State private var selectedBgm = "auto"
    @State private var previewPlayer: AVPlayer?
    @State private var playingTrackId: String?

    private let vlogService = VlogService()

    enum Phase { case chooseFormat, chooseBgm, generating, preview, error }

    var body: some View {
        switch phase {
        case .chooseFormat: chooseFormatView
        case .chooseBgm: chooseBgmView
        case .generating: generatingView
        case .preview:
            if let url = vlogURL {
                VlogPreviewView(vlogURL: url, thumbnailCourseId: thumbnailCourseId,
                                savedFormatsCount: savedFormatsCount,
                                fallbackNotice: didFallback) {
                    // 부모가 전달한 종료 클로저가 화면 닫기까지 책임진다
                    if let onDismissToHome {
                        onDismissToHome()
                    } else {
                        dismiss()
                    }
                }
            }
        case .error: errorView
        }
    }

    // MARK: - 포맷 선택

    /// 촬영 방향에 맞는 기본 포맷 — 세로 촬영이면 릴스, 가로 촬영이면 유튜브
    private var baseFormat: String { (shotPortrait ?? true) ? "reels" : "youtube" }

    private var chooseFormatView: some View {
        ZStack {
            VlogAuroraBackground()
            VStack(spacing: 0) {
                Spacer()
                Text(L("vlog.formatSheet.title"))
                    .font(.tte(22, .bold))
                    .foregroundColor(.white)
                Text(L("vlog.formatSheet.subtitle"))
                    .font(.tte(13))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.top, 6)

                VStack(spacing: 12) {
                    formatRow(icon: "iphone", title: L("vlog.format.reels"), ratio: "9:16",
                              subtitle: baseFormat == "reels" ? L("vlog.format.included") : L("vlog.format.blurConvert"),
                              key: "reels",
                              badge: baseFormat == "reels" ? L("vlog.format.portraitBadge") : nil)
                    formatRow(icon: "play.rectangle.fill", title: L("vlog.format.youtube"), ratio: "16:9",
                              subtitle: baseFormat == "youtube" ? L("vlog.format.included") : L("vlog.format.blurConvert"),
                              key: "youtube",
                              badge: baseFormat == "youtube" ? L("vlog.format.landscapeBadge") : nil)
                    formatRow(icon: "square.fill", title: L("vlog.format.insta"), ratio: "1:1",
                              subtitle: L("vlog.format.squareCrop"),
                              key: "insta", badge: nil)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)

                Spacer()

                Button {
                    phase = .chooseBgm
                } label: {
                    Text(selectedFormats.isEmpty ? L("session.makeVlog") : L("vlog.makeVersions", selectedFormats.count + 1))
                        .font(.tte(17, .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }
                .padding(.horizontal, 24)

                Button(L("common.close")) { dismiss() }
                    .font(.tte(14))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.top, 14)
                    .padding(.bottom, 36)
            }
        }
        .task { await detectShotOrientation() }
        .sheet(isPresented: $showPaywall) { ProPaywallView() }
    }

    /// 세션 클립들의 회전 메타를 읽어 다수 방향을 판별 → 특화 배지·기본 포맷 결정
    private func detectShotOrientation() async {
        guard shotPortrait == nil else { return }
        var portraitVotes = 0, landscapeVotes = 0
        for place in course.places {
            let url = VlogService.clipURL(place: place, sessionId: sessionId)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { continue }
            let display = CGRect(origin: .zero, size: size).applying(transform)
            if abs(display.height) >= abs(display.width) { portraitVotes += 1 }
            else { landscapeVotes += 1 }
        }
        guard portraitVotes + landscapeVotes > 0 else { return }
        let portrait = portraitVotes >= landscapeVotes
        shotPortrait = portrait
        // 기본 포맷이 바뀌면 추가 선택 목록에서 제거 (서버가 항상 기본으로 생성)
        selectedFormats.remove(portrait ? "reels" : "youtube")
    }

    private func formatRow(icon: String, title: String, ratio: String,
                           subtitle: String, key: String, badge: String?) -> some View {
        let fixed = key == baseFormat
        // 기본 포맷은 무료 포함. 추가 포맷은 PRO 전용 — 무료 유저는 잠금 표시.
        let locked = !fixed && !pro.isPro
        let isOn = fixed || selectedFormats.contains(key)
        return Button {
            guard !fixed else { return }
            if locked { showPaywall = true; return }
            if selectedFormats.contains(key) { selectedFormats.remove(key) }
            else { selectedFormats.insert(key) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.tte(20))
                    .foregroundColor(isOn ? .tteOrange : .white.opacity(0.5))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.tte(16, .semibold))
                            .foregroundColor(.white)
                        Text(ratio)
                            .font(.tte(12, .bold))
                            .foregroundColor(.tteOrange)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.tteOrange.opacity(0.18)))
                        if let badge {
                            HStack(spacing: 3) {
                                Image(systemName: "sparkles")
                                    .font(.tte(9, .bold))
                                Text(badge)
                                    .font(.tte(11, .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.tteOrange))
                        } else if locked {
                            proBadge
                        }
                    }
                    Text(subtitle)
                        .font(.tte(12))
                        .foregroundColor(.white.opacity(0.55))
                }
                Spacer()
                Image(systemName: locked ? "lock.fill"
                                         : (isOn ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: locked ? 18 : 22))
                    .foregroundColor(locked ? .white.opacity(0.4)
                                            : (isOn ? .tteOrange : .white.opacity(0.3)))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(isOn ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isOn ? Color.tteOrange.opacity(0.6) : Color.clear, lineWidth: 1.2)
            )
        }
        .disabled(fixed)
    }

    /// PRO 전용 잠금 배지
    private var proBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "crown.fill")
                .font(.tte(8, .bold))
            Text("PRO")
                .font(.tte(10, .heavy))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(
            LinearGradient(colors: [Color(red: 1, green: 0.7, blue: 0.3), .tteOrange],
                           startPoint: .leading, endPoint: .trailing)
        ))
    }

    // MARK: - BGM 선택

    struct BgmTrack: Decodable, Identifiable {
        let id: String     // "mood/파일명"
        let name: String
        let mood: String   // 커플 · 친구 · 가족 · 혼자
        let url: String
    }

    private var chooseBgmView: some View {
        ZStack {
            VlogAuroraBackground()
            VStack(spacing: 0) {
                Spacer(minLength: 60)
                Text(L("vlog.bgmSheet.title"))
                    .font(.tte(22, .bold))
                    .foregroundColor(.white)
                Text(L("vlog.bgmSheet.subtitle"))
                    .font(.tte(13))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.top, 6)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        bgmRow(id: "auto", name: L("vlog.bgm.auto"), mood: course.tag.displayName,
                               subtitle: L("vlog.bgm.auto.subtitle"), previewURL: nil)
                        bgmRow(id: "none", name: L("vlog.bgm.none"), mood: nil,
                               subtitle: L("vlog.bgm.none.subtitle"), previewURL: nil)
                        ForEach(bgmTracks) { track in
                            bgmRow(id: track.id, name: track.name, mood: track.mood,
                                   subtitle: nil, previewURL: URL(string: track.url))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 12)
                }

                Button {
                    stopBgmPreview()
                    phase = .generating
                } label: {
                    Text(L("session.makeVlog"))
                        .font(.tte(17, .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }
                .padding(.horizontal, 24)

                Button(L("vlog.back")) {
                    stopBgmPreview()
                    phase = .chooseFormat
                }
                .font(.tte(14))
                .foregroundColor(.white.opacity(0.6))
                .padding(.top, 14)
                .padding(.bottom, 36)
            }
        }
        .task { await loadBgmTracks() }
        .onDisappear { stopBgmPreview() }
        .sheet(isPresented: $showPaywall) { ProPaywallView() }
    }

    private func bgmRow(id: String, name: String, mood: String?,
                        subtitle: String?, previewURL: URL?) -> some View {
        let isOn = selectedBgm == id
        // 자동 추천·음악 없음은 무료. 개별 트랙(previewURL 존재)은 PRO 전용.
        let locked = previewURL != nil && !pro.isPro
        return Button {
            if locked { showPaywall = true; return }
            selectedBgm = id
        } label: {
            HStack(spacing: 14) {
                Image(systemName: id == "auto" ? "wand.and.stars"
                                : (id == "none" ? "speaker.slash" : "music.note"))
                    .font(.tte(18))
                    .foregroundColor(isOn ? .tteOrange : .white.opacity(0.5))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.tte(16, .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if let mood {
                            Text(mood)
                                .font(.tte(11, .bold))
                                .foregroundColor(.tteOrange)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Color.tteOrange.opacity(0.18)))
                        }
                        if locked { proBadge }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.tte(12))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
                Spacer()
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.tte(18))
                        .foregroundColor(.white.opacity(0.4))
                } else {
                    if let previewURL {
                        Button {
                            toggleBgmPreview(id: id, url: previewURL)
                        } label: {
                            Image(systemName: playingTrackId == id ? "pause.circle.fill" : "play.circle")
                                .font(.tte(26))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                    }
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.tte(22))
                        .foregroundColor(isOn ? .tteOrange : .white.opacity(0.3))
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(isOn ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isOn ? Color.tteOrange.opacity(0.6) : Color.clear, lineWidth: 1.2)
            )
        }
    }

    private func loadBgmTracks() async {
        guard bgmTracks.isEmpty else { return }
        if let tracks = try? await VlogServerService.shared.fetchBgmTracks() {
            bgmTracks = tracks.map { BgmTrack(id: $0.id, name: $0.name, mood: $0.mood, url: $0.url) }
        }
        // 목록을 못 받아도 자동 추천/음악 없음 두 옵션으로 진행 가능
    }

    private func toggleBgmPreview(id: String, url: URL) {
        if playingTrackId == id {
            stopBgmPreview()
            return
        }
        previewPlayer?.pause()
        let player = AVPlayer(url: url)
        player.play()
        previewPlayer = player
        playingTrackId = id
    }

    private func stopBgmPreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        playingTrackId = nil
    }

    // MARK: - 생성 중
    private var generatingView: some View {
        ZStack {
            VlogAuroraBackground()
            VStack(spacing: 28) {
                Spacer()

                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 6)
                        .frame(width: 100, height: 100)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 100, height: 100)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.tte(20, .bold))
                        .foregroundColor(.white)
                }

                VStack(spacing: 8) {
                    Text(stageText)
                        .font(.tte(18, .semibold))
                        .foregroundColor(.white)
                        .animation(.easeInOut(duration: 0.2), value: stageText)
                    Text(course.courseName)
                        .font(.tte(14))
                        .foregroundColor(.white.opacity(0.6))
                }

                Spacer()
            }
        }
        // 합성은 수 분이 걸린다. 화면이 잠기면 앱이 중단돼 업로드·폴링이 끊기고
        // 결과적으로 BGM·워터마크가 빠진 로컬 폴백본이 저장된다 — 그 사이 잠금을 막는다.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task(id: attempt) { await runGeneration() }
    }

    /// 서버 합성 → (필요 시) 로컬 폴백 → 앨범 저장 → 프리뷰.
    private func runGeneration() async {
        progress = 0
        stageText = L("vlog.creating")
        canResume = false
        didFallback = false
        do {
            var mainURL: URL
            var extraURLs: [URL] = []

            if let uid = Auth.auth().currentUser?.uid, !forceLocal {
                do {
                    // 1순위: 서버(WAS 8코어) 합성 — 폰 부담 없이 빠르고 BGM·멀티포맷 포함
                    let result = try await VlogServerService.shared.generate(
                        course: course, sessionId: sessionId, userId: uid,
                        formats: Array(selectedFormats), bgm: selectedBgm,
                        watermark: !pro.isPro,   // PRO 유저만 워터마크 제거
                        priority: pro.isPro,     // PRO 유저 우선 렌더링
                        onProgress: { p, stage in
                            progress = p
                            stageText = stage
                        }
                    )
                    mainURL = result.main
                    extraURLs = result.extras.map(\.url)
                    print("[VlogGeneration] 서버 합성 성공 (추가 포맷: \(result.extras.map(\.format)))")
                } catch {
                    if Task.isCancelled || error is CancellationError { return }

                    // 서버가 아직 이 잡을 붙잡고 있다면 로컬로 도망치지 않는다 —
                    // 지금 폴백하면 음악·워터마크 없는 열화본이 저장되고, 서버는 헛일을 한다.
                    // 대신 이어받기를 안내해 다음 시도에서 완성본을 그대로 받아오게 한다.
                    let definitive = (error as? VlogServerService.ServerVlogError)?.isDefinitive ?? false
                    let pending = await VlogServerService.shared.hasPendingJob(sessionId: sessionId)
                    if !definitive, pending {
                        print("[VlogGeneration] 서버 렌더링 진행 중 — 이어받기 안내: \(error.localizedDescription)")
                        canResume = true
                        errorMessage = L("vlog.error.serverBusy")
                        phase = .error
                        return
                    }

                    // 서버가 확정 실패했거나 애초에 잡이 만들어지지 않았다 → 로컬 합성으로 결과는 보장
                    print("[VlogGeneration] 서버 합성 실패 → 로컬 폴백: \(error.localizedDescription)")
                    didFallback = true
                    stageText = L("vlog.creating")
                    progress = 0.05
                    mainURL = try await vlogService.generateVlog(
                        course: course, sessionId: sessionId,
                        onProgress: { p in Task { @MainActor in progress = p } }
                    )
                }
            } else {
                didFallback = forceLocal
                mainURL = try await vlogService.generateVlog(
                    course: course, sessionId: sessionId,
                    onProgress: { p in Task { @MainActor in progress = p } }
                )
            }

            print("[VlogGeneration] url=\(mainURL.path) exists=\(FileManager.default.fileExists(atPath: mainURL.path))")
            // 앨범 저장 권한 확인
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            let isAuthorized = status == .authorized || status == .limited
            if !isAuthorized {
                let newStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                let ok = newStatus == .authorized || newStatus == .limited
                if !ok {
                    throw NSError(
                        domain: "tteona.permissions",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: L("vlog.photoPermission")]
                    )
                }
            }
            try await vlogService.saveToPhotoLibrary(url: mainURL)
            var saved = 1
            for extra in extraURLs {
                // 추가 선택한 포맷 버전도 함께 저장 (실패해도 무시)
                if (try? await vlogService.saveToPhotoLibrary(url: extra)) != nil { saved += 1 }
            }
            savedFormatsCount = saved
            vlogURL = mainURL
            Haptics.success()
            // 발자취 적재 — 브이로그가 완성된 여행만 지도에 칠해진다 (실패해도 흐름 방해 없음)
            if let uid = Auth.auth().currentUser?.uid {
                let recordCourse = course
                let recordSessionId = sessionId
                Task {
                    await FootprintService.shared.record(
                        course: recordCourse, sessionId: recordSessionId, userId: uid)
                }
            }
            phase = .preview
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            errorMessage = error.localizedDescription
            phase = .error
        }
    }

    // MARK: - 에러
    private var errorView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: canResume ? "clock.arrow.circlepath" : "exclamationmark.triangle.fill")
                    .font(.tte(48))
                    .foregroundColor(canResume ? .tteOrange : .red)
                Text(canResume ? L("vlog.error.serverBusy.title") : L("vlog.failed"))
                    .font(.tte(18, .semibold)).foregroundColor(.white)
                if let msg = errorMessage {
                    Text(msg)
                        .font(.tte(13)).foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                }

                VStack(spacing: 12) {
                    // 다시 시도 — 서버에 잡이 남아 있으면 업로드를 건너뛰고 완성본만 받아온다
                    Button(canResume ? L("vlog.resume") : L("vlog.retry")) {
                        forceLocal = false
                        attempt += 1
                        phase = .generating
                    }
                    .buttonStyle(TteButtonStyle())

                    if canResume {
                        // 기다릴 수 없을 때의 탈출구 — 음악·워터마크 없는 기본본으로 지금 저장
                        Button(L("vlog.saveWithoutMusic")) {
                            forceLocal = true
                            attempt += 1
                            phase = .generating
                        }
                        .font(.tte(14, .medium))
                        .foregroundColor(.white.opacity(0.75))
                    }

                    Button(L("vlog.goBack")) { dismiss() }
                        .font(.tte(14))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 40)
            }
        }
    }
}

// MARK: - 주황 그라데이션 일렁임 배경 (Vlog 대기·포맷선택 화면)
struct VlogAuroraBackground: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            // 딥 웜 베이스
            Color(red: 0.10, green: 0.04, blue: 0.01).ignoresSafeArea()

            // 떠나 주황 계열 글로우 3개가 천천히 떠다니며 일렁임
            Circle()
                .fill(Color.tteOrange.opacity(0.55))
                .frame(width: 430, height: 430)
                .blur(radius: 95)
                .offset(x: animate ? -130 : 110, y: animate ? -230 : -70)
            Circle()
                .fill(Color(red: 1.0, green: 0.63, blue: 0.35).opacity(0.45))
                .frame(width: 360, height: 360)
                .blur(radius: 85)
                .offset(x: animate ? 140 : -100, y: animate ? 190 : 330)
            Circle()
                .fill(Color(red: 1.0, green: 0.40, blue: 0.45).opacity(0.30))
                .frame(width: 320, height: 320)
                .blur(radius: 95)
                .offset(x: animate ? -50 : 70, y: animate ? 340 : 60)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}

// MARK: - Vlog Preview
struct VlogPreviewView: View {
    let vlogURL: URL
    let thumbnailCourseId: String?
    let savedFormatsCount: Int
    /// 서버 합성에 실패해 음악·워터마크가 빠진 로컬 버전이 저장된 경우 — 조용히 넘기지 않고 알린다
    let fallbackNotice: Bool
    let onDismiss: () -> Void

    @State private var player: AVPlayer
    @State private var showShareSheet = false
    @State private var thumbPickerItem: PhotosPickerItem?
    @State private var thumbState: ThumbState = .idle

    private enum ThumbState { case idle, uploading, done, failed }

    init(vlogURL: URL, thumbnailCourseId: String? = nil,
         savedFormatsCount: Int = 1, fallbackNotice: Bool = false,
         onDismiss: @escaping () -> Void) {
        self.vlogURL = vlogURL
        self.thumbnailCourseId = thumbnailCourseId
        self.savedFormatsCount = savedFormatsCount
        self.fallbackNotice = fallbackNotice
        self.onDismiss = onDismiss
        _player = State(initialValue: AVPlayer(url: vlogURL))
    }

    var body: some View {
        ZStack {
            VlogAuroraBackground()

            VStack(spacing: 0) {
                // 완성 헤더 — 축하하는 나루 + 문구 + 자동 저장 안내
                VStack(spacing: 8) {
                    Image("tteoni-jump")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 96)
                    Text(L("vlog.done.title"))
                        .font(.tte(23, .bold))
                        .foregroundColor(.white)
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.tte(12))
                            .foregroundColor(.green)
                        Text(savedFormatsCount > 1
                             ? L("vlog.done.savedMulti", savedFormatsCount)
                             : L("vlog.done.savedSingle"))
                            .font(.tte(13, .medium))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.12)))

                    if fallbackNotice {
                        HStack(spacing: 6) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.tte(11))
                                .foregroundColor(.yellow)
                            Text(L("vlog.done.fallbackNotice"))
                                .font(.tte(11))
                                .foregroundColor(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.yellow.opacity(0.12)))
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.top, 28)

                // 영상 카드 — 라운드 + 테두리 + 그림자
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .onAppear { player.play() }

                // 액션 영역
                VStack(spacing: 12) {
                    if let courseId = thumbnailCourseId {
                        thumbnailButton(courseId: courseId)
                    }

                    Button {
                        showShareSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                            Text(L("vlog.share"))
                        }
                        .font(.tte(16, .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                        .shadow(color: .tteOrange.opacity(0.4), radius: 12, y: 4)
                    }

                    Button {
                        onDismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "house.fill")
                                .font(.tte(13))
                            Text(L("vlog.goHome"))
                        }
                        .font(.tte(15, .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.10)))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 34)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [vlogURL])
        }
    }

    // MARK: - 탐색탭 썸네일 선택

    private func thumbnailButton(courseId: String) -> some View {
        PhotosPicker(selection: $thumbPickerItem, matching: .images) {
            HStack(spacing: 8) {
                switch thumbState {
                case .idle:
                    Image(systemName: "photo.on.rectangle.angled")
                    Text(L("vlog.thumbnail.pick"))
                case .uploading:
                    ProgressView().tint(.white).scaleEffect(0.8)
                    Text(L("vlog.thumbnail.uploading"))
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(L("vlog.thumbnail.done"))
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                    Text(L("vlog.thumbnail.failed"))
                }
            }
            .font(.tte(15, .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1.5)
            )
        }
        .disabled(thumbState == .uploading)
        .onChange(of: thumbPickerItem) { _, newItem in
            Task { await uploadThumbnail(from: newItem, courseId: courseId) }
        }
    }

    private func uploadThumbnail(from item: PhotosPickerItem?, courseId: String) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            thumbState = .failed
            return
        }
        thumbState = .uploading
        if await CourseThumbnailService.shared.upload(courseId: courseId, image: image) != nil {
            thumbState = .done
        } else {
            thumbState = .failed
        }
    }
}

// MARK: - Reusable Button Style
struct TteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.tte(16, .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.tteOrange.opacity(configuration.isPressed ? 0.7 : 1.0))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
