import SwiftUI

/// One section of the Advanced tab — title + subtitle + 2-column card grid
/// that collapses to 1 column on narrow windows (spec v1 §6).
///
/// The threshold is 560pt, matching the spec's "Advanced grid stays 2-column
/// until window narrower than ~560pt (then 1-column)" acceptance criterion.
/// Width is measured once at `HelpAdvancedView` via a single `GeometryReader`
/// and passed down — nesting a GeometryReader inside a scrollable stack
/// swallows intrinsic height and breaks layout, so we do it once at the top.
struct AdvancedSectionView: View {

    /// Width below which the grid collapses to a single column.
    static let narrowThreshold: CGFloat = 560

    let section: AdvancedSection
    /// Measured width passed down from `HelpAdvancedView`.
    let availableWidth: CGFloat
    /// Slugs of currently expanded cards. Shared across the whole tab so
    /// `pendingExpansion` from the navigator can land in any section.
    @Binding var expandedIds: Set<String>
    /// Slug the navigator has staged for a highlight pulse. Compared by
    /// equality per card so only the target card pulses.
    var highlightedSlug: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.headline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text(section.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(section.cards) { card in
                    AdvancedCard(
                        card: card,
                        isExpanded: binding(for: card.id),
                        isHighlighted: highlightedSlug == card.id
                    )
                    .id(card.id)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section.title)
    }

    // MARK: - Layout

    /// `columns` keys off the width passed in from the parent. Public so
    /// tests can exercise the threshold without spinning up a GeometryReader.
    var columns: [GridItem] {
        if availableWidth > 0, availableWidth < Self.narrowThreshold {
            return [GridItem(.flexible(), spacing: 10, alignment: .topLeading)]
        }
        return [
            GridItem(.flexible(), spacing: 10, alignment: .topLeading),
            GridItem(.flexible(), spacing: 10, alignment: .topLeading),
        ]
    }

    /// Static accessor for the column-count decision — used by tests so they
    /// don't need to construct a full view to exercise the threshold.
    static func columnCount(for width: CGFloat) -> Int {
        (width > 0 && width < narrowThreshold) ? 1 : 2
    }

    // MARK: - Binding plumbing

    /// A binding that treats membership in `expandedIds` as the "isExpanded"
    /// state for a single card.
    private func binding(for slug: String) -> Binding<Bool> {
        Binding(
            get: { expandedIds.contains(slug) },
            set: { newValue in
                if newValue {
                    expandedIds.insert(slug)
                } else {
                    expandedIds.remove(slug)
                }
            }
        )
    }
}
