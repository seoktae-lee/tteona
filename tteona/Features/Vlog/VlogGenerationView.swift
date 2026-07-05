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

    @State private var phase: Phase = .chooseFormat
    @State private var vlogURL: URL?
    @State private var errorMessage: String?
    @State private var progress: Double = 0
    @State private var stageText = "추억을 만들고 있어요..."
    @State private var savedFormatsCount = 1
    @State private var selectedFormats: Set<String> = []   // 기본 포맷 외 추가 선택
    @State private var didGenerate = false

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
                                savedFormatsCount: savedFormatsCount) {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        onDismissToHome?()
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
                Text("어떤 포맷으로 만들까요?")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Text("촬영 방향에 딱 맞는 포맷은 기본으로 포함돼요")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.top, 6)

                VStack(spacing: 12) {
                    formatRow(icon: "iphone", title: "릴스 · 세로", ratio: "9:16",
                              subtitle: baseFormat == "reels" ? "기본 포함 · 촬영 방향 그대로" : "블러 배경으로 변환",
                              key: "reels",
                              badge: baseFormat == "reels" ? "세로 촬영 특화" : nil)
                    formatRow(icon: "play.rectangle.fill", title: "유튜브 · 가로", ratio: "16:9",
                              subtitle: baseFormat == "youtube" ? "기본 포함 · 촬영 방향 그대로" : "블러 배경으로 변환",
                              key: "youtube",
                              badge: baseFormat == "youtube" ? "가로 촬영 특화" : nil)
                    formatRow(icon: "square.fill", title: "인스타 · 정방형", ratio: "1:1",
                              subtitle: "여백 없이 꽉 차게 잘라서 변환",
                              key: "insta", badge: nil)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)

                Spacer()

                Button {
                    phase = .chooseBgm
                } label: {
                    Text(selectedFormats.isEmpty ? "Vlog 만들기" : "\(selectedFormats.count + 1)가지 버전으로 만들기")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }
                .padding(.horizontal, 24)

                Button("닫기") { dismiss() }
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.top, 14)
                    .padding(.bottom, 36)
            }
        }
        .task { await detectShotOrientation() }
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
        let isOn = fixed || selectedFormats.contains(key)
        return Button {
            guard !fixed else { return }
            if selectedFormats.contains(key) { selectedFormats.remove(key) }
            else { selectedFormats.insert(key) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(isOn ? .tteOrange : .white.opacity(0.5))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                        Text(ratio)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.tteOrange)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.tteOrange.opacity(0.18)))
                        if let badge {
                            HStack(spacing: 3) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 9, weight: .bold))
                                Text(badge)
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.tteOrange))
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                }
                Spacer()
                Image(systemName: fixed ? "checkmark.circle.fill"
                                        : (isOn ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: 22))
                    .foregroundColor(isOn ? .tteOrange : .white.opacity(0.3))
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
                Text("어떤 음악과 함께할까요?")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Text("미리 들어보고 골라도, 그냥 맡겨도 좋아요")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.top, 6)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        bgmRow(id: "auto", name: "자동 추천", mood: course.tag.rawValue,
                               subtitle: "여행 태그에 어울리는 음악을 골라드려요", previewURL: nil)
                        bgmRow(id: "none", name: "음악 없이", mood: nil,
                               subtitle: "현장의 소리만 그대로 담아요", previewURL: nil)
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
                    Text("Vlog 만들기")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }
                .padding(.horizontal, 24)

                Button("이전으로") {
                    stopBgmPreview()
                    phase = .chooseFormat
                }
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
                .padding(.top, 14)
                .padding(.bottom, 36)
            }
        }
        .task { await loadBgmTracks() }
        .onDisappear { stopBgmPreview() }
    }

    private func bgmRow(id: String, name: String, mood: String?,
                        subtitle: String?, previewURL: URL?) -> some View {
        let isOn = selectedBgm == id
        return Button {
            selectedBgm = id
        } label: {
            HStack(spacing: 14) {
                Image(systemName: id == "auto" ? "wand.and.stars"
                                : (id == "none" ? "speaker.slash" : "music.note"))
                    .font(.system(size: 18))
                    .foregroundColor(isOn ? .tteOrange : .white.opacity(0.5))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if let mood {
                            Text(mood)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.tteOrange)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Color.tteOrange.opacity(0.18)))
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
                Spacer()
                if let previewURL {
                    Button {
                        toggleBgmPreview(id: id, url: previewURL)
                    } label: {
                        Image(systemName: playingTrackId == id ? "pause.circle.fill" : "play.circle")
                            .font(.system(size: 26))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isOn ? .tteOrange : .white.opacity(0.3))
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
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(spacing: 8) {
                    Text(stageText)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .animation(.easeInOut(duration: 0.2), value: stageText)
                    Text(course.courseName)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                }

                Spacer()
            }
        }
        .task {
            guard !didGenerate else { return }
            didGenerate = true
            do {
                var mainURL: URL
                var extraURLs: [URL] = []
                if let uid = Auth.auth().currentUser?.uid {
                    do {
                        // 1순위: 서버(WAS 8코어) 합성 — 폰 부담 없이 빠르고 BGM·멀티포맷 포함
                        let result = try await VlogServerService.shared.generate(
                            course: course, sessionId: sessionId, userId: uid,
                            formats: Array(selectedFormats), bgm: selectedBgm,
                            onProgress: { p, stage in
                                progress = p
                                stageText = stage
                            }
                        )
                        mainURL = result.main
                        extraURLs = result.extras.map(\.url)
                        print("[VlogGeneration] 서버 합성 성공 (추가 포맷: \(result.extras.map(\.format)))")
                    } catch {
                        // 서버 실패(네트워크·서버 다운 등) → 기존 로컬 합성 폴백으로 항상 동작 보장
                        print("[VlogGeneration] 서버 합성 실패 → 로컬 폴백: \(error.localizedDescription)")
                        await MainActor.run {
                            stageText = "추억을 만들고 있어요..."
                            progress = 0.05
                        }
                        mainURL = try await vlogService.generateVlog(
                            course: course, sessionId: sessionId,
                            onProgress: { p in Task { @MainActor in progress = p } }
                        )
                    }
                } else {
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
                            userInfo: [NSLocalizedDescriptionKey: "앨범 저장을 위해 사진 권한이 필요해요.\n설정에서 사진 접근을 허용해주세요."]
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
                phase = .preview
            } catch {
                errorMessage = error.localizedDescription
                phase = .error
            }
        }
    }

    // MARK: - 에러
    private var errorView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48)).foregroundColor(.red)
                Text("Vlog 생성에 실패했어요")
                    .font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
                if let msg = errorMessage {
                    Text(msg)
                        .font(.system(size: 13)).foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                }
                Button("돌아가기") { dismiss() }
                    .buttonStyle(TteButtonStyle()).padding(.horizontal, 40)
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
    let onDismiss: () -> Void

    @State private var player: AVPlayer
    @State private var showShareSheet = false
    @State private var thumbPickerItem: PhotosPickerItem?
    @State private var thumbState: ThumbState = .idle

    private enum ThumbState { case idle, uploading, done, failed }

    init(vlogURL: URL, thumbnailCourseId: String? = nil,
         savedFormatsCount: Int = 1, onDismiss: @escaping () -> Void) {
        self.vlogURL = vlogURL
        self.thumbnailCourseId = thumbnailCourseId
        self.savedFormatsCount = savedFormatsCount
        self.onDismiss = onDismiss
        _player = State(initialValue: AVPlayer(url: vlogURL))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.height * (thumbnailCourseId == nil ? 0.65 : 0.58))
                    .onAppear { player.play() }

                VStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text(savedFormatsCount > 1 ? "\(savedFormatsCount)가지 버전이 앨범에 저장됨" : "앨범에 저장됨")
                            .font(.system(size: 14)).foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.top, 20)

                    if let courseId = thumbnailCourseId {
                        thumbnailButton(courseId: courseId)
                            .padding(.horizontal, 24)
                    }

                    Button {
                        showShareSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                            Text("공유하기")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.tteOrange))
                    }
                    .padding(.horizontal, 24)

                    Button("홈으로 돌아가기") { onDismiss() }
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.bottom, 40)
                }
                .background(Color.black)
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
                    Text("탐색탭에 보여질 썸네일 고르기")
                case .uploading:
                    ProgressView().tint(.white).scaleEffect(0.8)
                    Text("썸네일 업로드 중...")
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("썸네일 설정 완료 · 변경하기")
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                    Text("업로드 실패 · 다시 시도")
                }
            }
            .font(.system(size: 15, weight: .semibold))
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
            .font(.system(size: 16, weight: .semibold))
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
