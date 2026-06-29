import Foundation
import SwiftUI

/// Event bus coordinating cross-pane navigation. Owned at the root of
/// the unified window so every pane can read and write it, and so
/// mid-flight deep-links survive sidebar navigation.
///
/// Consumers:
///   * `HelpPane` — reads `switchTab`, `pendingExpansion`,
///     `highlightedFeatureId` to drive the two-phase deep-link
///     (expand → scroll → highlight pulse).
///   * Settings panes — read `pendingSettingsFieldAnchor` to scroll
///     a just-opened Settings subsection to a specific field row.
///   * `JotAppWindow` — observes `sidebarSelection` to switch the
///     active pane (Home / Ask Jot / Settings / Help / About).
///   * `AskJotView` — reads `pendingPrefill` + `focusChatInput` to
///     wire the sparkle-icon / About-row → TextField prefill path.
///   * `InfoPopoverButton` (legacy) — continues posting the
///     `jot.help.scrollToAnchor` notification until phase 2C migrates
///     anchor strings to slugs. `HelpPane` bridges the old notification
///     into a tab-level fallback so deep-links still land somewhere
///     non-broken during the transition.
///
/// The navigator is a plain `@Observable` view model — no Combine, no
/// ObservableObject — so SwiftUI tracks property-level access
/// automatically. Mutating a property from the main actor is sufficient
/// to trigger a view update.
@MainActor
@Observable
public final class HelpNavigator {
    // MARK: - Help-tab navigation

    /// Which Help sub-tab should be active. Nil = no change pending.
    /// Consumed by `HelpPane`; once consumed, the pane clears this back
    /// to nil to prevent re-application on a later render.
    public var switchTab: HelpTab?

    /// Slug of an expandable row / card the navigator wants expanded
    /// before scrolling. Matches `Feature.expandableRowId` for the
    /// target feature. `HelpPane` and the tab views consume and clear
    /// this during the two-phase deep-link flow.
    public var pendingExpansion: String?

    /// Slug of the feature currently being highlighted by a deep-link
    /// pulse. Tab views read this to paint an `accentColor.opacity(0.6)`
    /// border around the matching card / row for 1.5s. Auto-clears on a
    /// `Task` timer so callers don't have to.
    public var highlightedFeatureId: String?

    /// When non-nil, the active Settings pane should scroll to the
    /// element tagged with `.id(anchor)`. Consumed by the target pane
    /// on appear / change, then cleared to avoid stale re-scrolls.
    public var pendingSettingsFieldAnchor: String?

    // MARK: - Ask Jot / chatbot integration (phase 2)

    /// Programmatic sidebar selection request. When non-nil, the root
    /// window's `JotAppWindow` observes this via `.onChange` and
    /// mutates its `@State selection`. Consumers set this to
    /// `.askJot` when routing from a sparkle icon, the About row, or
    /// the `ShowFeatureTool` (which also sets `switchHelpTab`).
    ///
    /// The root window clears the value back to nil after consumption
    /// so repeatedly selecting the same destination still re-fires.
    public var sidebarSelection: AppSidebarSelection?

    /// When non-nil, after `sidebarSelection = .help` routes the user
    /// to the Help pane, `HelpPane` switches its internal tab to this
    /// value. Redundant with `switchTab` today but kept separate for
    /// symmetry with `sidebarSelection` — the latter navigates between
    /// sidebar destinations, this one scopes tab switches to the Help
    /// surface specifically.
    public var switchHelpTab: HelpTab?

    /// When non-nil, the Ask Jot pane's TextField should be filled
    /// with this string (without auto-sending). Consumed by
    /// `AskJotView` on focus / appear, then cleared.
    public var pendingPrefill: String?

    /// Request that the Ask Jot pane focus its TextField. Resets to
    /// false after focus is applied. Used both by sparkle-icon routes
    /// (which also set `pendingPrefill`) and the About tab row
    /// (which doesn't — context-free entry).
    public var focusChatInput: Bool = false

    // MARK: - Ask-your-recordings (transcript Q&A) integration

    /// When non-nil, the new transcript-Q&A Ask Jot surface should run
    /// this question immediately (prefill + AUTO-SEND). Set by the AI
    /// button next to the recordings search; consumed + cleared by the
    /// Ask Jot pane wrapper. Distinct from `pendingPrefill`, which only
    /// fills the help-bot composer without sending.
    public var pendingAsk: String?

    /// When non-nil, the recordings list should open this recording's
    /// detail. Set by a citation chip tap in the Ask Jot answer (after
    /// routing to Home/Recents); consumed + cleared by `RecordingsListView`.
    public var pendingOpenRecording: UUID?

    public init() {}

    // MARK: - Deep-link API

    /// Two-phase deep-link: switch tab, stage the expansion, highlight
    /// the slug. No-ops on non-deep-linkable features — the chatbot's
    /// `ShowFeatureTool` and the phase-2 Settings popover migration
    /// both rely on this guard so they never land the user on a plain
    /// (non-expandable) row.
    ///
    /// Consumers (HelpPane + tab views) read `pendingExpansion` and
    /// perform the actual scroll via `ScrollViewReader.scrollTo(slug)`.
    /// `highlightedFeatureId` pulses for 1.5s and then auto-clears so
    /// callers don't need to manage the timer themselves.
    public func show(feature: Feature) {
        guard feature.isDeepLinkable else { return }

        switchTab = feature.tab
        pendingExpansion = feature.expandableRowId ?? feature.slug
        highlightedFeatureId = feature.slug

        scheduleHighlightClear(for: feature.slug)
    }

    /// Convenience: look up the slug and deep-link, if it exists and is
    /// deep-linkable. Silently no-ops on unknown / non-linkable slugs —
    /// matches the `ShowFeatureTool` graceful-skip behavior.
    public func show(slug: String) {
        guard let feature = Feature.bySlug(slug) else { return }
        show(feature: feature)
    }

    /// Manual clear — use when the pane has consumed the state and
    /// wants to avoid re-applying it on the next render.
    public func clearPendingExpansion() {
        pendingExpansion = nil
    }

    /// Manual Settings-field deep-link consumption.
    public func clearPendingSettingsFieldAnchor() {
        pendingSettingsFieldAnchor = nil
    }

    /// Manual tab-switch consumption.
    public func clearSwitchTab() {
        switchTab = nil
    }

    // MARK: - Private

    /// Task-backed auto-clear for `highlightedFeatureId`. Canceled
    /// implicitly by the MainActor reordering — if a second deep-link
    /// starts during the 1.5s window, we simply overwrite the slug and
    /// reschedule. The previous task still fires but checks for the
    /// current slug before clearing, so it's harmless.
    private func scheduleHighlightClear(for slug: String) {
        let target = slug
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            if self.highlightedFeatureId == target {
                self.highlightedFeatureId = nil
            }
        }
    }
}

// MARK: - Environment plumbing

/// Shared placeholder used as the environment default. Replaced by the
/// root view's explicit injection at runtime; the fallback exists so
/// previews, the setup wizard, and other out-of-tree hosts stay
/// harmless when they read the environment key.
@MainActor
private let defaultHelpNavigator = HelpNavigator()

/// Environment key for the shared `HelpNavigator`. Inject once at the
/// root of the unified window (JotAppWindow) and consume anywhere in
/// the view tree.
private struct HelpNavigatorKey: @preconcurrency EnvironmentKey {
    @MainActor
    static let defaultValue: HelpNavigator = defaultHelpNavigator
}

extension EnvironmentValues {
    /// Shared Help navigator. Injected by `JotAppWindow`; consumers read
    /// it via `@Environment(\.helpNavigator)`.
    public var helpNavigator: HelpNavigator {
        get { self[HelpNavigatorKey.self] }
        set { self[HelpNavigatorKey.self] = newValue }
    }
}
