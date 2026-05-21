#if DEBUG
import SwiftUI

/// DEBUG-only runtime tests for the Advanced + Troubleshooting tabs. The
/// main app target doesn't ship with an XCTest bundle wired up yet (per the
/// project layout under `Tests/` — only SwiftPM POCs live there), so the
/// "pragmatic scope" from the phase 1B brief applies: we express the five
/// required test cases as `assert()`-based invariants that run once at
/// startup via `HelpRuntimeTests.runAll()` and `fatalError()` on failure.
///
/// A release build strips this file entirely via `#if DEBUG`.
enum HelpRuntimeTests {

    /// Call once at app launch (e.g. from `AppDelegate.applicationDidFinishLaunching`)
    /// to exercise every invariant. Cheap — the whole suite finishes in sub-
    /// millisecond time and never allocates any AppKit/Help chrome.
    static func runAll() {
        testAdvancedHasFourSections_with6_4_4_3_cards()
        testTroubleshootingHas11Cards()
        testExpansionTogglesOnClick()
        testAdvancedGridCollapsesToOneColumnAtNarrowWidth()
        testCardIdsMatchFeatureRegistry()
    }

    // MARK: - test_advancedHasFourSections_with6_4_4_3_cards

    static func testAdvancedHasFourSections_with6_4_4_3_cards() {
        let sections = AdvancedContent.sections
        assert(sections.count == 4, "Expected 4 Advanced sections; got \(sections.count)")

        // AI providers section grew from 6 → 7 with ai-prompt-library
        // added alongside the existing ai-editable-prompts (the two
        // cover different concerns: shared system prompts vs. the
        // catalog of named prompts).
        let expected: [(String, Int)] = [
            ("AI providers", 7),
            ("System", 4),
            ("Input", 4),
            ("Sounds", 3),
        ]
        for (idx, (title, count)) in expected.enumerated() {
            let section = sections[idx]
            assert(
                section.title == title,
                "Section \(idx) title mismatch: expected \(title), got \(section.title)"
            )
            assert(
                section.cards.count == count,
                "Section \(title) card count: expected \(count), got \(section.cards.count)"
            )
        }
    }

    // MARK: - test_troubleshootingHas11Cards

    static func testTroubleshootingHas11Cards() {
        let cards = TroubleshootingContent.cards
        assert(cards.count == 11, "Expected 11 Troubleshooting cards; got \(cards.count)")

        let expectedSlugs: Set<String> = [
            "permissions", "modifier-required", "bluetooth-redirect",
            "shortcut-conflicts", "recording-wont-start", "hotkey-stopped-working",
            "resetting-jot", "report-issue",
            "ai-unavailable", "ai-connection-failed", "articulate-bad-results",
        ]
        let actualSlugs = Set(cards.map(\.id))
        assert(
            actualSlugs == expectedSlugs,
            "Troubleshooting slugs mismatch. Missing: \(expectedSlugs.subtracting(actualSlugs)). Extra: \(actualSlugs.subtracting(expectedSlugs))"
        )
    }

    // MARK: - test_expansion_togglesOnClick

    /// Exercises the expansion state-model used by both Advanced and
    /// Troubleshooting cards: a `Set<String>` of expanded slugs with
    /// insert/remove semantics. We can't easily fire SwiftUI taps without a
    /// view hierarchy, so this test drives the same Binding pattern the
    /// card views use and asserts the state mutates as expected.
    static func testExpansionTogglesOnClick() {
        var expanded: Set<String> = []
        let binding = Binding<Bool>(
            get: { expanded.contains("ai-apple-intelligence") },
            set: { newValue in
                if newValue {
                    expanded.insert("ai-apple-intelligence")
                } else {
                    expanded.remove("ai-apple-intelligence")
                }
            }
        )

        // Initial: collapsed.
        assert(binding.wrappedValue == false, "Card should start collapsed")

        // Toggle on (simulating tap).
        binding.wrappedValue.toggle()
        assert(binding.wrappedValue == true, "First tap should expand")
        assert(expanded.contains("ai-apple-intelligence"), "Slug should be in expanded set after first tap")

        // Toggle off.
        binding.wrappedValue.toggle()
        assert(binding.wrappedValue == false, "Second tap should collapse")
        assert(!expanded.contains("ai-apple-intelligence"), "Slug should be out of expanded set after second tap")
    }

    // MARK: - test_advancedGrid_collapsesToOneColumnAtNarrowWidth

    static func testAdvancedGridCollapsesToOneColumnAtNarrowWidth() {
        // Below threshold → 1 column.
        assert(AdvancedSectionView.columnCount(for: 400) == 1, "400pt should yield 1 column")
        assert(AdvancedSectionView.columnCount(for: 559) == 1, "559pt should yield 1 column")
        // At/above threshold → 2 columns.
        assert(AdvancedSectionView.columnCount(for: 560) == 2, "560pt should yield 2 columns")
        assert(AdvancedSectionView.columnCount(for: 900) == 2, "900pt should yield 2 columns")
        // Edge case — zero width (unmeasured) defaults to 2 columns so cards
        // render reasonably during first layout.
        assert(AdvancedSectionView.columnCount(for: 0) == 2, "0pt should default to 2 columns")

        // Troubleshooting uses the same threshold — verify parity.
        assert(HelpTroubleshootingView.columnCount(for: 400) == 1)
        assert(HelpTroubleshootingView.columnCount(for: 560) == 2)
    }

    // MARK: - test_cardIds_matchFeatureRegistry

    static func testCardIdsMatchFeatureRegistry() {
        // Every Advanced card slug must resolve via Feature.bySlug.
        for card in AdvancedContent.allCards {
            guard let feature = Feature.bySlug(card.id) else {
                assertionFailure("Advanced slug \(card.id) not in Feature registry")
                continue
            }
            assert(feature.tab == .advanced, "\(card.id) wrong tab")
            assert(feature.surface == .advancedCard, "\(card.id) wrong surface")
        }
        // Every Troubleshooting card slug must resolve via Feature.bySlug.
        for card in TroubleshootingContent.cards {
            guard let feature = Feature.bySlug(card.id) else {
                assertionFailure("Troubleshooting slug \(card.id) not in Feature registry")
                continue
            }
            assert(feature.tab == .troubleshooting, "\(card.id) wrong tab")
            assert(feature.surface == .troubleshootingCard, "\(card.id) wrong surface")
        }

        // Reverse direction: every Feature on these two tabs must have a
        // card-level rendering entry in our content catalogs. This catches
        // the "added a Feature, forgot the card" regression.
        let advancedSlugs = Set(AdvancedContent.allCards.map(\.id))
        for feature in Feature.all(on: .advanced) {
            assert(
                advancedSlugs.contains(feature.id),
                "Feature \(feature.id) is tab=.advanced but has no AdvancedCardData entry"
            )
        }
        let troubleshootingSlugs = Set(TroubleshootingContent.cards.map(\.id))
        for feature in Feature.all(on: .troubleshooting) {
            assert(
                troubleshootingSlugs.contains(feature.id),
                "Feature \(feature.id) is tab=.troubleshooting but has no TroubleshootingCardData entry"
            )
        }
    }
}
#endif
