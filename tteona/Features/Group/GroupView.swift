import SwiftUI

// MARK: - Room Card
struct RoomCard: View {
    let room: Room

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(room.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.tteDarkGray)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundColor(.tteMediumGray)
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "key.horizontal")
                        .font(.system(size: 12))
                        .foregroundColor(.tteOrange)
                    Text(room.inviteCode)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.tteOrange)
                        .kerning(2)
                    Text("초대 코드")
                        .font(.system(size: 12))
                        .foregroundColor(.tteMediumGray)
                    Rectangle()
                        .fill(Color(UIColor.separator))
                        .frame(width: 1, height: 12)
                        .padding(.horizontal, 2)
                    Image(systemName: "person.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.tteMediumGray)
                    Text("\(room.memberIds.count)명")
                        .font(.system(size: 12))
                        .foregroundColor(.tteMediumGray)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.tteOrange.opacity(0.08)))

                Spacer()

                Button {
                    shareRoom()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.tteOrange)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.tteOrange.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemBackground)))
    }

    private func shareRoom() {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "tteona.kr"
        components.path = "/room"
        components.queryItems = [
            URLQueryItem(name: "code", value: room.inviteCode),
            URLQueryItem(name: "name", value: room.name)
        ]
        guard let url = components.url else { return }
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }
        var topVC = rootVC
        while let presented = topVC.presentedViewController { topVC = presented }
        topVC.present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
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

                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(.red)
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
                            .fill(inviteCode.count < 6 ? Color.gray.opacity(0.4) : Color.tteOrange)
                    )
                }
                .disabled(inviteCode.count < 6 || isLoading)
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
        guard let uid = authService.currentUser?.uid else { return }
        let nickname = userService.currentUser?.nickname ?? "멤버"
        isLoading = true
        errorMessage = nil
        do {
            _ = try await roomService.joinRoom(inviteCode: inviteCode, userId: uid, nickname: nickname)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
