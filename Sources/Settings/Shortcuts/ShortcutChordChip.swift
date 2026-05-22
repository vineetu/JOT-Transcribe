import KeyboardShortcuts
import SwiftUI

/// Inline chord-recorder rendered as the row's binding chip when the
/// action's effective trigger type is `.chord`.
///
/// Wraps `KeyboardShortcuts.Recorder` directly — that view is itself a
/// click-to-record AppKit field, which is exactly the affordance the
/// redesign wants: a clickable chip showing the current combo. We keep
/// the framework's recorder (instead of writing a bespoke popover-style
/// recorder) because:
///   • It already handles modifier-required validation, system-shortcut
///     deduping, and the recording focus ring per macOS HIG.
///   • Stays under the "minimal risk" bar from the design doc — the
///     storage shape (`KeyboardShortcuts` UserDefaults) is unchanged.
///   • Avoids the popover-recorder risk callout in the plan: a focused
///     popover hosting an `NSTextField`-backed recorder has known
///     accessibility / focus quirks in nested SwiftUI presentations.
///
/// The `onChange` callback bumps a `refreshToken` in the parent so the
/// conflict banner (and any view that has cached the current
/// `KeyboardShortcuts.getShortcut(...)` lookup) re-renders on commit.
struct ShortcutChordChip: View {
    let action: SingleKey.Action
    let onChange: () -> Void

    var body: some View {
        KeyboardShortcuts.Recorder(for: action.keyboardShortcutsName) { _ in
            onChange()
        }
        .fixedSize()
    }
}
