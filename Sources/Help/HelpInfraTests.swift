#if DEBUG
import Foundation
import SwiftUI

/// DEBUG-only runtime tests for the Help-infrastructure layer owned by
/// phase 1C: the `Feature` registry, `HelpSearchState` filtering, and
/// the `HelpNavigator` deep-link API.
///
/// The main Jot app target does not link XCTest (see phase 1C brief's
/// "pragmatic scope" clause — the shipping target has no existing XCTest
/// target). Tests instead live as `assert()`-based invariants inside
/// `#if DEBUG` and are invoked once at startup; release builds strip
/// this file entirely.
///
/// Call `HelpInfraTests.runAll()` from `AppDelegate.applicationDidFinishLaunching`
/// (or any other DEBUG-only startup hook) to exercise the suite. Runs in
/// sub-millisecond time and allocates no AppKit chrome.
enum HelpInfraTests {

    /// Top-level entry point. Each sub-suite fatalError's on failure so
    /// the offending invariant is obvious in the backtrace.
    @MainActor
    static func runAll() {
        FeatureCatalogTests.runAll()
        HelpSearchStateTests.runAll()
        HelpNavigatorTests.runAll()
        InfoCircleAnchorTests.runAll()
    }
}

// MARK: - Feature catalog

enum FeatureCatalogTests {
    static func runAll() {
        test_featureAll_matchesSpec14ExactSlugs()
        test_plainSubRows_areNotDeepLinkable()
        test_nonPlainFeatures_areDeepLinkable()
        test_exactlyTwoCommandOnCardSlugs()
        test_bySlug_lookup()
        test_heroReverseLookup()
    }

    /// §14 check: `Feature.all` contains exactly the slugs from the
    /// redesign spec — no more, no less.
    static func test_featureAll_matchesSpec14ExactSlugs() {
        let actual = Set(Feature.all.map(\.slug))
        let expected = Feature.expectedSlugs

        let missing = expected.subtracting(actual)
        let extra = actual.subtracting(expected)

        assert(
            missing.isEmpty,
            "Feature catalog is missing expected slugs: \(missing.sorted())"
        )
        assert(
            extra.isEmpty,
            "Feature catalog has unexpected slugs: \(extra.sorted())"
        )
        assert(
            actual.count == expected.count,
            "Feature catalog count mismatch: got \(actual.count), expected \(expected.count)"
        )
    }

    /// §5 check: the 5 plain sub-rows must all have
    /// `isDeepLinkable == false`. Everything else must be
    /// `isDeepLinkable == true`.
    static func test_plainSubRows_areNotDeepLinkable() {
        for slug in Feature.plainSubRowSlugs {
            guard let feature = Feature.bySlug(slug) else {
                assertionFailure("Plain sub-row slug '\(slug)' missing from Feature registry")
                continue
            }
            assert(
                feature.isDeepLinkable == false,
                "Plain sub-row '\(slug)' must have isDeepLinkable == false"
            )
            assert(
                feature.expandableRowId == nil,
                "Plain sub-row '\(slug)' must have expandableRowId == nil"
            )
        }
    }

    /// Mirror assertion: every non-plain feature is deep-linkable.
    static func test_nonPlainFeatures_areDeepLinkable() {
        for feature in Feature.all where !Feature.plainSubRowSlugs.contains(feature.slug) {
            assert(
                feature.isDeepLinkable,
                "Feature '\(feature.slug)' is not in plainSubRowSlugs but isDeepLinkable == false"
            )
        }
    }

    /// §7 sharp-fix rule: exactly 2 slugs carry `commandOnCard == true`
    /// (`recording-wont-start` and `hotkey-stopped-working`).
    static func test_exactlyTwoCommandOnCardSlugs() {
        let commandSlugs = Feature.all.filter(\.commandOnCard).map(\.slug)
        let expected: Set<String> = Feature.commandOnCardSlugs

        assert(
            Set(commandSlugs) == expected,
            "commandOnCard slugs mismatch. Got \(commandSlugs.sorted()), expected \(expected.sorted())"
        )
        assert(
            commandSlugs.count == 2,
            "commandOnCard count must be 2; got \(commandSlugs.count)"
        )
    }

    /// `Feature.bySlug` round-trips for every slug, and misses on
    /// unknown inputs.
    static func test_bySlug_lookup() {
        for feature in Feature.all {
            assert(
                Feature.bySlug(feature.slug)?.slug == feature.slug,
                "bySlug round-trip failed for '\(feature.slug)'"
            )
        }
        assert(
            Feature.bySlug("definitely-not-a-slug") == nil,
            "bySlug should return nil for unknown slugs"
        )
    }

    /// Every sub-row resolves to its parent hero via `.hero`, and every
    /// hero resolves to itself.
    static func test_heroReverseLookup() {
        for feature in Feature.all where feature.surface == .subRow {
            let hero = feature.hero
            assert(
                hero != nil,
                "Sub-row '\(feature.slug)' has no parent hero"
            )
            assert(
                hero?.surface == .hero,
                "Sub-row '\(feature.slug)' parent is not a hero"
            )
        }
        for feature in Feature.all where feature.surface == .hero {
            assert(
                feature.hero?.slug == feature.slug,
                "Hero '\(feature.slug)' does not resolve to itself via .hero"
            )
        }
    }
}

// MARK: - HelpSearchState

enum HelpSearchStateTests {
    /// Tiny fixture that adopts `HelpSearchable` so we can exercise
    /// the matcher without importing the phase-1A/1B data structs.
    struct Fixture: HelpSearchable {
        let slug: String
        let searchableText: [String]
    }

    @MainActor
    static func runAll() {
        test_emptyQuery_matchesEverything()
        test_substring_caseInsensitive()
        test_substring_diacriticInsensitive()
        test_whitespaceOnlyQuery_isNotSearching()
        test_subRowMatch_surfacesHero()
        test_filtered_preservesOrder()
        test_frozenPhase_capturesOnce()
        test_endSearch_clearsFrozenPhase()
    }

    @MainActor
    static func test_emptyQuery_matchesEverything() {
        let state = HelpSearchState()
        let fx = Fixture(slug: "foo", searchableText: ["Toggle recording"])
        assert(state.matches(fx), "Empty query should match every surface")
        assert(state.isSearching == false, "Empty query should set isSearching = false")
    }

    @MainActor
    static func test_substring_caseInsensitive() {
        let state = HelpSearchState()
        state.query = "TOGGLE"
        let fx = Fixture(slug: "toggle-recording", searchableText: ["Toggle recording", "Press once to start..."])
        assert(state.matches(fx), "Uppercase query should match lowercase title")

        state.query = "record"
        assert(state.matches(fx), "Lowercase query should match title containing 'Recording'")

        state.query = "no-such-text"
        assert(!state.matches(fx), "Non-matching query should not match")
    }

    @MainActor
    static func test_substring_diacriticInsensitive() {
        let state = HelpSearchState()
        state.query = "cafe"
        let fx = Fixture(slug: "cafe", searchableText: ["Café mode"])
        assert(
            state.matches(fx),
            "localizedStandardContains should be diacritic-insensitive"
        )
    }

    @MainActor
    static func test_whitespaceOnlyQuery_isNotSearching() {
        let state = HelpSearchState()
        state.query = "    "
        assert(state.isSearching == false, "Whitespace-only query should set isSearching = false")
        let fx = Fixture(slug: "foo", searchableText: ["bar"])
        assert(state.matches(fx), "Whitespace-only query should behave as empty query (match all)")
    }

    /// Spec §8 — sub-row matches must include their hero so the user
    /// sees the match in context.
    @MainActor
    static func test_subRowMatch_surfacesHero() {
        let state = HelpSearchState()
        let hero = Fixture(slug: "cleanup", searchableText: ["Cleanup", "LLM polish"])
        let row = Fixture(slug: "cleanup-prompt", searchableText: ["Editable prompt", "Rewrite it..."])
        let unrelatedRow = Fixture(slug: "x", searchableText: ["nothing relevant"])

        state.query = "prompt"
        assert(state.matches(hero) == false, "Hero title should not match 'prompt'")
        assert(state.matches(row), "Sub-row containing 'prompt' should match")
        assert(
            state.shouldShowHero(hero, subRows: [row, unrelatedRow]),
            "Hero should surface because at least one sub-row matched"
        )

        state.query = "does-not-appear-anywhere"
        assert(
            !state.shouldShowHero(hero, subRows: [row, unrelatedRow]),
            "Hero should not surface when neither it nor any sub-row matches"
        )
    }

    @MainActor
    static func test_filtered_preservesOrder() {
        let state = HelpSearchState()
        let a = Fixture(slug: "a", searchableText: ["Alpha"])
        let b = Fixture(slug: "b", searchableText: ["Boxed"])
        let c = Fixture(slug: "c", searchableText: ["Alphabet"])

        state.query = "alph"
        let filtered = state.filtered([a, b, c])
        assert(filtered.count == 2, "Expected 2 matches for 'alph' over [Alpha, Boxed, Alphabet]")
        assert(filtered.first?.slug == "a", "Order should be preserved: 'a' first")
        assert(filtered.last?.slug == "c", "Order should be preserved: 'c' last")
    }

    @MainActor
    static func test_frozenPhase_capturesOnce() {
        let state = HelpSearchState()
        state.query = "x"
        state.beginSearch(capturingPhase: 0.25)
        assert(state.frozenPhase == 0.25, "First beginSearch should capture phase")
        state.beginSearch(capturingPhase: 0.9)
        assert(state.frozenPhase == 0.25, "beginSearch must not overwrite a previous frozen phase")
    }

    @MainActor
    static func test_endSearch_clearsFrozenPhase() {
        let state = HelpSearchState()
        state.query = "x"
        state.beginSearch(capturingPhase: 0.25)
        state.query = ""
        state.endSearchIfNeeded()
        assert(state.frozenPhase == nil, "endSearchIfNeeded should clear frozen phase when not searching")

        // Housekeeping guard: endSearchIfNeeded while still searching must NOT
        // clear the frozen phase (would re-capture next tick — not desirable).
        state.query = "x"
        state.beginSearch(capturingPhase: 0.4)
        state.endSearchIfNeeded()
        assert(state.frozenPhase == 0.4, "endSearchIfNeeded should be a no-op while isSearching is true")
    }
}

// MARK: - HelpNavigator

enum HelpNavigatorTests {
    @MainActor
    static func runAll() {
        test_show_onDeepLinkable_stagesTabAndExpansion()
        test_show_onPlainSubRow_isNoOp()
        test_show_onUnknownSlug_isNoOp()
        test_clearSwitchTab_andClearPendingExpansion()
        test_showByFeature_andShowBySlug_parity()
        // Auto-clear test is async — fire-and-forget.
        test_highlightedFeatureId_autoClearsAfter1p5s()
    }

    @MainActor
    static func test_show_onDeepLinkable_stagesTabAndExpansion() {
        let nav = HelpNavigator()
        guard let feature = Feature.bySlug("toggle-recording") else {
            assertionFailure("toggle-recording missing from Feature registry")
            return
        }
        assert(feature.isDeepLinkable, "toggle-recording should be deep-linkable")

        nav.show(feature: feature)
        assert(nav.switchTab == feature.tab, "show should set switchTab to feature.tab")
        assert(
            nav.pendingExpansion == (feature.expandableRowId ?? feature.slug),
            "show should stage pendingExpansion to expandableRowId ?? slug"
        )
        assert(nav.highlightedFeatureId == feature.slug, "show should stage highlightedFeatureId")
    }

    @MainActor
    static func test_show_onPlainSubRow_isNoOp() {
        let nav = HelpNavigator()
        guard let plain = Feature.bySlug("cleanup-fallback") else {
            assertionFailure("cleanup-fallback missing from Feature registry")
            return
        }
        assert(plain.isDeepLinkable == false, "cleanup-fallback should NOT be deep-linkable")

        nav.show(feature: plain)
        assert(nav.switchTab == nil, "show on plain sub-row must not switch tab")
        assert(nav.pendingExpansion == nil, "show on plain sub-row must not stage expansion")
        assert(nav.highlightedFeatureId == nil, "show on plain sub-row must not highlight")
    }

    @MainActor
    static func test_show_onUnknownSlug_isNoOp() {
        let nav = HelpNavigator()
        nav.show(slug: "definitely-not-a-slug")
        assert(nav.switchTab == nil, "show(slug:) on unknown slug must not switch tab")
        assert(nav.pendingExpansion == nil, "show(slug:) on unknown slug must not stage expansion")
        assert(nav.highlightedFeatureId == nil, "show(slug:) on unknown slug must not highlight")
    }

    @MainActor
    static func test_clearSwitchTab_andClearPendingExpansion() {
        let nav = HelpNavigator()
        guard let feature = Feature.bySlug("permissions") else {
            assertionFailure("permissions missing from Feature registry")
            return
        }
        nav.show(feature: feature)
        assert(nav.switchTab != nil)
        assert(nav.pendingExpansion != nil)

        nav.clearSwitchTab()
        assert(nav.switchTab == nil, "clearSwitchTab must null out switchTab")

        nav.clearPendingExpansion()
        assert(nav.pendingExpansion == nil, "clearPendingExpansion must null out pendingExpansion")
    }

    /// show(slug:) should behave identically to show(feature:) when the
    /// slug resolves.
    @MainActor
    static func test_showByFeature_andShowBySlug_parity() {
        guard let feature = Feature.bySlug("cleanup") else {
            assertionFailure("cleanup missing from Feature registry")
            return
        }

        let navA = HelpNavigator()
        navA.show(feature: feature)

        let navB = HelpNavigator()
        navB.show(slug: "cleanup")

        assert(navA.switchTab == navB.switchTab, "show(feature:) and show(slug:) diverge on switchTab")
        assert(
            navA.pendingExpansion == navB.pendingExpansion,
            "show(feature:) and show(slug:) diverge on pendingExpansion"
        )
        assert(
            navA.highlightedFeatureId == navB.highlightedFeatureId,
            "show(feature:) and show(slug:) diverge on highlightedFeatureId"
        )
    }

    /// Spec §7: `highlightedFeatureId` auto-clears after ~1.5s. We run a
    /// short-form check at a slightly extended timeout to absorb test-
    /// runner jitter. Fire-and-forget — the surrounding Task captures a
    /// weak reference so nothing leaks.
    @MainActor
    static func test_highlightedFeatureId_autoClearsAfter1p5s() {
        let nav = HelpNavigator()
        guard let feature = Feature.bySlug("articulate") else {
            assertionFailure("articulate missing from Feature registry")
            return
        }
        nav.show(feature: feature)
        assert(nav.highlightedFeatureId == "articulate", "highlight should be staged immediately")

        Task { @MainActor in
            // 1.5s pulse + 200ms jitter budget.
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            assert(
                nav.highlightedFeatureId == nil,
                "highlightedFeatureId should auto-clear 1.5s after show(feature:)"
            )
        }
    }
}

// MARK: - InfoPopoverButton anchor registry

/// DEBUG-only registry of every `InfoPopoverButton(helpAnchor:)` call
/// site across the Settings / Vocabulary panes. Exists so
/// `InfoCircleAnchorTests` can assert every anchor resolves to a live,
/// deep-linkable `Feature` at app launch — adding a new call site with
/// a stale slug fires the assertion immediately in DEBUG builds.
///
/// Maintenance: whenever a new `InfoPopoverButton(helpAnchor:)` is
/// added OR an existing one's anchor changes, add or update its entry
/// here. The `label` column is free-form — "file.field-name" works
/// well; it only appears in the assertion message.
///
/// Popovers with `helpAnchor: nil` are NOT listed here — nil means "no
/// deep-link, no Learn more footer", which is a valid configuration.
enum InfoCircleAnchorRegistry {
    static let entries: [(label: String, anchor: String)] = [
        // GeneralPane
        ("GeneralPane.launchAtLogin",          "sys-launch-at-login"),
        ("GeneralPane.restartJot",             "hotkey-stopped-working"),
        ("GeneralPane.runSetupWizardAgain",    "resetting-jot"),
        // GeneralPane.donationReminder has helpAnchor: nil

        // TranscriptionPane
        ("TranscriptionPane.defaultModel",                "on-device-transcription"),
        ("TranscriptionPane.autoPaste",                   "dictation"),
        ("TranscriptionPane.pressReturnAfterPasting",     "dictation"),
        ("ArticulatePane.cleanUpTranscriptWithAI",        "cleanup"),
        ("ArticulatePane.customizePrompt",                "cleanup-prompt"),
        ("TranscriptionPane.keepLastTranscriptOnClipboard", "dictation"),

        // ArticulatePane
        ("ArticulatePane.provider",           "ai-cloud-providers"),
        ("ArticulatePane.baseURL",            "ai-custom-base-url"),
        ("ArticulatePane.model",              "ai-cloud-providers"),
        ("ArticulatePane.apiKey",             "ai-custom-base-url"),
        ("ArticulatePane.testConnection",     "ai-test-connection"),
        ("ArticulatePane.sharedSystemPrompt", "ai-editable-prompts"),

        // SoundPane — 5 chime rows + volume slider
        ("SoundPane.recordingStart",          "sound-recording-chimes"),
        ("SoundPane.recordingStop",           "sound-recording-chimes"),
        ("SoundPane.recordingCanceled",       "sound-recording-chimes"),
        ("SoundPane.transcriptionComplete",   "sound-transcription-complete"),
        ("SoundPane.error",                   "sound-error-chime"),
        ("SoundPane.chimeVolume",             "sound-recording-chimes"),

        // ShortcutsPane — header + 5 ForEach bindings + Cancel recording
        ("ShortcutsPane.globalShortcuts",     "modifier-required"),
        ("ShortcutsPane.toggleRecording",     "toggle-recording"),
        ("ShortcutsPane.pushToTalk",          "push-to-talk"),
        ("ShortcutsPane.pasteLastTranscription", "dictation"),
        ("ShortcutsPane.articulateCustom",    "articulate-custom"),
        ("ShortcutsPane.articulate",          "articulate-fixed"),
        ("ShortcutsPane.cancelRecording",     "cancel-recording"),

        // VocabularyPane
        ("VocabularyPane.customVocabulary",   "custom-vocabulary"),

        // SavingsBadge.savingsEstimate has helpAnchor: nil
    ]
}

enum InfoCircleAnchorTests {
    static func runAll() {
        test_allInfoCircleAnchors_resolveToDeepLinkableSlugs()
    }

    /// Every entry in `InfoCircleAnchorRegistry.entries` must resolve
    /// to a live `Feature` where `isDeepLinkable == true`. Fires
    /// `assertionFailure` — which is a soft stop in DEBUG builds — on
    /// any miss so the offender is obvious in the backtrace without
    /// tearing down the whole app on launch.
    static func test_allInfoCircleAnchors_resolveToDeepLinkableSlugs() {
        for (label, anchor) in InfoCircleAnchorRegistry.entries {
            guard let feature = Feature.bySlug(anchor) else {
                assertionFailure(
                    "[\(label)] helpAnchor '\(anchor)' has no matching Feature in the registry."
                )
                continue
            }
            assert(
                feature.isDeepLinkable,
                "[\(label)] helpAnchor '\(anchor)' maps to a non-deep-linkable Feature " +
                "(surface=\(feature.surface), isDeepLinkable=false). Route to the parent " +
                "hero or an expandable sibling instead."
            )
        }
    }
}
#endif
