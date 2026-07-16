import Foundation

/// Pure resolver for the Advanced-only "Transcription model" picker in
/// Settings → General.
///
/// The picker normally offers `ParakeetModelID.visibleCases`, but the model
/// the user is ACTUALLY running (`TranscriberHolder.activeModelID`) can be one
/// that was auto-routed by language and never appears as a selectable row —
/// e.g. `.nemotron_multilingual_latin` on a ≥24 GB Mac speaking Spanish. In
/// that case the control must still display the real active model's name with a
/// caption explaining it was chosen automatically for the current language.
///
/// A pending download-then-flip switch (menu-bar or Settings-initiated) is
/// reflected too: the picker shows the target the user chose while it downloads,
/// mirroring how the language picker prefers `pendingLanguage`.
///
/// Extracted as a pure struct so the display decision is unit-testable without a
/// SwiftUI environment (`ModelPickerDisplayTests`).
struct ModelPickerDisplay: Equatable {
    /// The model the picker should reflect as its current selection: the
    /// in-flight pending target if one is downloading, otherwise the active
    /// model.
    let selectedID: ParakeetModelID
    /// `true` when `selectedID` is not one of the directly-selectable
    /// `visibleCases` — i.e. it was auto-routed by the active language and needs
    /// an extra, explanatory row so the menu can show its name.
    let selectedIsAutoRouted: Bool
    /// Caption to render beneath the picker when the active model was auto-routed;
    /// `nil` when the selection is a normal selectable row.
    let autoRouteCaption: String?

    static func resolve(
        active: ParakeetModelID,
        pendingTarget: ParakeetModelID?,
        language: LanguageChoice
    ) -> ModelPickerDisplay {
        let selected = pendingTarget ?? active
        let isVisible = ParakeetModelID.visibleCases.contains(selected)
        let caption = isVisible
            ? nil
            : "\(selected.displayName) — chosen automatically for \(language.displayName)"
        return ModelPickerDisplay(
            selectedID: selected,
            selectedIsAutoRouted: !isVisible,
            autoRouteCaption: caption
        )
    }
}
