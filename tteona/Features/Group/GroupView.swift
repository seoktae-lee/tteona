import SwiftUI

// MARK: - Room Card
struct RoomCard: View {
    let room: Room
    var hasNewFeed: Bool = false

    // 방마다 고정되는 아바타 그라데이션 (roomId 해시 기반)
    private static let avatarGradients: [[Color]] = [
        [Color.tteOrange, Color(red: 1.0, green: 0.62, blue: 0.30)],
        [Color(red: 0.98, green: 0.45, blue: 0.45), Color(red: 1.0, green: 0.65, blue: 0.45)],
        [Color(red: 0.35, green: 0.65, blue: 0.95), Color(red: 0.45, green: 0.82, blue: 0.90)],
        [Color(red: 0.55, green: 0.45, blue: 0.95), Color(red: 0.75, green: 0.55, blue: 0.98)],
        [Color(red: 0.25, green: 0.75, blue: 0.62), Color(red: 0.50, green: 0.87, blue: 0.60)],
        [Color(red: 0.95, green: 0.55, blue: 0.75), Color(red: 1.0, green: 0.72, blue: 0.62)],
    ]

    private var gradient: [Color] {
        let hash = room.roomId.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.avatarGradients[abs(hash) % Self.avatarGradients.count]
    }

    private var initial: String {
        String(room.name.trimmingCharacters(in: .whitespaces).prefix(1))
    }

    var body: some View {
        HStack(spacing: 14) {
            // 그라데이션 아바타 + 방 이름 첫 글자
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(LinearGradient(colors: gradient,
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 54, height: 54)
                Text(initial)
                    .font(.tte(22, .bold))
                    .foregroundColor(.white)
            }
            .overlay(alignment: .topTrailing) {
                if hasNewFeed {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.tteBackground, lineWidth: 2))
                        .offset(x: 3, y: -3)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(room.name)
                        .font(.tte(17, .semibold))
                        .foregroundColor(.tteDarkGray)
                        .lineLimit(1)
                    if hasNewFeed {
                        Text("NEW")
                            .font(.tte(9, .heavy))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2.5)
                            .background(Capsule().fill(Color.tteOrange))
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.tte(10))
                    Text("멤버 \(room.memberIds.count)명")
                        .font(.tte(12, .medium))
                }
                .foregroundColor(.tteMediumGray)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.tte(13, .semibold))
                .foregroundColor(.tteMediumGray.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(hasNewFeed ? Color.tteOrange.opacity(0.35) : Color.clear, lineWidth: 1.2)
        )
    }

}

// MARK: - Create Room View
struct CreateRoomView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @Environment(\.dismiss) private var dismiss
    @State private var roomName = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("그룹 이름")
                        .font(.tte(14, .medium))
                        .foregroundColor(.tteMediumGray)
                    TextField("예: 제주 여행 친구들", text: $roomName)
                        .font(.tte(17))
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                if let error = errorMessage {
                    Text(error)
                        .font(.tte(14))
                        .foregroundColor(.red)
                        .padding(.horizontal, 20)
                }

                Spacer()

                Button {
                    Task { await create() }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("방 만들기")
                                .font(.tte(17, .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(roomName.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray.opacity(0.4) : Color.tteOrange)
                    )
                }
                .disabled(roomName.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
            }
            .navigationTitle("그룹 만들기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") { dismiss() }
                        .foregroundColor(.tteDarkGray)
                }
            }
        }
    }

    private func create() async {
        guard let uid = authService.currentUser?.uid else { return }
        let nickname = userService.currentUser?.nickname ?? "멤버"
        isLoading = true
        do {
            _ = try await roomService.createRoom(name: roomName.trimmingCharacters(in: .whitespaces), userId: uid, nickname: nickname)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Join Room View
struct JoinRoomView: View {
    var initialCode: String = ""
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @Environment(\.dismiss) private var dismiss
    @State private var inviteCode = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    // 화면을 닫았다 열어도 잠금이 리셋되지 않도록 영속 저장
    @AppStorage("joinRoomFailCount") private var failCount = 0
    @AppStorage("joinRoomLockUntil") private var lockUntilTimestamp: Double = 0
    @State private var cooldownRemaining = 0
    @State private var cooldownTimer: Timer? = nil

    private let maxAttempts = 5
    private let lockSeconds = 3600

    private var lockUntil: Date? {
        lockUntilTimestamp > 0 ? Date(timeIntervalSince1970: lockUntilTimestamp) : nil
    }
    private var isLocked: Bool { lockUntil.map { Date() < $0 } ?? false }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("초대 코드 6자리를 입력하세요")
                        .font(.tte(14, .medium))
                        .foregroundColor(.tteMediumGray)

                    TextField("예: A3F7K2", text: $inviteCode)
                        .font(.tte(28, .bold))
                        .multilineTextAlignment(.center)
                        .kerning(6)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .onChange(of: inviteCode) { _, val in
                            inviteCode = String(val.uppercased().prefix(6))
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                if isLocked {
                    Text("코드 입력 횟수를 초과했어요.\n\(cooldownRemaining / 60)분 후 다시 시도해주세요.")
                        .font(.tte(14))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                } else if let error = errorMessage {
                    VStack(spacing: 4) {
                        Text(error)
                            .font(.tte(14))
                            .foregroundColor(.red)
                        Text("\(failCount)/\(maxAttempts)회 실패")
                            .font(.tte(12))
                            .foregroundColor(.tteMediumGray)
                    }
                    .padding(.horizontal, 20)
                }

                Spacer()

                Button {
                    Task { await join() }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("참여하기")
                                .font(.tte(17, .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(inviteCode.count < 6 || isLocked ? Color.gray.opacity(0.4) : Color.tteOrange)
                    )
                }
                .disabled(inviteCode.count < 6 || isLoading || isLocked)
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
            }
            .navigationTitle("코드로 참여")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") { dismiss() }
                        .foregroundColor(.tteDarkGray)
                }
            }
            .onAppear {
                if !initialCode.isEmpty {
                    inviteCode = String(initialCode.uppercased().prefix(6))
                }
                // 잠금 상태 복원 (만료됐으면 리셋)
                if let until = lockUntil {
                    if Date() < until {
                        cooldownRemaining = Int(until.timeIntervalSinceNow)
                        startCooldownTimer()
                    } else {
                        lockUntilTimestamp = 0
                        failCount = 0
                    }
                }
            }
            .onDisappear {
                cooldownTimer?.invalidate()
                cooldownTimer = nil
            }
        }
    }

    private func join() async {
        guard !isLocked, let uid = authService.currentUser?.uid else { return }
        let nickname = userService.currentUser?.nickname ?? "멤버"
        isLoading = true
        errorMessage = nil
        do {
            _ = try await roomService.joinRoom(inviteCode: inviteCode, userId: uid, nickname: nickname)
            failCount = 0
            lockUntilTimestamp = 0
            dismiss()
        } catch {
            failCount += 1
            if failCount >= maxAttempts {
                lockUntilTimestamp = Date().addingTimeInterval(TimeInterval(lockSeconds)).timeIntervalSince1970
                cooldownRemaining = lockSeconds
                startCooldownTimer()
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func startCooldownTimer() {
        cooldownTimer?.invalidate()
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            cooldownRemaining -= 1
            if cooldownRemaining <= 0 {
                cooldownTimer?.invalidate()
                cooldownTimer = nil
                lockUntilTimestamp = 0
                failCount = 0
            }
        }
    }
}
