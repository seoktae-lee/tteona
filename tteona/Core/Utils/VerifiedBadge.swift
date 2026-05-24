import SwiftUI

struct VerifiedBadge: View {
    let creatorLabel: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.tteOrange)
            if let label = creatorLabel, !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.tteOrange)
            }
        }
    }
}
