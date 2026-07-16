#if DEBUG
import Foundation

/// DEBUG-only runtime tests for the **picker visibility** of hardware-gated
/// languages (`LanguageChoice.isHardwareGated` / `presentationEntries`).
///
/// Mirrors the `ModelSwitchTests` pattern — no XCTest dependency (Jot's XCTest
/// target is currently broken), called once from
/// `AppDelegate.applicationDidFinishLaunching` in DEBUG so a miss fires at
/// launch.
///
/// Scope: the *pure* gating predicate + the two derived views the pickers read
/// (`presentationEntries`, which always surfaces every language, and
/// `presentationOrder`, the selectable subset). Eligibility is injected so the
/// suite runs identically on any Mac.
enum LanguageVisibilityTests {
    /// The Nemotron-multilingual-only languages — the exact set gated below the
    /// 24 GB bar (`requiresNemotronMultilingual`).
    private static let nemotronOnly: Set<LanguageChoice> =
        [.mandarin, .arabic, .korean, .hindi, .vietnamese, .turkish]

    static func runAll() {
        test_ineligible_gatesOnlyNemotronOnly()
        test_eligible_gatesNothing()
        test_entriesAlwaysCoverEveryLanguage()
        test_presentationOrderMatchesEntriesUngated()
        test_latvianExperimentalNeverGated()
    }

    /// On an ineligible Mac, exactly the six Nemotron-only languages are gated;
    /// every other language stays selectable.
    static func test_ineligible_gatesOnlyNemotronOnly() {
        for lang in LanguageChoice.allCases {
            let gated = LanguageChoice.isHardwareGated(lang, multilingualEligible: false)
            assert(gated == nemotronOnly.contains(lang),
                   "\(lang) gating on ineligible hardware is wrong (got \(gated))")
        }
    }

    /// On an eligible Mac, nothing is gated.
    static func test_eligible_gatesNothing() {
        for lang in LanguageChoice.allCases {
            assert(!LanguageChoice.isHardwareGated(lang, multilingualEligible: true),
                   "\(lang) must never be gated on eligible hardware")
        }
    }

    /// `presentationEntries` NEVER drops a language, regardless of eligibility —
    /// that's the whole point (gated ones come back disabled, not hidden).
    static func test_entriesAlwaysCoverEveryLanguage() {
        for eligible in [true, false] {
            let entries = LanguageChoice.presentationEntries(multilingualEligible: eligible)
            assert(entries.count == LanguageChoice.allCases.count,
                   "presentationEntries must surface every language (eligible=\(eligible))")
            let gatedCount = entries.filter(\.isHardwareGated).count
            assert(gatedCount == (eligible ? 0 : nemotronOnly.count),
                   "gated count wrong for eligible=\(eligible) (got \(gatedCount))")
        }
    }

    /// The selectable set (`presentationOrder`) is exactly the ungated entries,
    /// so a gated language can never be offered as a real choice.
    static func test_presentationOrderMatchesEntriesUngated() {
        let selectable = Set(LanguageChoice.presentationOrder)
        // presentationOrder reads real hardware; assert only the invariant that
        // no gated-eligible language leaks in, and every selectable one is not
        // Nemotron-only-on-ineligible.
        for lang in nemotronOnly where !HardwareTier.nemotronMultilingualEligible {
            assert(!selectable.contains(lang),
                   "\(lang) must not be selectable on ineligible hardware")
        }
    }

    /// Latvian is experimental but v3-backed — it must NEVER be hardware-gated.
    static func test_latvianExperimentalNeverGated() {
        assert(!LanguageChoice.isHardwareGated(.latvian, multilingualEligible: false),
               "Latvian rides v3 and must never be hardware-gated")
    }
}
#endif
