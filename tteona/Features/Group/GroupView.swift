import SwiftUI

// MARK: - Room Card
struct RoomCard: View {
    let room: Room
    var hasNewFeed: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(room.name)
                    .font(.custom("GowunBatang-Regular", size: 22))
                    .foregroundColor(.tteDarkGray)
                HStack(spacing: 4) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.tteMediumGray)
                    Text("\(room.memberIds.count)명")
                        .font(.system(size: 13))
                        .foregroundColor(.tteMediumGray)
                }
            }
            Spacer()
            if hasNewFeed {
                Circle()
                    .fill(Color.tteOrange)
                    .frame(width: 10, height: 10)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 14))
                .foregroundColor(.tteMediumGray)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemBackground)))
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
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.tteMediumGray)
                    TextField("예: 제주 여행 친구들", text: $roomName)
                        .font(.system(size: 17))
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 14))
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
                                .font(.system(size: 17, weight: .semibold))
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
    @State private var failCount = 0
    @State private var lockUntil: Date? = nil
    @State private var cooldownRemaining = 0
    @State private var cooldownTimer: Timer? = nil

    private let maxAttempts = 5
    private let lockSeconds = 3600

    private var isLocked: Bool { lockUntil.map { Date() < $0 } ?? false }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("초대 코드 6자리를 입력하세요")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.tteMediumGray)

                    TextField("예: A3F7K2", text: $inviteCode)
                        .font(.system(size: 28, weight: .bold))
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
                        .font(.system(size: 14))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                } else if let error = errorMessage {
                    VStack(spacing: 4) {
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                        Text("\(failCount)/\(maxAttempts)회 실패")
                            .font(.system(size: 12))
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
                                .font(.system(size: 17, weight: .semibold))
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
            dismiss()
        } catch {
            failCount += 1
            if failCount >= maxAttempts {
                lockUntil = Date().addingTimeInterval(TimeInterval(lockSeconds))
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
                lockUntil = nil
                failCount = 0
            }
        }
    }
}
