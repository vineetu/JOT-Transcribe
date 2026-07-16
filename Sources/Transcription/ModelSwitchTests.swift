#if DEBUG
import Foundation

/// DEBUG-only runtime tests for the manual model/language **switch routing**
/// decision (`TranscriberHolder.languageSwitchNeedsDownload`).
///
/// Mirrors the `AdvancedFlagTests` / `DockActivationPolicyTests` pattern — no
/// XCTest dependency (Jot's XCTest target is currently broken), the suite is
/// called once from `AppDelegate.applicationDidFinishLaunching` in DEBUG so a
/// miss fires at launch.
///
/// Scope: the *pure* routing predicate — "does this switch download-then-flip,
/// or flip immediately?" — which is exactly the bug this change fixes (manual
/// switches used to flip before the model was on disk). The async
/// download-then-flip flow itself (`beginPendingSwitch`, generation supersede)
/// is MainActor + network-bound and is verified by build + manual runtime, not
/// here — a synchronous launch harness can't await it without risking a
/// launch-time deadlock.
enum ModelSwitchTests {
    static func runAll() {
        test_englishRepickOnNemotron_noDownload()
        test_englishRepickOnV2_noDownload()
        test_resolvedEqualsPrimary_noDownload()
        test_differentModelInstalled_noDownload()
        test_differentModelNotInstalled_downloadThenFlip()
    }

    /// Re-picking English while stored on Nemotron (English-only): no-clobber,
    /// the model is untouched, so no download.
    static func test_englishRepickOnNemotron_noDownload() {
        let needs = TranscriberHolder.languageSwitchNeedsDownload(
            lang: .english,
            resolved: LanguageChoice.english.modelID(),
            primary: .nemotron_en,
            isResolvedInstalled: false
        )
        assert(!needs, "English re-pick on Nemotron must not download")
    }

    /// Same no-clobber rule for the other English-only stored model, v2.
    static func test_englishRepickOnV2_noDownload() {
        let needs = TranscriberHolder.languageSwitchNeedsDownload(
            lang: .english,
            resolved: LanguageChoice.english.modelID(),
            primary: .tdt_0_6b_v2_en_streaming,
            isResolvedInstalled: false
        )
        assert(!needs, "English re-pick on v2 must not download")
    }

    /// The resolved model already IS the primary → hint rebuild only, no
    /// download, regardless of installed-state.
    static func test_resolvedEqualsPrimary_noDownload() {
        let needs = TranscriberHolder.languageSwitchNeedsDownload(
            lang: .japanese,
            resolved: .tdt_0_6b_ja,
            primary: .tdt_0_6b_ja,
            isResolvedInstalled: false
        )
        assert(!needs, "Re-picking the current model's language must not download")
    }

    /// A genuinely different model that's already on disk → immediate flip.
    static func test_differentModelInstalled_noDownload() {
        let needs = TranscriberHolder.languageSwitchNeedsDownload(
            lang: .japanese,
            resolved: .tdt_0_6b_ja,
            primary: .tdt_0_6b_v3_eou_streaming,
            isResolvedInstalled: true
        )
        assert(!needs, "Switching to an already-installed model must flip immediately")
    }

    /// The fix: a different model that is NOT on disk → download-then-flip
    /// (the old code flipped immediately and stranded the transcriber).
    static func test_differentModelNotInstalled_downloadThenFlip() {
        let needs = TranscriberHolder.languageSwitchNeedsDownload(
            lang: .japanese,
            resolved: .tdt_0_6b_ja,
            primary: .tdt_0_6b_v3_eou_streaming,
            isResolvedInstalled: false
        )
        assert(needs, "Switching to a not-installed model must download before flipping")
    }
}
#endif
