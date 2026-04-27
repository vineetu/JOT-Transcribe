import SwiftUI

/// The Troubleshooting tab (spec v1 §7) — a flat 2-column `LazyVGrid` of
/// 11 cards (8 migrated from the old Help pane, 3 new AI cards).
///
/// Layout is intentionally unchanged from the old Troubleshooting grid — we
/// preserve the existing visual rhythm so users who already know where to
/// look aren't disoriented. The card component itself (`TroubleshootingCard`)
/// is new and matches the `AdvancedCard` shape for visual consistency.
///
/// Deep-link contract mirrors `HelpAdvancedView`: `pendingExpansion` is
/// computed by `HelpPane` and passed in; `onConsumePendingExpansion` is
/// invoked after the view applies the expansion so the navigator can
/// clear its state. Highlight pulses are driven straight off the
/// environment-level `HelpNavigator.highlightedFeatureId`.
///
/// Search: reads `@Environment(\.helpSearchState)`. When `isSearching` is
/// true, non-matching cards are hidden. The enclosing `HelpPane` owns the
/// "no matches" empty state.
struct HelpTroubleshootingView: View {

    @Environment(\.helpSearchState) private var searchState
    @Environment(\.helpNavigator) private var navigator

    /// Slug the navigator wants expanded on entry. Computed by `HelpPane`.
    var pendingExpansion: String?

    /// Called after the view has consumed the pending slug.
    var onConsumePendingExpansion: (() -> Void)?

    /// Width below which the grid collapses to 1 column. Matches Advanced's
    /// 560pt breakpoint so the two tabs reflow in lockstep.
    static let narrowThreshold: CGFloat = 560

    let cards: [TroubleshootingCardData]

    @State private var expandedIds: Set<String> = []

    /// Measured container width. `HelpPane` owns the outer `ScrollView`,
    /// so this view cannot use `GeometryReader` at the root — see the
    /// matching comment in `HelpAdvancedView`.
    @State private var measuredWidth: CGFloat = 0

    init(
        cards: [TroubleshootingCardData] = TroubleshootingContent.cards,
        pendingExpansion: String? = nil,
        onConsumePendingExpansion: (() -> Void)? = nil
    ) {
        self.cards = cards
        self.pendingExpansion = pendingExpansion
        self.onConsumePendingExpansion = onConsumePendingExpansion
    }

    var body: some View {
        LazyVGrid(
            columns: columns(for: measuredWidth),
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(visibleCards) { card in
                TroubleshootingCard(
                    card: card,
                    isExpanded: binding(for: card.id),
                    isHighlighted: navigator.highlightedFeatureId == card.id
                )
                .id(card.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TroubleshootingWidthPreferenceKey.self,
                    value: proxy.size.width
                )
            }
        )
        .onPreferenceChange(TroubleshootingWidthPreferenceKey.self) { width in
            measuredWidth = width
        }
        .onChange(of: pendingExpansion) { _, newValue in
            consumeExpansion(newValue)
        }
        .onAppear {
            consumeExpansion(pendingExpansion)
        }
    }

    // MARK: - Filter

    private var visibleCards: [TroubleshootingCardData] {
        guard searchState.isSearching else { return cards }
        return cards.filter { searchState.matches($0) }
    }

    // MARK: - Layout

    private func columns(for width: CGFloat) -> [GridItem] {
        if width > 0, width < Self.narrowThreshold {
            return [GridItem(.flexible(), spacing: 10, alignment: .topLeading)]
        }
        return [
            GridItem(.flexible(), spacing: 10, alignment: .topLeading),
            GridItem(.flexible(), spacing: 10, alignment: .topLeading),
        ]
    }

    static func columnCount(for width: CGFloat) -> Int {
        (width > 0 && width < narrowThreshold) ? 1 : 2
    }

    // MARK: - Expansion plumbing

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

    /// Applies the pending expansion locally. `HelpPane` owns the outer
    /// `ScrollViewReader`, so it handles the scroll-to.
    private func consumeExpansion(_ slug: String?) {
        guard let slug, cards.contains(where: { $0.id == slug }) else { return }
        withAnimation(HelpSharedStyle.expandAnimation) {
            _ = expandedIds.insert(slug)
        }
        DispatchQueue.main.async {
            onConsumePendingExpansion?()
        }
    }
}

private struct TroubleshootingWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Debug invariants

#if DEBUG
extension HelpTroubleshootingView {
    /// Invoked at app startup to assert the catalog matches the spec.
    static func runDebugInvariants() {
        // 11 cards total (8 migrated + 3 new AI cards).
        assert(
            TroubleshootingContent.cards.count == 11,
            "Troubleshooting must have exactly 11 cards; got \(TroubleshootingContent.cards.count)"
        )
        // Slug coverage: every card must resolve via Feature.bySlug.
        for card in TroubleshootingContent.cards {
            assert(
                Feature.bySlug(card.id) != nil,
                "Troubleshooting card slug \(card.id) missing from Feature registry"
            )
            assert(
                Feature.bySlug(card.id)?.tab == .troubleshooting,
                "Troubleshooting card slug \(card.id) resolves to wrong tab"
            )
        }
        // The 3 new AI cards must be present in the catalog.
        let slugs = Set(TroubleshootingContent.cards.map(\.id))
        for newSlug in ["ai-unavailable", "ai-connection-failed", "articulate-bad-results"] {
            assert(slugs.contains(newSlug), "Missing new AI card slug \(newSlug)")
        }
        // Column threshold sanity check — matches Advanced tab's 560pt pivot.
        assert(Self.columnCount(for: 400) == 1)
        assert(Self.columnCount(for: 559) == 1)
        assert(Self.columnCount(for: 560) == 2)
        assert(Self.columnCount(for: 900) == 2)
    }
}
#endif
