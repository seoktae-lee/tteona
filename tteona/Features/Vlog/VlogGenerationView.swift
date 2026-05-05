import SwiftUI
import AVKit

enum VlogOrientation {
    case portrait   // 1080 x 1920 (세로)
    case landscape  // 1920 x 1080 (가로)

    var size: CGSize {
        switch self {
        case .portrait:  return CGSize(width: 1080, height: 1920)
        case .landscape: return CGSize(width: 1920, height: 1080)
        }
    }
}

struct VlogGenerationView: View {
    let course: Course
    let sessionId: String
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .selectOrientation
    @State private var orientation: VlogOrientation = .portrait
    @State private var vlogURL: URL?
    @State private var errorMessage: String?
    @State private var progress: Double = 0

    private let vlogService = VlogService()

    enum Phase { case selectOrientation, generating, preview, error }

    var body: some View {
        switch phase {
        case .selectOrientation: orientationSelectView
        case .generating:        generatingView
        case .preview:
            if let url = vlogURL {
                VlogPreviewView(vlogURL: url, orientation: orientation) { dismiss() }
            }
        case .error: errorView
        }
    }

    // MARK: - 방향 선택
    private var orientationSelectView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 8) {
                    Text("✈️")
                        .font(.system(size: 52))
                    Text("Vlog 만들기")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                    Text(course.courseName)
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.6))
                }

                VStack(spacing: 14) {
                    Text("영상 방향을 선택하세요")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))

                    HStack(spacing: 16) {
                        OrientationCard(
                            title: "세로",
                            subtitle: "9:16",
                            icon: "iphone",
                            isSelected: orientation == .portrait
                        ) { orientation = .portrait }

                        OrientationCard(
                            title: "가로",
                            subtitle: "16:9",
                            icon: "iphone.landscape",
                            isSelected: orientation == .landscape
                        ) { orientation = .landscape }
                    }
                    .padding(.horizontal, 32)
                }

                Spacer()

                Button {
                    phase = .generating
                } label: {
                    Text("Vlog 생성 시작")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.tteOrange))
                }
                .padding(.horizontal, 32)

                Button("취소") { dismiss() }
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.bottom, 48)
            }
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
            do {
                let url = try await vlogService.generateVlog(
                    course: course,
                    sessionId: sessionId,
                    orientation: orientation,
                    onProgress: { p in
                        Task { @MainActor in progress = p }
                    }
                )
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

// MARK: - 방향 선택 카드
struct OrientationCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 36))
                    .foregroundColor(isSelected ? .tteOrange : .white.opacity(0.5))
                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isSelected ? .white : .white.opacity(0.6))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? .tteOrange : .white.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? Color.tteOrange.opacity(0.15) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(isSelected ? Color.tteOrange : Color.white.opacity(0.1), lineWidth: 1.5)
                    )
            )
        }
    }
}

// MARK: - Vlog Preview
struct VlogPreviewView: View {
    let vlogURL: URL
    let orientation: VlogOrientation
    let onDismiss: () -> Void

    @State private var player: AVPlayer
    @State private var showShareSheet = false

    init(vlogURL: URL, orientation: VlogOrientation, onDismiss: @escaping () -> Void) {
        self.vlogURL = vlogURL
        self.orientation = orientation
        self.onDismiss = onDismiss
        _player = State(initialValue: AVPlayer(url: vlogURL))
    }

    private var playerHeight: CGFloat {
        let screenW = UIScreen.main.bounds.width
        let screenH = UIScreen.main.bounds.height
        switch orientation {
        case .portrait:  return screenH * 0.65
        case .landscape: return screenW * (9.0 / 16.0)
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity)
                    .frame(height: playerHeight)
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
