import SwiftUI

// MARK: - HelpBasicsView

/// Basics-tab content — the three hero cards and their sub-row lists.
///
/// This view is the single host of the shared animation timeline for the
/// Basics tab (redesign §4). It computes `phase ∈ [0, 1)` once per
/// `TimelineView` tick and injects it into `\.animationPhase` so every
/// `HeroIllustration` reads the same value — guaranteeing the three
/// illustrations move in lockstep.
///
/// ### Reduce Motion
/// When `@Environment(\.accessibilityReduceMotion)` is true, phase locks
/// to `0.6` — a "resolved" keyframe that leaves all three illustrations
/// on their final composed state. This matches the default value of the
/// `animationPhase` environment key so even previews without a
/// TimelineView still render a sensible illustration.
///
/// ### Search pause
/// `HelpSearchState.isSearching` freezes the phase at the value captured
/// the moment search began. When search clears, the live timeline
/// resumes. Phase1c's `HelpPane` passes the current values in as init
/// args (`isSearching`, `searchQuery`) AND injects the shared
/// `HelpSearchState` via `\.helpSearchState`; we honor the init args for
/// the display-filtering path and the env state for the
/// animation-freeze snapshot, so sub-row filtering, empty-state text,
/// and animation pause stay consistent.
///
/// ### Deep-link highlight pulse
/// When `HelpNavigator.highlightedFeatureId` matches a hero slug, the
/// hero paints an accent-tinted stroke via `helpHighlightPulse(...)`.
/// When it matches a sub-row slug, the sub-row header gets the pulse.
struct HelpBasicsView: View {
    /// Injected from `HelpPane.searchState.isSearching`. Doubles as the
    /// "freeze animations" trigger.
    var isSearching: Bool = false

    /// Injected from `HelpPane.searchState.query`. Empty string = show all
    /// (redesign §8). Case-insensitive substring match across title +
    /// subtitle + sub-row names + sub-row prose.
    var searchQuery: String = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.helpSearchState) private var searchState
    @Environment(\.helpNavigator) private var navigator
    /// v1.13: hide the per-hero "Ask Jot about this" sparkle affordance
    /// when Advanced is off — the Ask Jot pane is hidden from the
    /// sidebar in that mode, so a live link here would land the user
    /// on an orphan pane (or, post-sanitize, redirect to Recents
    /// silently — neither is a good UX).
    @AppStorage(AdvancedFlag.storageKey) private var advancedEnabled: Bool = false

    /// v1.13: track Apple Intelligence availability so the empty-state
    /// copy doesn't suggest "or ask Ask Jot" on a Mac where Ask Jot
    /// itself shows an unavailable state. Refreshed on `.onAppear`
    /// (mirrors the pattern in `AboutPane`) so a user who enables
    /// Apple Intelligence in System Settings sees the suggestion the
    /// next time they visit Basics.
    @State private var isAskJotAvailable: Bool = AppleIntelligenceClient.isAvailable

    // MARK: Filtering

    private var normalizedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var activeSearch: Bool { isSearching && !normalizedQuery.isEmpty }

    private var visibleHeroes: [Hero] {
        guard activeSearch else { return BasicsContent.heroes }
        return BasicsContent.heroes.filter {
            searchState.shouldShowHero($0, subRows: $0.subRows)
        }
    }

    /// Order-preserved sub-rows for a hero. When search is active, drops
    /// rows that neither match the query directly nor belong to a hero
    /// whose title/subtitle match (so a hero-level match shows ALL rows).
    private func visibleSubRows(for hero: Hero) -> [SubRow] {
        guard activeSearch else { return hero.subRows }
        if searchState.matches(hero) {
            return hero.subRows
        }
        return hero.subRows.filter { searchState.matches($0) }
    }

    // MARK: Body

    var body: some View {
        // Kick the validator on first render (DEBUG-only budget assertions).
        let _ = BasicsContent()

        // No `minimumInterval:` — SwiftUI drives the timeline at the
        // display's native refresh rate (120Hz on ProMotion, 60Hz
        // otherwise). A 30Hz cap here produced visible stutter on
        // ProMotion; at native rate the shared-phase math is cheap.
        TimelineView(.animation) { context in
            let rawPhase = Self.sharedPhase(date: context.date, loopSeconds: 6.0)

            // Search freeze > Reduce Motion > live phase.
            let effectivePhase: Double = {
                if isSearching {
                    if searchState.frozenPhase == nil {
                        searchState.beginSearch(capturingPhase: rawPhase)
                    }
                    return searchState.frozenPhase ?? rawPhase
                } else {
                    // End-of-search housekeeping — clear any stale frozen
                    // phase so the next search captures fresh.
                    if searchState.frozenPhase != nil {
                        searchState.endSearchIfNeeded()
                    }
                    return reduceMotion ? 0.6 : rawPhase
                }
            }()

            content
                .environment(\.animationPhase, effectivePhase)
        }
        .onAppear {
            // Refresh Apple Intelligence availability on each appearance
            // so the empty-state copy reflects a user who flipped Apple
            // Intelligence on in System Settings without relaunching.
            isAskJotAvailable = AppleIntelligenceClient.isAvailable
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visibleHeroes) { hero in
                HeroCard(
                    hero: hero,
                    trailingAccessory: sparkleAccessory(for: hero),
                    isHighlighted: navigator.highlightedFeatureId == hero.id
                )
                .id(hero.id)
                .contextMenu {
                    if advancedEnabled {
                        Button {
                            routeToAskJot(for: hero.id, withPrefill: true)
                        } label: {
                            Label("Ask Jot about this", systemImage: "sparkles")
                        }
                    }
                }

                SubRowList(rows: visibleSubRows(for: hero))
            }

            if visibleHeroes.isEmpty {
                emptyState
            }
        }
    }

    // MARK: - Sparkle icon (chatbot spec v5 §9)

    /// Top-right sparkle affordance on each of the three Basics hero
    /// cards. Hidden when Apple Intelligence is unavailable (the
    /// chatbot pane would be disabled anyway — a live link here would
    /// land the user on a disabled pane).
    ///
    /// Tap behavior (spec §9):
    ///   1. Set `navigator.pendingPrefill = FeatureQuestionMap.prefill(for: heroSlug)`.
    ///   2. Set `navigator.focusChatInput = true`.
    ///   3. Set `navigator.sidebarSelection = .askJot`.
    ///   4. Does NOT auto-send — user reviews and sends.
    private func sparkleAccessory(for hero: Hero) -> AnyView? {
        guard advancedEnabled else { return nil }
        guard FeatureQuestionMap.prefill(for: hero.id) != nil else { return nil }
        return AnyView(
            SparkleAskJotButton(heroSlug: hero.id) {
                routeToAskJot(for: hero.id, withPrefill: true)
            }
        )
    }

    private func routeToAskJot(for heroSlug: String, withPrefill: Bool) {
        if withPrefill, let prefill = FeatureQuestionMap.prefill(for: heroSlug) {
            navigator.pendingPrefill = prefill
        }
        navigator.focusChatInput = true
        navigator.sidebarSelection = .askJot
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            // v1.13: drop the "ask Ask Jot" suggestion when Advanced is
            // off (the chatbot pane is hidden from the sidebar) OR when
            // Apple Intelligence is unavailable (the Ask Jot pane would
            // show an unavailable state). In either case the suggestion
            // would dead-end.
            Text(advancedEnabled && isAskJotAvailable
                 ? "No matches for '\(normalizedQuery)'. Try a different term, or ask Ask Jot."
                 : "No matches for '\(normalizedQuery)'. Try a different term.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    // MARK: Phase computation

    /// Wall-clock-phased `[0, 1)` over a `loopSeconds` cycle. Stable across
    /// view remounts because it reads the same global clock every frame.
    /// `static` so tests can exercise it without instantiating a view.
    static func sharedPhase(date: Date, loopSeconds: Double) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let m = t.truncatingRemainder(dividingBy: loopSeconds)
        return m / loopSeconds
    }
}

// MARK: - Sparkle affordance

/// Top-right sparkle affordance shown on each of the three Basics hero
/// cards. Secondary-tinted by default; hover fills the accent color +
/// shows a tooltip ("Ask Jot about this") per chatbot spec v5 §9.
///
/// The actual routing logic (setting navigator state) lives on the
/// parent `HelpBasicsView` — this view only renders the chrome and
/// forwards the tap. Keeps the affordance free of navigator
/// dependencies so previews stay cheap.
private struct SparkleAskJotButton: View {
    let heroSlug: String
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.accentColor.opacity(0.1) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help("Ask Jot about this")
        .accessibilityLabel("Ask Jot about \(heroSlug)")
        .accessibilityHint("Opens Ask Jot with a starter question about this feature.")
    }
}
