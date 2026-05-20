import SwiftUI

/// Compact "Lighter" badge used next to model display names in Settings
/// and the Setup Wizard. Marks a smaller-footprint model variant without
/// implying experimental status.
struct LighterBadge: View {
    var body: some View {
        Text("Lighter")
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(Color.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.green.opacity(0.15))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.green.opacity(0.35), lineWidth: 0.5)
            )
            .accessibilityLabel("Lighter")
    }
}
