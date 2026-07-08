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
                                let hasNew = roomService.unreadRoomIds.contains(room.roomId)
                                RoomCard(room: room, hasNewFeed: hasNew)
                                    .onTapGesture {
                                        roomService.markRoomAsRead(roomId: room.roomId, userId: uid)
                                        selectedRoom = room
                                    }
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle(L("tab.chat"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showCreateRoom = true
                        } label: {
                            Label(L("group.createRoom"), systemImage: "plus.circle")
                        }
                        Button {
                            showJoinRoom = true
                        } label: {
                            Label(L("group.joinWithCode"), systemImage: "key.horizontal")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.tte(17, .semibold))
                            .foregroundColor(.tteOrange)
                    }
                    .accessibilityLabel(L("group.createOrJoin"))
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
        .task {
            guard !uid.isEmpty else { return }
            await roomService.refreshUnreadStatus(userId: uid)
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
            TteEmptyState(
                image: "tteoni-travel",
                title: L("group.empty.title"),
                subtitle: L("group.empty.subtitle")
            )
            HStack(spacing: 12) {
                Button { showCreateRoom = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text(L("group.createRoom")).fontWeight(.semibold)
                    }
                    .font(.tte(15))
                    .foregroundColor(.white)
                    .frame(height: 48).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.tteOrange))
                }
                Button { showJoinRoom = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "key.horizontal.fill")
                        Text(L("group.enterCode")).fontWeight(.semibold)
                    }
                    .font(.tte(15))
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
