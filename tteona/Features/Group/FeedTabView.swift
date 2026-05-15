import SwiftUI

struct FeedTabView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var notificationManager: AppNotificationManager

    @State private var selectedRoom: Room?
    @State private var showCreateRoom = false
    @State private var showJoinRoom = false
    @State private var pendingMemberChat: FeedMember? = nil

    private var uid: String { authService.currentUser?.uid ?? "" }

    var body: some View {
        NavigationStack {
            Group {
                if roomService.myRooms.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(roomService.myRooms) { room in
                                RoomCard(room: room)
                                    .onTapGesture { selectedRoom = room }
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("피드")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showCreateRoom = true
                        } label: {
                            Label("방 만들기", systemImage: "plus.circle")
                        }
                        Button {
                            showJoinRoom = true
                        } label: {
                            Label("코드로 참여", systemImage: "key.horizontal")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.tteOrange)
                    }
                }
            }
            .navigationDestination(item: $selectedRoom) { room in
                RoomDetailView(room: room, autoOpenUserId: pendingMemberChat?.userId)
                    .environmentObject(authService)
                    .environmentObject(userService)
                    .environmentObject(roomService)
                    .onDisappear { pendingMemberChat = nil }
            }
        }
        .onAppear {
            guard let pending = notificationManager.pendingChatRoom else { return }
            Task {
                await openChatRoom(pending)
            }
        }
        .onChange(of: notificationManager.pendingChatRoom) { _, pending in
            guard let pending else { return }
            Task {
                await openChatRoom(pending)
            }
        }
        .onChange(of: roomService.myRooms) { _, _ in
            guard let pending = notificationManager.pendingChatRoom else { return }
            Task {
                await openChatRoom(pending)
            }
        }
        .sheet(isPresented: $showCreateRoom) {
            CreateRoomView()
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
        .sheet(isPresented: $showJoinRoom) {
            JoinRoomView()
                .environmentObject(authService)
                .environmentObject(userService)
                .environmentObject(roomService)
        }
    }

    private func openChatRoom(_ pending: PendingChatRoom) async {
        guard let room = roomService.myRooms.first(where: { $0.roomId == pending.roomId }) else { return }
        notificationManager.pendingChatRoom = nil
        await roomService.fetchMembers(roomId: pending.roomId)
        if let member = roomService.currentRoomMembers.first(where: { $0.userId == pending.targetUserId }) {
            pendingMemberChat = FeedMember(userId: member.userId, nickname: member.nickname)
        }
        selectedRoom = room
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "person.3.fill")
                .font(.system(size: 52))
                .foregroundColor(.tteOrange.opacity(0.4))
            Text("아직 참여한 그룹이 없어요")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.tteDarkGray)
            Text("친구들과 함께 오늘을 공유해보세요!")
                .font(.system(size: 14))
                .foregroundColor(.tteMediumGray)
            HStack(spacing: 12) {
                Button { showCreateRoom = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("방 만들기").fontWeight(.semibold)
                    }
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .frame(height: 48).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.tteOrange))
                }
                Button { showJoinRoom = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "key.horizontal.fill")
                        Text("코드 입력").fontWeight(.semibold)
                    }
                    .font(.system(size: 15))
                    .foregroundColor(.tteOrange)
                    .frame(height: 48).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).stroke(Color.tteOrange, lineWidth: 1.5))
                }
            }
            .padding(.horizontal, 40)
            Spacer()
        }
    }
}
