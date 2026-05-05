import SwiftUI
import AVKit

struct PostShotMemoView: View {
    let clipURL: URL
    let place: Place
    let sessionId: String
    let onDone: () -> Void

    @State private var memo: String = ""
    @State private var player: AVPlayer
    @FocusState private var focused: Bool

    init(clipURL: URL, place: Place, sessionId: String, onDone: @escaping () -> Void) {
        self.clipURL = clipURL
        self.place = place
        self.sessionId = sessionId
        self.onDone = onDone
        _player = State(initialValue: AVPlayer(url: clipURL))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                // 영상 미리보기
                VideoPlayer(player: player)
                    .frame(height: UIScreen.main.bounds.height * 0.55)
                    .onAppear { player.play() }

                VStack(spacing: 16) {
                    Text(place.placeName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 20)

                    // 메모 입력
                    ZStack(alignment: .topLeading) {
                        if memo.isEmpty {
                            Text("이 순간을 한 줄로 기록해보세요...")
                                .font(.system(size: 15))
                                .foregroundColor(.white.opacity(0.3))
                                .padding(.horizontal, 4)
                                .padding(.top, 2)
                        }
                        TextEditor(text: $memo)
                            .font(.system(size: 15))
                            .foregroundColor(.white)
                            .scrollContentBackground(.hidden)
                            .focused($focused)
                            .frame(minHeight: 60, maxHeight: 80)
                            .toolbar {
                                ToolbarItemGroup(placement: .keyboard) {
                                    Spacer()
                                    Button("완료") { focused = false }
                                        .foregroundColor(.tteOrange)
                                        .fontWeight(.semibold)
                                }
                            }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                    .padding(.horizontal, 24)

                    // 저장 버튼
                    Button {
                        saveMemoAndDone()
                    } label: {
                        Text(memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "메모 없이 저장" : "저장하기")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.tteOrange))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
                .background(Color.black)
            }
        }
        .onTapGesture { focused = false }
    }

    private func saveMemoAndDone() {
        let text = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let memoURL = memoFileURL(place: place, sessionId: sessionId)
            try? text.write(to: memoURL, atomically: true, encoding: .utf8)
        }
        onDone()
    }

    private func memoFileURL(place: Place, sessionId: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(
            "Tteona/Sessions/\(sessionId)/\(place.order)_\(place.placeName.replacingOccurrences(of: " ", with: "_"))_memo.txt"
        )
    }
}
