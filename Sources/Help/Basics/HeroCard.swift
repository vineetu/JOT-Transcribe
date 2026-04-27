import SwiftUI

// MARK: - HeroCard

/// Large animated card at the top of each Basics hero section.
///
/// Structure (redesign §3):
///   1. Title row: `.title2`/medium + optional "optional" label + trailing
///      accessory slot (phase 2A will add a sparkles button there).
///   2. Subtitle: `.subheadline`/secondary, 2-line max. Hard-capped at
///      120 chars by `BasicsContent.validate()`; DEBUG builds paint a red
///      outline when the cap slips.
///   3. Illustration: 140pt tall, rounded corners.
///   4. Optional `ConditionalAction` button.
///
/// ### Phase 2A extension point
/// `trailingAccessory` exists specifically so phase 2A can inject a sparkle
/// button top-right without changing HeroCard internals — just pass an
/// `AnyView` (or nil for none). `HelpBasicsView` renders each hero with
/// `trailingAccessory: nil` today; 2A will swap that for a sparkle view.
///
/// ### Highlight pulse
/// When `isHighlighted == true`, the card paints an accent-tinted stroke
/// via `HelpSharedStyle.helpHighlightPulse`. `HelpBasicsView` passes
/// through `navigator.highlightedFeatureId == hero.id` so deep-link
/// arrivals light up the correct card for 1.5s.
struct HeroCard: View {
    let hero: Hero
    /// Optional trailing view rendered in the top-right of the title row.
    /// Phase 2A hooks into this slot to add the "Ask Jot" sparkle button.
    let trailingAccessory: AnyView?
    /// When true, paints the deep-link pulse stroke.
    let isHighlighted: Bool

    init(
        hero: Hero,
        trailingAccessory: AnyView? = nil,
        isHighlighted: Bool = false
    ) {
        self.hero = hero
        self.trailingAccessory = trailingAccessory
        self.isHighlighted = isHighlighted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(hero.title))
                    .font(.title2)
                    .fontWeight(.medium)
                if hero.isOptional {
                    Text("optional")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let accessory = trailingAccessory {
                    accessory
                }
            }

            Text(LocalizedStringKey(hero.subtitle))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .budgetCheck(max: BasicsBudget.heroSubtitle, actual: hero.subtitle.count)

            HeroIllustration(kind: hero.illustrationKind)
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: HelpSharedStyle.cardCornerRadius))

            if let action = hero.conditionalAction, action.shouldShow() {
                Button(LocalizedStringKey(action.label)) { action.perform() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HelpSharedStyle.heroCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HelpSharedStyle.heroCornerRadius, style: .continuous)
                .stroke(
                    Color.primary.opacity(HelpSharedStyle.cardBorderOpacity),
                    lineWidth: HelpSharedStyle.cardBorderWidth
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: HelpSharedStyle.heroCornerRadius, style: .continuous))
        .helpHighlightPulse(
            isHighlighted: isHighlighted,
            cornerRadius: HelpSharedStyle.heroCornerRadius
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel(for: hero))
    }

    private static func accessibilityLabel(for hero: Hero) -> String {
        let title = String(localized: String.LocalizationValue(hero.title))
        let subtitle = String(localized: String.LocalizationValue(hero.subtitle))
        let optionalSuffix = hero.isOptional ? String(localized: ", optional") : ""
        return "\(title)\(optionalSuffix). \(subtitle)"
    }
}
