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

    @State private var phase: Phase = .generating
    @State private var vlogURL: URL?
    @State private var errorMessage: String?
    @State private var progress: Double = 0
    @State private var stageText = "추억을 만들고 있어요..."
    @State private var savedBothFormats = false
    @State private var didGenerate = false

    private let vlogService = VlogService()

    enum Phase { case generating, preview, error }

    var body: some View {
        switch phase {
        case .generating: generatingView
        case .preview:
            if let url = vlogURL {
                VlogPreviewView(vlogURL: url, thumbnailCourseId: thumbnailCourseId,
                                savedBothFormats: savedBothFormats) {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        onDismissToHome?()
                    }
                }
            }
        case .error: errorView
        }
    }

    // MARK: - 생성 중
    private var generatingView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()

                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 6)
                        .frame(width: 100, height: 100)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.tteOrange, style: StrokeStyle(lineWidth: 6, lineCap: .round))
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
                var altURL: URL?
                if let uid = Auth.auth().currentUser?.uid {
                    do {
                        // 1순위: 서버(WAS 8코어) 합성 — 폰 부담 없이 빠르고 BGM·멀티포맷 포함
                        let result = try await VlogServerService.shared.generate(
                            course: course, sessionId: sessionId, userId: uid,
                            onProgress: { p, stage in
                                progress = p
                                stageText = stage
                            }
                        )
                        mainURL = result.main
                        altURL = result.alt
                        print("[VlogGeneration] 서버 합성 성공 (멀티포맷: \(result.alt != nil))")
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
                if let altURL {
                    // 릴스·유튜브용 반대 방향 버전도 함께 저장 (실패해도 무시)
                    try? await vlogService.saveToPhotoLibrary(url: altURL)
                    savedBothFormats = true
                }
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

// MARK: - Vlog Preview
struct VlogPreviewView: View {
    let vlogURL: URL
    let thumbnailCourseId: String?
    let savedBothFormats: Bool
    let onDismiss: () -> Void

    @State private var player: AVPlayer
    @State private var showShareSheet = false
    @State private var thumbPickerItem: PhotosPickerItem?
    @State private var thumbState: ThumbState = .idle

    private enum ThumbState { case idle, uploading, done, failed }

    init(vlogURL: URL, thumbnailCourseId: String? = nil,
         savedBothFormats: Bool = false, onDismiss: @escaping () -> Void) {
        self.vlogURL = vlogURL
        self.thumbnailCourseId = thumbnailCourseId
        self.savedBothFormats = savedBothFormats
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
                        Text(savedBothFormats ? "세로·가로 2가지 버전이 앨범에 저장됨" : "앨범에 저장됨")
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
