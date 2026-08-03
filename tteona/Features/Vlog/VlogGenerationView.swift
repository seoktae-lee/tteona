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
    // 세션 시작 때 위치를 공유한 방들 — 공유 설정이 켜져 있으면 완성본이 이 방들에 자동 공유된다
    var shareRoomIds: Set<String> = []
    /// 브이로그가 실제로 완성돼 앨범까지 저장된 순간에 불린다.
    /// 세션 만료 같은 '되돌릴 수 없는 정리'는 나가는 버튼이 아니라 여기에 매달아야 한다 —
    /// 버튼에 매달면 다른 경로로 화면을 빠져나갔을 때 정리가 통째로 누락된다.
    var onVlogCompleted: (() -> Void)? = nil
    var onDismissToHome: (() -> Void)? = nil
    // 방 선택 화면의 "완성된 브이로그도 공유" 토글과 같은 저장소를 본다
    @AppStorage("vlog.shareToRooms") private var shareVlogPref = true
    // 장소 자막 서체·크기 — 다음 생성에도 기억된다 (기본: 고운바탕·보통)
    @AppStorage("vlog.font") private var vlogFont = VlogFont.gowun.rawValue
    @AppStorage("vlog.fontScale") private var vlogFontScale = VlogFontScale.medium.rawValue
    @AppStorage("vlog.subtitleFields") private var vlogFields = VlogSubtitleFields.both.rawValue
    @AppStorage("vlog.subtitleColor") private var vlogColor = VlogSubtitleColor.orange.rawValue
    /// 장소별 한 줄 문구 (클립 파일명 → 문구). 저장하지 않는다 —
    /// 이번 여행에 붙이는 말이라 다음 브이로그에 지난 글이 남으면 안 된다.
    @State private var captions: [String: String] = [:]
    /// 지금 문구를 편집 중인 클립
    @State private var editingClip: String?
    /// 클립 첫 프레임 캐시 (클립 파일명 → 이미지)
    @State private var previewFrames: [String: UIImage] = [:]
    @AppStorage("vlog.subtitleHold") private var subtitleHold = false
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pro = ProManager.shared
    @ObservedObject private var tutorial = VlogTutorial.shared
    @State private var showPaywall = false
    @State private var showAuthForGuestLimit = false

    @State private var phase: Phase = .chooseFormat
    @State private var didCheckGuestQuota = false
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

    enum Phase { case chooseFormat, chooseBgm, chooseText, chooseCaption, generating, preview, error, guestLimit }

    /// 게스트가 이미 첫 브이로그를 받았는가. 판정은 **진입할 때** 한다 —
    /// 포맷·음악·자막까지 다 고르게 해 놓고 마지막에 막으면 헛수고를 시키는 셈이다.
    private var guestQuotaExhausted: Bool {
        Auth.auth().currentUser?.isAnonymous == true && GuestVlogQuota.isExhausted
    }

    var body: some View {
        switch phase {
        case .guestLimit: guestLimitView
        case .chooseFormat:
            chooseFormatView
                .onAppear {
                    guard !didCheckGuestQuota else { return }
                    didCheckGuestQuota = true
                    if guestQuotaExhausted { phase = .guestLimit }
                }
        case .chooseBgm: chooseBgmView
        case .chooseText: chooseTextView
        case .chooseCaption: chooseCaptionView
        case .generating: generatingView
        case .preview:
            if let url = vlogURL {
                ZStack {
                    VlogPreviewView(vlogURL: url, thumbnailCourseId: thumbnailCourseId,
                                    savedFormatsCount: savedFormatsCount,
                                    fallbackNotice: didFallback,
                                    shareMissed: didFallback && shareVlogPref && !shareRoomIds.isEmpty) {
                        // 부모가 전달한 종료 클로저가 화면 닫기까지 책임진다
                        if let onDismissToHome {
                            onDismissToHome()
                        } else {
                            dismiss()
                        }
                    }

                    // 튜토리얼 완주 — 축하 + 무료 한도(6곳×5초) 안내
                    if tutorial.isOn(.celebrate) {
                        TutorialCelebrateOverlay {
                            tutorial.finish()
                        }
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

                // 튜토리얼 — 기본 포맷 그대로 다음 단계로 유도
                if tutorial.isOn(.chooseFormat) {
                    TutorialBubble(mascot: "tteoni-travel", text: L("tutorial.format.text")) {
                        tutorial.finish()
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 8)
                }

                Button {
                    tutorial.advance(to: .chooseBgm)
                    phase = .chooseBgm
                } label: {
                    Text(selectedFormats.isEmpty ? L("session.makeVlog") : L("vlog.makeVersions", selectedFormats.count + 1))
                        .font(.tte(17, .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }
                .tutorialGlow(tutorial.isOn(.chooseFormat), cornerRadius: 16)
                .padding(.horizontal, 24)

                Button(L("common.close")) {
                    tutorial.handleVlogExit()
                    dismiss()
                }
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

                // 튜토리얼 — 자동 추천 BGM 그대로 생성 유도
                if tutorial.isOn(.chooseBgm) {
                    TutorialBubble(mascot: "tteoni-wink", text: L("tutorial.bgm.text")) {
                        tutorial.finish()
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 8)
                }

                Button {
                    stopBgmPreview()
                    phase = .chooseText
                } label: {
                    Text(L("vlog.next"))
                        .font(.tte(17, .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }
                .tutorialGlow(tutorial.isOn(.chooseBgm), cornerRadius: 16)
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

    // MARK: - 글씨 스타일 선택

    private var selectedFont: VlogFont { VlogFont(rawValue: vlogFont) ?? .gowun }
    private var selectedScale: VlogFontScale { VlogFontScale(rawValue: vlogFontScale) ?? .medium }
    private var selectedFields: VlogSubtitleFields { VlogSubtitleFields(rawValue: vlogFields) ?? .both }
    private var selectedColor: VlogSubtitleColor { VlogSubtitleColor(rawValue: vlogColor) ?? .orange }
    private var subtitleStyle: VlogSubtitleStyle {
        VlogSubtitleStyle(font: selectedFont, scale: selectedScale,
                          fields: selectedFields, color: selectedColor,
                          holdsSubtitle: subtitleHold, captions: captions)
    }
    /// 미리보기에 쓸 실제 첫 장소명 (없으면 샘플)
    private var previewPlaceName: String {
        course.places.first?.placeName ?? L("vlog.font.sampleName")
    }
    /// 미리보기 자막 날짜 — 서버 자막과 같은 형식(yyyy.MM.dd HH:mm)
    private static var previewDateString: String {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy.MM.dd  HH:mm"
        return df.string(from: Date())
    }

    /// 두 번째 브이로그부터 — 약속했던 대로 회원가입을 요청한다.
    /// 막는 화면이 아니라 **첫 브이로그가 어땠는지 묻고 이어가자고 권하는** 화면이어야 한다.
    private var guestLimitView: some View {
        ZStack {
            VlogAuroraBackground()
            VStack(spacing: 0) {
                Spacer()
                Image("tteoni-thumbsup")
                    .resizable().scaledToFit()
                    .frame(width: 150, height: 150)
                    .floating(amplitude: 6, speed: 1.3)

                VStack(spacing: 10) {
                    Text(L("vlog.guestLimit.title"))
                        .font(.tte(23, .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    Text(L("vlog.guestLimit.message"))
                        .font(.tte(15))
                        .foregroundColor(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
                .padding(.horizontal, 36)
                .padding(.top, 24)

                Spacer()

                Button {
                    Haptics.light()
                    showAuthForGuestLimit = true
                } label: {
                    Text(L("vlog.guestLimit.signUp"))
                        .font(.tte(17, .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }
                .padding(.horizontal, 24)

                Button(L("vlog.guestLimit.later")) {
                    tutorial.handleVlogExit()
                    dismiss()
                }
                .font(.tte(14))
                .foregroundColor(.white.opacity(0.6))
                .padding(.top, 14)
                .padding(.bottom, 36)
            }
        }
        .fullScreenCover(isPresented: $showAuthForGuestLimit) { AuthView() }
    }

    private var chooseTextView: some View {
        ZStack {
            VlogAuroraBackground()
            VStack(spacing: 0) {
                Spacer(minLength: 40)
                Text(L("vlog.textSheet.title"))
                    .font(.tte(22, .bold))
                    .foregroundColor(.white)
                Text(L("vlog.textSheet.subtitle"))
                    .font(.tte(13))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.top, 6)

                // 실제 자막이 얹히는 모습 미리보기 (영상 프레임 흉내)
                textPreviewCard
                    .padding(.horizontal, 24)
                    .padding(.top, 24)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        // 서체
                        Text(L("vlog.textSheet.fontLabel"))
                            .font(.tte(13, .semibold))
                            .foregroundColor(.white.opacity(0.75))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(VlogFont.allCases) { font in
                                    fontChip(font)
                                }
                            }
                        }

                        // 크기
                        Text(L("vlog.textSheet.sizeLabel"))
                            .font(.tte(13, .semibold))
                            .foregroundColor(.white.opacity(0.75))
                        HStack(spacing: 10) {
                            ForEach(VlogFontScale.allCases) { scale in
                                sizePill(scale)
                            }
                        }

                        // 표시 항목 — 장소·시각 중 무엇을 남길지
                        Text(L("vlog.textSheet.fieldsLabel"))
                            .font(.tte(13, .semibold))
                            .foregroundColor(.white.opacity(0.75))
                        HStack(spacing: 10) {
                            ForEach(VlogSubtitleFields.allCases) { fields in
                                fieldsPill(fields)
                            }
                        }

                        // 강조색 — 첫 줄에 적용된다(렌더러와 같은 규칙)
                        Text(L("vlog.textSheet.colorLabel"))
                            .font(.tte(13, .semibold))
                            .foregroundColor(.white.opacity(0.75))
                        HStack(spacing: 12) {
                            ForEach(VlogSubtitleColor.allCases) { c in
                                colorDot(c)
                            }
                        }

                        // 자막 유지 — 끄면 2.5초만 보이고 사라진다
                        Toggle(isOn: $subtitleHold) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("vlog.textSheet.holdLabel"))
                                    .font(.tte(14, .semibold))
                                    .foregroundColor(.white)
                                Text(L("vlog.textSheet.holdHint"))
                                    .font(.tte(12))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        }
                        .tint(.tteOrange)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)

                Button {
                    editingClip = clipsForCaption.first?.clipFileName
                    phase = .chooseCaption
                } label: {
                    Text(L("common.next"))
                        .font(.tte(17, .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }
                .padding(.horizontal, 24)

                Button(L("vlog.back")) {
                    phase = .chooseBgm
                }
                .font(.tte(14))
                .foregroundColor(.white.opacity(0.6))
                .padding(.top, 14)
                .padding(.bottom, 36)
            }
        }
    }

    /// 선택한 서체·크기가 실제 자막처럼 얹힌 미리보기
    // MARK: - 장소별 한 줄 문구

    /// 실제로 클립이 있는 장소만 — 파일이 없는 장소는 브이로그에 안 들어간다
    private var clipsForCaption: [Place] {
        course.places.filter { place in
            FileManager.default.fileExists(
                atPath: VlogService.clipURL(place: place, sessionId: sessionId).path)
        }
    }

    private var chooseCaptionView: some View {
        ZStack {
            VlogAuroraBackground()
            VStack(spacing: 0) {
                Spacer(minLength: 30)
                Text(L("vlog.caption.title"))
                    .font(.tte(22, .bold))
                    .foregroundColor(.white)
                Text(L("vlog.caption.subtitle"))
                    .font(.tte(13))
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                    .padding(.horizontal, 32)

                // 세로 스크롤 안에 담는다 — 글씨 스타일 화면과 같은 구조.
                // 가로 칩 줄만 따로 두면 높이가 잡히지 않아 스크롤도 탭도 먹지 않았다.
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        // 클립이 하나뿐이면 고를 것이 없다 — 칩 줄을 감춘다
                        if clipsForCaption.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(clipsForCaption) { place in
                                        captionChip(place)
                                    }
                                }
                                .padding(.horizontal, 24)
                            }
                            .frame(height: 40)
                        }

                        clipPreviewCard
                        captionField.padding(.horizontal, 24)
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)

                Button {
                    phase = .generating
                } label: {
                    Text(L("session.makeVlog"))
                        .font(.tte(17, .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }
                .padding(.horizontal, 24)

                Button(L("vlog.back")) { phase = .chooseText }
                    .font(.tte(14))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.top, 14)
                    .padding(.bottom, 30)
            }
        }
    }

    private func captionChip(_ place: Place) -> some View {
        let isOn = editingClip == place.clipFileName
        let written = !(captions[place.clipFileName ?? ""] ?? "").isEmpty
        return Button {
            Haptics.light()
            editingClip = place.clipFileName
        } label: {
            HStack(spacing: 5) {
                Text("\(place.order)")
                    .font(.tte(11, .bold))
                    .foregroundColor(isOn ? .white : .tteOrange)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(isOn ? Color.white.opacity(0.25) : Color.tteOrange.opacity(0.18)))
                Text(place.placeName)
                    .font(.tte(13, isOn ? .bold : .medium))
                    .lineLimit(1)
                // 이미 적은 곳은 표시해 둔다 — 여러 곳을 오갈 때 어디를 채웠는지 놓치기 쉽다
                if written {
                    Image(systemName: "checkmark")
                        .font(.tte(9, .bold))
                        .foregroundColor(isOn ? .white : .tteOrange)
                }
            }
            .foregroundColor(isOn ? .white : .white.opacity(0.7))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                Capsule().fill(isOn ? Color.tteOrange : Color.white.opacity(0.10))
            )
        }
    }

    /// 완성될 영상과 **같은 비율**로 보여준다.
    /// 가로로 넓은 카드에 자막을 얹어 두면 실제 결과물이 그렇게 나오는 줄 오해한다 —
    /// 세로 촬영이면 9:16, 가로면 16:9로 맞춰 잘린 모습까지 그대로 보인다.
    private var previewAspect: CGFloat { baseFormat == "reels" ? 9.0 / 16.0 : 16.0 / 9.0 }
    private var previewHeight: CGFloat { baseFormat == "reels" ? 300 : 190 }

    /// 좌우로 넘겨 클립을 오갈 수 있게 한다 — 칩을 정확히 누르는 것보다 손이 편하다.
    /// 스와이프와 칩은 같은 값(editingClip)을 보므로 어느 쪽으로 바꿔도 함께 움직인다.
    private var clipPreviewCard: some View {
        TabView(selection: previewSelection) {
            ForEach(clipsForCaption) { place in
                previewCard(for: place)
                    .tag(place.clipFileName ?? "")
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: previewHeight + 16)
    }

    private var previewSelection: Binding<String> {
        Binding(
            get: { editingClip ?? clipsForCaption.first?.clipFileName ?? "" },
            set: { editingClip = $0 }
        )
    }

    private func previewCard(for place: Place) -> some View {
        let h = previewHeight
        let w = h * previewAspect
        let key = place.clipFileName ?? ""
        return ZStack {
            if let frame = previewFrames[key] {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()          // 서버의 cover 크롭과 같은 방식
            } else {
                LinearGradient(colors: [Color(red: 0.18, green: 0.10, blue: 0.05),
                                        Color(red: 0.30, green: 0.16, blue: 0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }

            VStack(spacing: 4) {
                if selectedFields.showsPlace {
                    previewLine(place.placeName, videoWanted: videoPlaceSize,
                                cardWidth: Double(w), color: selectedColor.color)
                }
                if selectedFields.showsTime {
                    previewLine(Self.previewDateString,
                                videoWanted: videoPlaceSize * 0.62, cardWidth: Double(w),
                                color: selectedFields.showsPlace ? .white : selectedColor.color)
                }
                let text = VlogSubtitleStyle.sanitize(captions[key] ?? "")
                if !text.isEmpty {
                    previewLine(text, videoWanted: videoPlaceSize * 0.62,
                                cardWidth: Double(w), color: .white)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .overlay(alignment: .bottom) {
            Text(baseFormat == "reels" ? "9:16" : "16:9")
                .font(.tte(10, .bold))
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .padding(.bottom, 8)
        }
        // 페이지마다 자기 프레임을 뽑는다 — 넘기기 전에 옆 장이 미리 준비된다
        .task { await loadPreviewFrame(for: place) }
    }

    private var currentPlace: Place? {
        clipsForCaption.first { $0.clipFileName == editingClip }
    }

    /// 클립의 첫 프레임을 뽑아 둔다. 한 번 뽑은 건 다시 뽑지 않는다.
    private func loadPreviewFrame(for place: Place) async {
        let key = place.clipFileName ?? ""
        guard !key.isEmpty, previewFrames[key] == nil else { return }
        let url = VlogService.clipURL(place: place, sessionId: sessionId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true      // 세로 촬영이 눕지 않게
        gen.maximumSize = CGSize(width: 720, height: 720)
        if let cg = try? await gen.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image {
            previewFrames[key] = UIImage(cgImage: cg)
        }
    }

    private var captionField: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("", text: captionBinding,
                      prompt: Text(L("vlog.caption.placeholder"))
                        .foregroundColor(.white.opacity(0.35)))
                .font(.tte(15))
                .foregroundColor(.white)
                .submitLabel(.done)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
            Text("\(currentCaption.count)/\(VlogSubtitleStyle.captionMaxLength)")
                .font(.tte(11))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private var currentCaption: String { captions[editingClip ?? ""] ?? "" }

    /// 입력을 한 곳으로 모은다 — 자르기와 햅틱을 onChange에 두면 값을 되돌려 쓸 때
    /// 다시 불려 한 번의 입력에 햅틱이 두 번 울린다.
    private var captionBinding: Binding<String> {
        Binding(
            get: { currentCaption },
            set: { raw in
                guard let key = editingClip else { return }
                let clamped = VlogSubtitleStyle.sanitize(raw)
                if clamped == currentCaption {
                    if raw != currentCaption { Haptics.limitReached() }
                } else {
                    Haptics.typing()
                }
                captions[key] = clamped
            }
        )
    }

    private var textPreviewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(colors: [Color(red: 0.18, green: 0.10, blue: 0.05),
                                            Color(red: 0.30, green: 0.16, blue: 0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            // 카드 폭을 알아야 실제 렌더와 같은 규칙으로 크기를 정할 수 있다
            GeometryReader { geo in
                let cardW = Double(geo.size.width)
                VStack(spacing: 6) {
                    if selectedFields.showsPlace {
                        previewLine(previewPlaceName, videoWanted: videoPlaceSize,
                                    cardWidth: cardW, color: selectedColor.color)
                    }
                    if selectedFields.showsTime {
                        // 강조색은 첫 줄에만 — 장소를 껐다면 시각이 첫 줄이 된다
                        previewLine(Self.previewDateString, videoWanted: videoPlaceSize * 0.62,
                                    cardWidth: cardW,
                                    color: selectedFields.showsPlace ? .white : selectedColor.color)
                    }
                    // 한 줄 문구는 다음 단계(장소별)에서 다룬다 — 여기서는 공통 스타일만 보여준다
                }
                .padding(.horizontal, 16)
                .frame(width: geo.size.width, height: geo.size.height)
                .animation(.easeInOut(duration: 0.18), value: selectedFields)
            }
        }
        .frame(height: 150)
        .overlay(
            RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func fontChip(_ font: VlogFont) -> some View {
        let isOn = selectedFont == font
        return Button {
            vlogFont = font.rawValue
            Haptics.light()
        } label: {
            Text(font.displayName)
                .font(.custom(font.postScriptName, size: 17))
                .foregroundColor(isOn ? .white : .white.opacity(0.7))
                .padding(.horizontal, 16).frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(isOn ? 0.14 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isOn ? Color.tteOrange : Color.clear, lineWidth: 1.5)
                )
        }
    }

    /// 미리보기 한 줄 — 실제 렌더와 **같은 규칙**으로 크기를 낮추고 말줄임한다.
    ///
    /// 예전엔 여기에만 `.minimumScaleFactor(0.5)`가 걸려 있어 SwiftUI가 몰래 글씨를 줄였다.
    /// 그 탓에 한글 9자만 넘어도 '보통'과 '크게'가 똑같은 크기로 그려져 단계 차이가 사라졌고,
    /// 정작 실제 영상은 줄이지 않고 화면 밖으로 흘려보냈다 — 미리보기가 결과와 어긋난 셈이다.
    /// 완성될 영상의 가로 픽셀. 자막 크기·줄임 판정을 여기 기준으로 한다.
    private var videoWidth: Double { baseFormat == "reels" ? 1080 : 1920 }
    /// 영상에서 쓰는 장소명 크기 — 서버와 같은 식(짧은 변의 4.2% × 배율)
    private var videoPlaceSize: Double { 1080 * 0.042 * Double(selectedScale.multiplier) }
    /// 미리보기는 실제보다 조금 크게 그린다. 그대로 축소하면 9pt라 읽히지 않는다.
    private static let previewMagnify: Double = 1.7

    /// 자막 한 줄.
    ///
    /// **크기와 줄임은 완성될 영상 기준으로 계산한 뒤 미리보기 크기로 옮긴다.**
    /// 미리보기 카드 폭으로 직접 계산하면, 읽히게 하려고 키운 글자 때문에 폭이 모자란 것으로
    /// 판정돼 영상에서는 멀쩡한 이름이 여기서만 "푸른마을푸르지오…"처럼 잘린다.
    /// 그러면 유저는 "안 되는 건가?" 하게 된다 — 실제로 그렇게 보였다.
    private func previewLine(_ text: String, videoWanted: Double, cardWidth: Double,
                             color: Color) -> some View {
        let fitted = VlogSubtitleFit.fit(text, wanted: videoWanted, frameWidth: videoWidth)
        let shown = fitted.size * (cardWidth / videoWidth) * Self.previewMagnify
        return Text(fitted.text)
            .font(.custom(selectedFont.postScriptName, size: shown))
            .foregroundColor(color)
            .shadow(color: .black.opacity(0.35), radius: 2, x: 2, y: 2)
            .lineLimit(1)
            // 확대해 그리다 카드를 넘칠 수 있다 — 조용히 줄여서 흡수한다.
            // (영상에서의 줄임 판정은 이미 위에서 끝났으므로 여기서 잘릴 일은 없다)
            .minimumScaleFactor(0.5)
    }

    private func fieldsPill(_ fields: VlogSubtitleFields) -> some View {
        let isOn = selectedFields == fields
        return Button {
            vlogFields = fields.rawValue
            Haptics.light()
        } label: {
            Text(fields.displayName)
                .font(.tte(14, isOn ? .bold : .regular))
                .foregroundColor(isOn ? .white : .white.opacity(0.7))
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(isOn ? 0.14 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isOn ? Color.tteOrange : Color.clear, lineWidth: 1.5)
                )
        }
    }

    private func colorDot(_ c: VlogSubtitleColor) -> some View {
        let isOn = selectedColor == c
        return Button {
            vlogColor = c.rawValue
            Haptics.light()
        } label: {
            Circle()
                .fill(c.color)
                .frame(width: 34, height: 34)
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                        .padding(-4)
                        .opacity(isOn ? 1 : 0)
                )
        }
        .accessibilityLabel(c.displayName)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// 캡션 입력을 한 곳으로 모은 바인딩.
    ///
    /// 자르기와 햅틱을 `onChange`에 두면, 길이를 잘라 값을 되돌려 쓸 때 다시 불려
    /// 한 번의 입력에 햅틱이 두 번 울린다. setter 한 곳으로 모으면 그럴 일이 없다.
    private func sizePill(_ scale: VlogFontScale) -> some View {
        let isOn = selectedScale == scale
        return Button {
            vlogFontScale = scale.rawValue
            Haptics.light()
        } label: {
            Text(scale.displayName)
                .font(.tte(15, isOn ? .bold : .regular))
                .foregroundColor(isOn ? .white : .white.opacity(0.7))
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(isOn ? 0.14 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isOn ? Color.tteOrange : Color.clear, lineWidth: 1.5)
                )
        }
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

                // 이어받기는 이미 되는데 유저가 모른다. 느린 회선에서 이 한 문장이
                // "멈춘 건가?" 하는 불안을 없애준다 — 예상 시간보다 이게 더 큰 안심이다.
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.icloud")
                        .font(.tte(12))
                    Text(L("vlog.keepsRunning"))
                        .font(.tte(13))
                        .multilineTextAlignment(.center)
                }
                .foregroundColor(.white.opacity(0.55))
                .padding(.horizontal, 40)

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
                        shareRoomIds: shareVlogPref ? Array(shareRoomIds) : [],
                        style: subtitleStyle,
                        onProgress: { p, stage in
                            progress = p
                            stageText = stage
                        }
                    )
                    mainURL = result.main
                    extraURLs = result.extras.map(\.url)
                    dlog("[VlogGeneration] 서버 합성 성공 (추가 포맷: \(result.extras.map(\.format)))")
                } catch {
                    if Task.isCancelled || error is CancellationError { return }

                    // 서버가 아직 이 잡을 붙잡고 있다면 로컬로 도망치지 않는다 —
                    // 지금 폴백하면 음악·워터마크 없는 열화본이 저장되고, 서버는 헛일을 한다.
                    // 대신 이어받기를 안내해 다음 시도에서 완성본을 그대로 받아오게 한다.
                    let definitive = (error as? VlogServerService.ServerVlogError)?.isDefinitive ?? false
                    let pending = await VlogServerService.shared.hasPendingJob(sessionId: sessionId)
                    if !definitive, pending {
                        dlog("[VlogGeneration] 서버 렌더링 진행 중 — 이어받기 안내: \(error.localizedDescription)")
                        canResume = true
                        errorMessage = L("vlog.error.serverBusy")
                        phase = .error
                        return
                    }

                    // 서버가 확정 실패했거나 애초에 잡이 만들어지지 않았다 → 로컬 합성으로 결과는 보장
                    dlog("[VlogGeneration] 서버 합성 실패 → 로컬 폴백: \(error.localizedDescription)")
                    didFallback = true
                    stageText = L("vlog.creating")
                    progress = 0.05
                    mainURL = try await vlogService.generateVlog(
                        course: course, sessionId: sessionId,
                        style: subtitleStyle,
                        watermark: !pro.isPro,   // 결제로 지운 워터마크가 폴백에서 되살아나면 안 된다
                        onProgress: { p in Task { @MainActor in progress = p } }
                    )
                }
            } else {
                didFallback = forceLocal
                mainURL = try await vlogService.generateVlog(
                    course: course, sessionId: sessionId,
                    style: subtitleStyle,
                    watermark: !pro.isPro,
                    onProgress: { p in Task { @MainActor in progress = p } }
                )
            }

            dlog("[VlogGeneration] url=\(mainURL.path) exists=\(FileManager.default.fileExists(atPath: mainURL.path))")
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
            // 게스트가 첫 브이로그를 손에 넣었다 — 서버든 로컬이든 한 번은 한 번이다
            if Auth.auth().currentUser?.isAnonymous == true {
                GuestVlogQuota.recordCompletion()
            }
            onVlogCompleted?()
            Haptics.success()
            // 발자취 적재 — 브이로그가 완성된 여행만 지도에 칠해진다 (실패해도 흐름 방해 없음).
            // 발자취는 계정 기능이라 게스트(익명)는 제외한다 — 규칙이 막으므로 거부만 쌓인다.
            if let user = Auth.auth().currentUser, !user.isAnonymous {
                let uid = user.uid
                let recordCourse = course
                let recordSessionId = sessionId
                Task {
                    await FootprintService.shared.record(
                        course: recordCourse, sessionId: recordSessionId, userId: uid)
                }
            }
            phase = .preview
            // 튜토리얼: 첫 브이로그 완성 → 축하 카드
            tutorial.advance(to: .celebrate)
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

                    Button(L("vlog.goBack")) {
                        tutorial.handleVlogExit()
                        dismiss()
                    }
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
    /// 방 공유가 예정돼 있었는데 로컬 폴백이라 서버가 공유하지 못한 경우 — 기대 불일치를 알린다
    let shareMissed: Bool
    let onDismiss: () -> Void

    @State private var player: AVPlayer
    @State private var showShareSheet = false
    @State private var thumbPickerItem: PhotosPickerItem?
    @State private var thumbState: ThumbState = .idle
    @State private var showAuthFromPreview = false

    /// 게스트가 첫 브이로그를 막 손에 넣은 상태인가 — 회원가입을 권하기 가장 좋은 순간
    private var isGuest: Bool { Auth.auth().currentUser?.isAnonymous == true }

    private enum ThumbState { case idle, uploading, done, failed }

    init(vlogURL: URL, thumbnailCourseId: String? = nil,
         savedFormatsCount: Int = 1, fallbackNotice: Bool = false,
         shareMissed: Bool = false,
         onDismiss: @escaping () -> Void) {
        self.vlogURL = vlogURL
        self.thumbnailCourseId = thumbnailCourseId
        self.savedFormatsCount = savedFormatsCount
        self.fallbackNotice = fallbackNotice
        self.shareMissed = shareMissed
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
                        VStack(spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: "wifi.exclamationmark")
                                    .font(.tte(11))
                                    .foregroundColor(.yellow)
                                Text(L("vlog.done.fallbackNotice"))
                                    .font(.tte(11))
                                    .foregroundColor(.white.opacity(0.8))
                                    .multilineTextAlignment(.center)
                            }
                            if shareMissed {
                                Text(L("vlog.done.fallbackNoShare"))
                                    .font(.tte(11))
                                    .foregroundColor(.white.opacity(0.8))
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 14).fill(Color.yellow.opacity(0.12))
                        )
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

                    // 결과물을 손에 쥔 지금이 가입을 권하기 가장 좋은 순간이다.
                    // 예전엔 '두 번째 브이로그를 만들려 할 때'만 권했는데, 첫 브이로그를 받고
                    // 앱을 닫은 사람은 그 화면을 영영 보지 못했다 — 정작 붙잡아야 할 쪽이다.
                    // 막지 않는다. 영상은 이미 앨범에 저장됐고, 여기서는 이어가자고 권하기만 한다.
                    if isGuest { signUpInvite }

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

    private var signUpInvite: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image("tteoni-thumbsup")
                    .resizable().scaledToFit()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("vlog.invite.title"))
                        .font(.tte(15, .bold))
                        .foregroundColor(.white)
                    Text(L("vlog.invite.message"))
                        .font(.tte(13))
                        .foregroundColor(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Button {
                Haptics.light()
                showAuthFromPreview = true
            } label: {
                Text(L("vlog.invite.signUp"))
                    .font(.tte(15, .bold))
                    .foregroundColor(.tteOrange)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 13).fill(Color.white))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
        .fullScreenCover(isPresented: $showAuthFromPreview) { AuthView() }
    }

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
