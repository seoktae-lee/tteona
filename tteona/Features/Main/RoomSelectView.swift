import SwiftUI

struct RoomSelectView: View {
    @Binding var selectedRoomIds: Set<String>
    let onConfirm: () -> Void

    @EnvironmentObject private var roomService: RoomService
    @Environment(\.dismiss) private var dismiss

    // 완성된 브이로그를 선택한 방 채팅에 자동 공유할지 — 위치 공유와 별개의 동의라 토글로 분리.
    // 설정은 기억된다 (VlogGenerationView가 같은 키를 읽어 잡 생성 시 서버에 전달).
    @AppStorage("vlog.shareToRooms") private var shareVlog = true

    var body: some View {
        VStack(spacing: 0) {
            // 핸들
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 16)

            // 헤더
            VStack(spacing: 6) {
                Text(L("roomselect.title"))
                    .font(.tte(22, .bold))
                    .foregroundColor(.tteDarkGray)
                Text(L("roomselect.subtitle"))
                    .font(.tte(14))
                    .foregroundColor(.tteMediumGray)
            }
            .padding(.top, 28)
            .padding(.bottom, 28)

            // 방 목록
            VStack(spacing: 10) {
                ForEach(roomService.myRooms) { room in
                    let isSelected = selectedRoomIds.contains(room.roomId)
                    Button {
                        if isSelected {
                            selectedRoomIds.remove(room.roomId)
                        } else {
                            selectedRoomIds.insert(room.roomId)
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.tte(24))
                                .foregroundColor(isSelected ? .tteOrange : Color.secondary.opacity(0.4))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(room.name)
                                    .font(.tte(16, .semibold))
                                    .foregroundColor(.tteDarkGray)
                                Text(L("roomselect.members", room.memberIds.count))
                                    .font(.tte(13))
                                    .foregroundColor(.tteMediumGray)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 64)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(isSelected ? Color.tteOrange.opacity(0.08) : Color(UIColor.secondarySystemBackground))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(isSelected ? Color.tteOrange.opacity(0.5) : Color.clear, lineWidth: 1.5)
                                )
                        )
                    }
                }
            }
            .padding(.horizontal, 20)

            // 브이로그 자동 공유 토글 — 방을 하나라도 골랐을 때만 의미가 있다
            if !selectedRoomIds.isEmpty {
                Toggle(isOn: $shareVlog) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("roomselect.shareVlog"))
                            .font(.tte(15, .semibold))
                            .foregroundColor(.tteDarkGray)
                        Text(L("roomselect.shareVlogHint"))
                            .font(.tte(12))
                            .foregroundColor(.tteMediumGray)
                    }
                }
                .tint(.tteOrange)
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }

            Spacer()

            // 버튼
            VStack(spacing: 12) {
                Button {
                    onConfirm()
                } label: {
                    Text(selectedRoomIds.isEmpty ? L("roomselect.startWithoutSharing") : L("roomselect.start"))
                        .font(.tte(17, .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }

                Button {
                    dismiss()
                } label: {
                    Text(L("common.cancel"))
                        .font(.tte(15))
                        .foregroundColor(.tteMediumGray)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .background(Color.tteBackground.ignoresSafeArea())
    }
}
