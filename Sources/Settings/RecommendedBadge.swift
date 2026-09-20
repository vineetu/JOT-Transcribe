import SwiftUI

/// Compact "Recommended" badge used next to model display names in
/// Settings → Transcription and the Setup Wizard model step. Marks the
/// option as Jot's default first-try pick.
struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(JotTheme.current.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(JotTheme.current.accent.opacity(0.15))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(JotTheme.current.accent.opacity(0.35), lineWidth: 0.5)
            )
            .accessibilityLabel("Recommended")
    }
}
