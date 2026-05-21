import SwiftUI

/// Compact badge for model options kept only for compatibility.
struct DeprecatedBadge: View {
    var body: some View {
        Text("Deprecated")
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.orange.opacity(0.15))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
            )
            .accessibilityLabel("Deprecated")
    }
}
