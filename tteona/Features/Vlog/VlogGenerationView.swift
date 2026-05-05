import SwiftUI
import AVKit

struct VlogGenerationView: View {
    let course: Course
    let sessionId: String
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .generating
    @State private var vlogURL: URL?
    @State private var errorMessage: String?

    private let vlogService = VlogService()

    enum Phase { case generating, preview, error }

    var body: some View {
        switch phase {
        case .generating:
            generatingView
        case .preview:
            if let url = vlogURL {
                VlogPreviewView(vlogURL: url) { dismiss() }
            }
        case .error:
            errorView
        }
    }

    // MARK: - Generating
    private var generatingView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                ProgressView()
                    .tint(.tteOrange)
                    .scaleEffect(1.5)

                Text("추억을 만들고 있어요...")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                Text(course.courseName)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .task {
            do {
                let url = try await vlogService.generateVlog(course: course, sessionId: sessionId)
                try await vlogService.saveToPhotoLibrary(url: url)
                vlogURL = url
                phase = .preview
            } catch {
                errorMessage = error.localizedDescription
                phase = .error
            }
        }
    }

    // MARK: - Error
    private var errorView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.red)
                Text("Vlog 생성에 실패했어요")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                if let msg = errorMessage {
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Button("돌아가기") { dismiss() }
                    .buttonStyle(TteButtonStyle())
                    .padding(.horizontal, 40)
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
                // 비디오 플레이어
                VideoPlayer(player: player)
                    .frame(maxHeight: UIScreen.main.bounds.height * 0.65)
                    .onAppear { player.play() }

                VStack(spacing: 20) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("앨범에 저장됨")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.8))
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
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.tteOrange)
                        )
                    }
                    .padding(.horizontal, 24)

                    Button("홈으로 돌아가기") {
                        onDismiss()
                    }
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

// MARK: - Share Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Reusable Button Style
struct TteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.tteOrange.opacity(configuration.isPressed ? 0.7 : 1.0))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
