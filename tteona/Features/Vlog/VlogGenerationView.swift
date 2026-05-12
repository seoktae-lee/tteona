import SwiftUI
import AVKit
import Photos

struct VlogGenerationView: View {
    let course: Course
    let sessionId: String
    var onDismissToHome: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .generating
    @State private var vlogURL: URL?
    @State private var errorMessage: String?
    @State private var progress: Double = 0
    @State private var didGenerate = false

    private let vlogService = VlogService()

    enum Phase { case generating, preview, error }

    var body: some View {
        switch phase {
        case .generating: generatingView
        case .preview:
            if let url = vlogURL {
                VlogPreviewView(vlogURL: url) {
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
                    Text("추억을 만들고 있어요...")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
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
                let url = try await vlogService.generateVlog(
                    course: course,
                    sessionId: sessionId,
                    onProgress: { p in
                        Task { @MainActor in progress = p }
                    }
                )
                print("[VlogGeneration] url=\(url.path) exists=\(FileManager.default.fileExists(atPath: url.path))")
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
                try await vlogService.saveToPhotoLibrary(url: url)
                vlogURL = url
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
    let onDismiss: () -> Void

    @State private var player: AVPlayer
    @State private var showShareSheet = false

    init(vlogURL: URL, onDismiss: @escaping () -> Void) {
        self.vlogURL = vlogURL
        self.onDismiss = onDismiss
        _player = State(initialValue: AVPlayer(url: vlogURL))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.height * 0.65)
                    .onAppear { player.play() }

                VStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("앨범에 저장됨")
                            .font(.system(size: 14)).foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.top, 20)

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
