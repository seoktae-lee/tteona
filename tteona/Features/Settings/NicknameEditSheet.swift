import SwiftUI

/// 설정 → 프로필에서 닉네임을 변경하는 시트.
/// 온보딩과 동일한 검증 파이프라인(길이 → 부적절 표현 → 중복)을 거친다.
struct NicknameEditSheet: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var userService: UserService
    @Environment(\.dismiss) private var dismiss

    @State private var nickname = ""
    @State private var state: CheckState = .idle
    @State private var debounceTask: Task<Void, Never>? = nil
    @State private var isSaving = false
    @State private var saveFailed = false
    @FocusState private var focused: Bool

    enum CheckState { case idle, checking, available, taken, inappropriate, unchanged }

    private var currentNickname: String {
        userService.currentUser?.nickname ?? ""
    }

    private var trimmed: String {
        nickname.trimmingCharacters(in: .whitespaces)
    }

    private var canSave: Bool {
        state == .available && !isSaving
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    TteTextField(placeholder: L("onboarding.nickname.placeholder"), text: $nickname)
                        .focused($focused)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .onChange(of: nickname) { _, newValue in
                            scheduleCheck(newValue)
                        }

                    HStack(spacing: 6) {
                        switch state {
                        case .checking:
                            ProgressView().scaleEffect(0.7)
                            Text(L("onboarding.nickname.checking"))
                                .font(.tte(12))
                                .foregroundColor(.tteMediumGray)
                        case .available:
                            Image(systemName: "checkmark.circle.fill")
                                .font(.tte(13))
                                .foregroundColor(.green)
                            Text(L("onboarding.nickname.available"))
                                .font(.tte(12))
                                .foregroundColor(.green)
                        case .taken:
                            Image(systemName: "xmark.circle.fill")
                                .font(.tte(13))
                                .foregroundColor(.red)
                            Text(L("onboarding.nickname.taken"))
                                .font(.tte(12))
                                .foregroundColor(.red)
                        case .inappropriate:
                            Image(systemName: "xmark.circle.fill")
                                .font(.tte(13))
                                .foregroundColor(.red)
                            Text(L("onboarding.nickname.inappropriate"))
                                .font(.tte(12))
                                .foregroundColor(.red)
                        case .unchanged:
                            Text(L("settings.nickname.unchanged"))
                                .font(.tte(12))
                                .foregroundColor(.tteMediumGray)
                        case .idle:
                            EmptyView()
                        }
                        Spacer()
                        Text("\(nickname.count)/10")
                            .font(.tte(12))
                            .foregroundColor(nickname.count > 10 ? .red : .tteMediumGray)
                    }
                    .padding(.horizontal, 28)
                    .frame(height: 20)
                }

                Spacer()

                Button {
                    Task { await save() }
                } label: {
                    ZStack {
                        if isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Text(L("common.save"))
                                .font(.tte(17, .semibold))
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.tteOrange))
                }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.4)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationTitle(L("settings.editNickname"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.cancel")) { dismiss() }
                        .font(.tte(15))
                        .foregroundColor(.tteMediumGray)
                }
            }
            .alert(L("settings.nickname.saveFailed"), isPresented: $saveFailed) {
                Button(L("common.ok"), role: .cancel) {}
            }
            .onAppear {
                nickname = currentNickname
                focused = true
            }
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }

    // 온보딩과 동일 기준: 600ms 디바운스 → 금칙어 → 중복 검사. 현재 닉네임 그대로면 저장 불필요.
    private func scheduleCheck(_ value: String) {
        debounceTask?.cancel()
        let t = value.trimmingCharacters(in: .whitespaces)
        guard t != currentNickname else {
            state = .unchanged
            return
        }
        guard t.count >= 2, t.count <= 10 else {
            state = .idle
            return
        }
        state = .checking
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            guard await StatsService.shared.isTextAllowed(t) else {
                if !Task.isCancelled { state = .inappropriate }
                return
            }
            let taken = await userService.isNicknameTaken(t)
            guard !Task.isCancelled else { return }
            state = taken ? .taken : .available
        }
    }

    private func save() async {
        guard let uid = authService.currentUser?.uid, state == .available else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await userService.updateNickname(uid: uid, nickname: trimmed)
            Haptics.success()
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}
