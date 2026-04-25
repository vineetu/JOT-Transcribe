import SwiftUI

/// The Advanced tab (spec v1 §6) — four sections stacked vertically, each
/// rendering a 2-column card grid that collapses to 1 column below 560pt.
///
/// Sections & card counts come from `AdvancedContent` and mirror spec §6:
///   * AI providers — 6 cards
///   * System — 4 cards
///   * Input — 4 cards
///   * Sounds — 3 cards
///
/// Deep-link contract (coordinated with `HelpPane`):
///   * `pendingExpansion` — a slug the navigator wants expanded-and-scrolled
///     when this tab mounts. `HelpPane` computes this per-tab (so Advanced
///     doesn't try to expand a Troubleshooting slug) and passes it in.
///   * `onConsumePendingExpansion` — invoked after the view has applied the
///     expansion, so `HelpPane` / `HelpNavigator` can clear their state.
///   * `helpNavigator.highlightedFeatureId` — consulted for the highlight
///     pulse. Read straight from the environment since it auto-clears via
///     the navigator's own 1.5s timer.
///
/// Search: reads `@Environment(\.helpSearchState)`. When `isSearching` is
/// true, sections whose cards all fail to match hide entirely; otherwise
/// the section renders only the subset of cards that matched. The enclosing
/// `HelpPane` owns the "no matches" empty state.
struct HelpAdvancedView: View {

    @Environment(\.helpSearchState) private var searchState
    @Environment(\.helpNavigator) private var navigator

    /// Slug the navigator wants expanded on entry. `HelpPane` computes this
    /// from `HelpNavigator.pendingExpansion`, but filters it down to the slug
    /// belonging to the Advanced tab so an unrelated slug doesn't leak in.
    var pendingExpansion: String?

    /// Called after the view has consumed the pending slug, so the parent
    /// can clear its navigator state.
    var onConsumePendingExpansion: (() -> Void)?

    let sections: [AdvancedSection]

    /// The slugs of currently expanded Advanced cards. Multiple cards may be
    /// expanded at once — users can open several to compare without the view
    /// closing earlier ones.
    @State private var expandedIds: Set<String> = []

    /// Measured container width, sampled via `onGeometryChange` on a
    /// zero-size clear background. `HelpPane` owns the outer `ScrollView`,
    /// so this view cannot use `GeometryReader` at the root — it would
    /// report 0 vertical height inside the infinite scroll parent and
    /// collapse the entire tab to empty.
    @State private var measuredWidth: CGFloat = 0

    init(
        sections: [AdvancedSection] = AdvancedContent.sections,
        pendingExpansion: String? = nil,
        onConsumePendingExpansion: (() -> Void)? = nil
    ) {
        self.sections = sections
        self.pendingExpansion = pendingExpansion
        self.onConsumePendingExpansion = onConsumePendingExpansion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(visibleSections) { section in
                AdvancedSectionView(
                    section: section,
                    availableWidth: measuredWidth,
                    expandedIds: $expandedIds,
                    highlightedSlug: navigator.highlightedFeatureId
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AdvancedWidthPreferenceKey.self,
                    value: proxy.size.width
                )
            }
        )
        .onPreferenceChange(AdvancedWidthPreferenceKey.self) { width in
            measuredWidth = width
        }
        .onChange(of: pendingExpansion) { _, newValue in
            consumeExpansion(newValue)
        }
        .onAppear {
            consumeExpansion(pendingExpansion)
        }
    }

    // MARK: - Visible (post-filter) sections

    /// Sections with their cards optionally filtered by the active search
    /// query. Empty sections are dropped.
    private var visibleSections: [AdvancedSection] {
        guard searchState.isSearching else { return sections }
        return sections.compactMap { section in
            let filtered = section.cards.filter { searchState.matches($0) }
            guard !filtered.isEmpty else { return nil }
            return AdvancedSection(
                id: section.id,
                title: section.title,
                subtitle: section.subtitle,
                cards: filtered
            )
        }
    }

    // MARK: - Navigator wiring

    /// Applies the pending expansion locally. `HelpPane` owns the outer
    /// `ScrollViewReader`, so it handles the scroll-to; this method only
    /// opens the target card and lets the parent clear its pending state.
    private func consumeExpansion(_ slug: String?) {
        guard let slug,
              sections.contains(where: { $0.cards.contains(where: { $0.id == slug }) })
        else {
            return
        }
        withAnimation(HelpSharedStyle.expandAnimation) {
            expandedIds.insert(slug)
        }
        DispatchQueue.main.async {
            onConsumePendingExpansion?()
        }
    }
}

private struct AdvancedWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Debug invariants

#if DEBUG
extension HelpAdvancedView {
    /// Invoked at app startup to assert the catalog matches the spec. Cheap;
    /// runs once. A release build strips this whole block.
    static func runDebugInvariants() {
        // Shape: 4 sections with expected counts per spec §6.
        assert(
            AdvancedContent.sections.count == 4,
            "Advanced must have exactly 4 sections; got \(AdvancedContent.sections.count)"
        )
        let expectedCounts = [6, 4, 4, 3]
        for (idx, section) in AdvancedContent.sections.enumerated() {
            assert(
                section.cards.count == expectedCounts[idx],
                "Section \(section.title) should have \(expectedCounts[idx]) cards; got \(section.cards.count)"
            )
        }
        // Slug coverage: every card must resolve via Feature.bySlug.
        for card in AdvancedContent.allCards {
            assert(
                Feature.bySlug(card.id) != nil,
                "Advanced card slug \(card.id) missing from Feature registry"
            )
            assert(
                Feature.bySlug(card.id)?.tab == .advanced,
                "Advanced card slug \(card.id) resolves to wrong tab"
            )
        }
        // Column threshold: sanity-check the pivot points.
        assert(AdvancedSectionView.columnCount(for: 400) == 1)
        assert(AdvancedSectionView.columnCount(for: 559) == 1)
        assert(AdvancedSectionView.columnCount(for: 560) == 2)
        assert(AdvancedSectionView.columnCount(for: 900) == 2)
    }
}
#endif
