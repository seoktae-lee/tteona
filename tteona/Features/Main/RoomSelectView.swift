import SwiftUI

struct RoomSelectView: View {
    @Binding var selectedRoomIds: Set<String>
    let onConfirm: () -> Void

    @EnvironmentObject private var roomService: RoomService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 핸들
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 16)

            // 헤더
            VStack(spacing: 6) {
                Text("어디에 공유할까요?")
                    .font(.tte(22, .bold))
                    .foregroundColor(.tteDarkGray)
                Text("선택한 그룹에 오늘의 기록이 공유돼요")
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
                                Text("멤버 \(room.memberIds.count)명")
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

            Spacer()

            // 버튼
            VStack(spacing: 12) {
                Button {
                    onConfirm()
                } label: {
                    Text(selectedRoomIds.isEmpty ? "공유 없이 시작" : "시작하기")
                        .font(.tte(17, .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.tteOrange))
                }

                Button {
                    dismiss()
                } label: {
                    Text("취소")
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
