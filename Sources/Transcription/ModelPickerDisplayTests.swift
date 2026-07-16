#if DEBUG
import Foundation

/// DEBUG-only runtime tests for the Advanced-only Settings model-picker display
/// resolver (`ModelPickerDisplay.resolve`).
///
/// Mirrors the `ModelSwitchTests` / `LanguageVisibilityTests` pattern — no
/// XCTest dependency (Jot's XCTest target is currently broken); the suite is
/// called once from `AppDelegate.applicationDidFinishLaunching` in DEBUG so a
/// miss fires at launch.
///
/// Scope: the pure "what does the picker show?" decision — pending-target
/// precedence, and the auto-routed-active-model case where the active model is
/// absent from `visibleCases` and must be surfaced with a caption instead of
/// dropped.
enum ModelPickerDisplayTests {
    static func runAll() {
        test_visibleActive_noPending_selectsActive()
        test_autoRoutedActive_surfacedWithCaption()
        test_pendingTarget_overridesActive()
        test_pendingVisible_whileActiveAutoRouted_notAutoRouted()
    }

    /// A normal selectable active model with no pending switch: the picker
    /// reflects it, no auto-route treatment.
    static func test_visibleActive_noPending_selectsActive() {
        let d = ModelPickerDisplay.resolve(
            active: .tdt_0_6b_v3_eou_streaming,
            pendingTarget: nil,
            language: .english
        )
        assert(d.selectedID == .tdt_0_6b_v3_eou_streaming)
        assert(!d.selectedIsAutoRouted)
        assert(d.autoRouteCaption == nil)
    }

    /// The active model was auto-routed by language and isn't in `visibleCases`:
    /// it must still be the selection, flagged auto-routed, with a caption that
    /// names the language.
    static func test_autoRoutedActive_surfacedWithCaption() {
        let d = ModelPickerDisplay.resolve(
            active: .nemotron_multilingual_latin,
            pendingTarget: nil,
            language: .spanish
        )
        assert(d.selectedID == .nemotron_multilingual_latin)
        assert(d.selectedIsAutoRouted)
        assert(d.autoRouteCaption?.contains(LanguageChoice.spanish.displayName) == true,
               "auto-route caption must name the active language")
    }

    /// A pending download-then-flip target wins over the active model so the
    /// picker shows the user's choice mid-download.
    static func test_pendingTarget_overridesActive() {
        let d = ModelPickerDisplay.resolve(
            active: .tdt_0_6b_v3_eou_streaming,
            pendingTarget: .nemotron_en,
            language: .english
        )
        assert(d.selectedID == .nemotron_en)
        assert(!d.selectedIsAutoRouted)
        assert(d.autoRouteCaption == nil)
    }

    /// Pending target is a visible model while the active one is auto-routed:
    /// the visible pending target wins and gets no auto-route treatment.
    static func test_pendingVisible_whileActiveAutoRouted_notAutoRouted() {
        let d = ModelPickerDisplay.resolve(
            active: .nemotron_multilingual_latin,
            pendingTarget: .tdt_0_6b_ja,
            language: .spanish
        )
        assert(d.selectedID == .tdt_0_6b_ja)
        assert(!d.selectedIsAutoRouted)
        assert(d.autoRouteCaption == nil)
    }
}
#endif
