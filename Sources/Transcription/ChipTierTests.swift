#if DEBUG
import Foundation

/// DEBUG-only runtime tests for the **chip half** of the Nemotron hardware gate
/// (`HardwareTier.chipClearsNemotronTier`) and the dynamic gate-note wording
/// (`LanguageChoice.hardwareGateNote`).
///
/// Mirrors the `ModelSwitchTests` / `LanguageVisibilityTests` pattern — no
/// XCTest dependency (Jot's XCTest target is currently broken), called once from
/// `AppDelegate.applicationDidFinishLaunching` in DEBUG so a miss fires at
/// launch.
///
/// Scope: the *pure* brand-string → pass/fail predicate (injected as a literal
/// string, so the suite runs identically on any Mac) and the two honest note
/// variants. The rule under test: Pro/Max/Ultra clear from gen 2; base chips
/// clear from gen 4; base M1/M2/M3 and all M1 fail.
enum ChipTierTests {
    static func runAll() {
        test_chipTierRule()
        test_generationParsing()
        test_gateNoteVariants()
    }

    /// Every case the reviewer pinned, plus the base-M4/M5 fix and the "M12"
    /// parsing guard.
    static func test_chipTierRule() {
        let cases: [(String?, Bool)] = [
            ("Apple M1", false),        // gen 1 base
            ("Apple M1 Max", false),    // gen 1 Pro-tier still fails (< gen 2)
            ("Apple M2", false),        // base gen 2 — measured-caution, stays out
            ("Apple M2 Pro", true),     // the original floor
            ("Apple M3", false),        // base gen 3 — stays out
            ("Apple M3 Max", true),
            ("Apple M4", true),         // NEW: base gen 4 now clears
            ("Apple M5", true),         // NEW: base gen 5 clears
            ("Apple M5 Pro", true),
            ("Apple M12", true),        // parsing: 12 ≥ 4, not a "M1" substring hit
            (nil, false),
            ("Intel(R) Core(TM) i7", false),
        ]
        for (brand, expected) in cases {
            let got = HardwareTier.chipClearsNemotronTier(brand)
            assert(got == expected,
                   "chipClearsNemotronTier(\(brand ?? "nil")) = \(got), expected \(expected)")
        }
    }

    /// The generation is a full integer after "M", so "M12" is 12 (not 1) and
    /// non-Apple strings yield `nil`.
    static func test_generationParsing() {
        assert(HardwareTier.appleSiliconGeneration(from: "Apple M4") == 4)
        assert(HardwareTier.appleSiliconGeneration(from: "Apple M2 Pro") == 2)
        assert(HardwareTier.appleSiliconGeneration(from: "Apple M12") == 12)
        assert(HardwareTier.appleSiliconGeneration(from: "Intel(R) Core(TM) i7") == nil)
        assert(HardwareTier.appleSiliconGeneration(from: "Apple M Pro") == nil)
    }

    /// Chip-passing (but RAM-short) Macs get the memory note; chip-failing Macs
    /// get the chip note regardless of RAM.
    static func test_gateNoteVariants() {
        assert(LanguageChoice.hardwareGateNote(chipClearsTier: true)
                   == "Needs a Mac with 16 GB memory or more",
               "chip-passing note must name the memory bar")
        assert(LanguageChoice.hardwareGateNote(chipClearsTier: false)
                   == "Needs a newer Apple Silicon chip (M2 Pro or M4 and later)",
               "chip-failing note must name the chip bar")
    }
}
#endif
