import SwiftUI

/// Shared dimensions for the binding chip in every Shortcuts row.
/// Single source of truth so `ShortcutSingleKeyChip` (a SwiftUI
/// rounded-rect) and `ShortcutChordChip` (a `KeyboardShortcuts.Recorder`
/// wrapping an NSView) line up pixel-for-pixel in the same column.
enum ShortcutChipSize {
    static let width: CGFloat = 150
    static let height: CGFloat = 26
}
