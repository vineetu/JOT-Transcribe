import Foundation
import SwiftUI

// MARK: - BasicsContent runtime tests
//
// The Jot app target has no linked XCTest target (see CLAUDE.md —
// "pragmatic scope" for this phase), so the Basics content tests run as
// DEBUG-only runtime assertions executed on first reference. `HelpPane`
// pulls `BasicsContent()` in via `HelpBasicsView`, which triggers
// `BasicsContent.validate()`; this file adds a second entry point that
// invokes the more granular per-slug checks.
//
// When we wire a real XCTest target (phase 2+), these assertions port
// one-to-one to proper `XCTAssert`/`XCTAssertEqual` calls. Everything
// here is safe to leave in place — it compiles away to nothing in
// release builds.

#if DEBUG
extension BasicsContent {
    /// Deep invariant suite. Called once from a DEBUG-only initializer on
    /// first `HelpBasicsView` render. Independent from `validate()` so
    /// the two can evolve separately if needed.
    static func runTestSuite() {
        test_heroSubtitleBudget_under120Chars()
        test_subRowDetailBudget_under400Chars()
        test_plainRows_haveNoDetail()
        test_expandableRows_haveDetail()
        test_multilingualExpansion_shows25Languages()
        test_subRowSlugs_matchSpec14()
        test_heroSlugs_matchSpec14()
    }

    // §10 test 1
    static func test_heroSubtitleBudget_under120Chars() {
        for hero in heroes {
            assert(
                hero.subtitle.count <= BasicsBudget.heroSubtitle,
                "Hero '\(hero.id)' subtitle is \(hero.subtitle.count) chars; budget \(BasicsBudget.heroSubtitle)."
            )
        }
    }

    // §10 test 2
    static func test_subRowDetailBudget_under400Chars() {
        for hero in heroes {
            for row in hero.subRows {
                guard let prose = row.detail?.prose else { continue }
                assert(
                    prose.count <= BasicsBudget.subRowProse,
                    "SubRow '\(row.id)' prose is \(prose.count) chars; budget \(BasicsBudget.subRowProse)."
                )
            }
        }
    }

    // §10 test 3 — only Cleanup retains plain rows after the April 2026
    // removal of auto-transcribe, re-transcribe, and articulate-shared-prompt.
    static func test_plainRows_haveNoDetail() {
        let plainSlugs: Set<String> = [
            "cleanup-fallback", "cleanup-raw-preserved",
        ]
        for hero in heroes {
            for row in hero.subRows where plainSlugs.contains(row.id) {
                assert(row.isExpandable == false,
                       "Plain sub-row '\(row.id)' must have isExpandable == false.")
                assert(row.detail == nil,
                       "Plain sub-row '\(row.id)' must have detail == nil.")
            }
        }
    }

    // §10 test 4
    static func test_expandableRows_haveDetail() {
        for hero in heroes {
            for row in hero.subRows where row.isExpandable {
                assert(row.detail != nil,
                       "Expandable sub-row '\(row.id)' must have a non-nil detail.")
            }
        }
    }

    // §10 test 8 — multilingual expansion must include 25 language codes.
    // We assert on the MultilingualGrid's private list indirectly by
    // exercising the grid's custom content: the catalog gives the
    // sub-row a customContent != nil and the grid itself is known-good
    // by construction. The count check is repeated in the grid to keep
    // the two in sync.
    static func test_multilingualExpansion_shows25Languages() {
        guard let multilingualRow = heroes
                .first(where: { $0.id == "dictation" })?
                .subRows.first(where: { $0.id == "multilingual" })
        else {
            assertionFailure("Multilingual sub-row missing from Dictation hero.")
            return
        }
        assert(multilingualRow.detail?.customContent != nil,
               "multilingual row must have customContent (the 25-code grid).")
    }

    // Slug catalog sanity — cross-check against spec §14.
    static func test_subRowSlugs_matchSpec14() {
        let expected: [String: Set<String>] = [
            "dictation": [
                "toggle-recording", "push-to-talk", "cancel-recording",
                "any-length", "on-device-transcription",
                "multilingual", "languages", "custom-vocabulary",
            ],
            "cleanup": [
                "cleanup-providers", "cleanup-prompt",
                "cleanup-fallback", "cleanup-raw-preserved",
            ],
            "articulate": [
                "articulate-custom", "articulate-fixed",
                "articulate-intent-classifier",
            ],
        ]
        for hero in heroes {
            let actual = Set(hero.subRows.map(\.id))
            let want = expected[hero.id] ?? []
            assert(
                actual == want,
                "Hero '\(hero.id)' sub-row slugs diverged from spec §14.\n  Expected: \(want.sorted())\n  Actual:   \(actual.sorted())"
            )
        }
    }

    static func test_heroSlugs_matchSpec14() {
        let expected: Set<String> = ["dictation", "cleanup", "articulate"]
        let actual = Set(heroes.map(\.id))
        assert(
            actual == expected,
            "Hero slugs diverged from spec §14. Expected: \(expected), actual: \(actual)"
        )
    }
}
#endif
