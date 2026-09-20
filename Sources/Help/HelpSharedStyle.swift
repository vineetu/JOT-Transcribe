import SwiftUI

/// Shared visual constants for the redesigned Help tab. Hoisting these
/// into a single file means the hero card, Advanced card, and
/// Troubleshooting card can't drift out of sync on border stroke,
/// corner radius, or the deep-link highlight pulse timing.
///
/// Phase 1A leads any further consolidation of visual tokens — if a new
/// shared constant is useful across all three tab views, add it here
/// rather than duplicating it per-view.
public enum HelpSharedStyle {
    /// Corner radius for hero cards on the Basics tab. Larger than
    /// sub-row / Advanced / Troubleshooting cards to reinforce hero
    /// hierarchy.
    public static let heroCornerRadius: CGFloat = 12

    /// Corner radius for every non-hero card (sub-row expanded panel,
    /// Advanced card, Troubleshooting card).
    public static let cardCornerRadius: CGFloat = 8

    /// Stroke width for the default card border.
    public static let cardBorderWidth: CGFloat = 0.5

    /// Default card border color — very low opacity `.primary` so it
    /// works on light / dark / tinted modes without manual overrides.
    public static let cardBorderOpacity: Double = 0.08

    /// Duration the deep-link highlight pulse stays on a card before
    /// auto-clearing. Consumed by `HelpNavigator.scheduleHighlightClear`
    /// — adjust BOTH values together if tuning.
    public static let highlightPulseDuration: Double = 1.5

    /// Accent-tinted border opacity used during the highlight pulse.
    public static let highlightBorderOpacity: Double = 0.6

    /// Spring animation used for sub-row / card expansion toggles. Tuned
    /// for a calm, non-bouncy slide — same parameters drive row height,
    /// detail insertion, chevron rotation, and background tint so the
    /// whole expand transaction animates as one coherent change.
    public static let expandAnimation: Animation = .spring(response: 0.35, dampingFraction: 0.85)

    /// Ease used for scroll-to-id on deep-link.
    public static let scrollAnimation: Animation = .easeInOut(duration: 0.25)

    // MARK: - View helpers

    /// Standard card chrome: background + border + clipping. Apply to
    /// any hero / Advanced / Troubleshooting surface that wants the
    /// default look. Callers that need the highlight pulse should
    /// overlay a second stroke with `accentColor.opacity(...)`
    /// themselves — kept out of the helper so the animation can be
    /// controlled at the call site.
    public static func cardBackground(radius: CGFloat = cardCornerRadius) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        Color.primary.opacity(cardBorderOpacity),
                        lineWidth: cardBorderWidth
                    )
            )
    }
}

extension View {
    /// Apply a highlight pulse to a card while `isHighlighted == true`.
    /// The caller animates the flag; this modifier just overlays the
    /// accent-tinted stroke.
    public func helpHighlightPulse(
        isHighlighted: Bool,
        cornerRadius: CGFloat = HelpSharedStyle.cardCornerRadius
    ) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    JotTheme.current.accent.opacity(
                        isHighlighted ? HelpSharedStyle.highlightBorderOpacity : 0
                    ),
                    lineWidth: isHighlighted ? 1.5 : 0
                )
                .animation(.easeOut(duration: 0.25), value: isHighlighted)
        )
    }
}
