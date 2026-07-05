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
    @State private var selectedFormats: Set<String> = []   // "youtube", "insta"
    @State private var didGenerate = false

    private let vlogService = VlogService()

    enum Phase { case chooseFormat, generating, preview, error }

    var body: some View {
        switch phase {
        case .chooseFormat: chooseFormatView
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
    private var chooseFormatView: some View {
        ZStack {
            VlogAuroraBackground()
            VStack(spacing: 0) {
                Spacer()
                Text("어떤 포맷으로 만들까요?")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Text("촬영 방향 그대로의 기본 영상은 항상 포함돼요")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.top, 6)

                VStack(spacing: 12) {
                    formatRow(icon: "iphone", title: "릴스 · 세로", ratio: "9:16",
                              subtitle: "기본 포함", fixed: true, key: nil)
                    formatRow(icon: "play.rectangle.fill", title: "유튜브 · 가로", ratio: "16:9",
                              subtitle: "블러 배경으로 변환", fixed: false, key: "youtube")
                    formatRow(icon: "square.fill", title: "인스타 · 정방형", ratio: "1:1",
                              subtitle: "블러 배경으로 변환", fixed: false, key: "insta")
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)

                Spacer()

                Button {
                    phase = .generating
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
    }

    private func formatRow(icon: String, title: String, ratio: String,
                           subtitle: String, fixed: Bool, key: String?) -> some View {
        let isOn = fixed || (key.map { selectedFormats.contains($0) } ?? false)
        return Button {
            guard let key else { return }
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
                            formats: Array(selectedFormats),
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
