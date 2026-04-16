import AppKit

/// Computes where the Dynamic Island-style pill should live on a given screen.
///
/// - Notch Macs (`safeAreaInsets.top > 0`): top edge of the pill is flush with
///   the bottom of the menu bar, directly under the notch cutout. The notch's
///   horizontal center is always the screen's `midX`, so we center the pill
///   there.
/// - Non-notch Macs: the pill floats just below the menu bar, horizontally
///   centered on the screen, with a small breathing gap.
enum OverlayPlacement {
    /// Gap between the menu bar's lower edge and the pill's top edge on
    /// non-notch displays. Tight but not kissing — lets the drop shadow read.
    static let nonNotchGap: CGFloat = 4

    /// Returns the frame (bottom-left origin, screen coordinates) for a pill
    /// of the given size on the given screen.
    static func frame(for size: NSSize, on screen: NSScreen) -> NSRect {
        let visibleTop = screen.frame.maxY
        let topInset = screen.safeAreaInsets.top
        let centerX = screen.frame.midX - size.width / 2

        if topInset > 0 {
            // Notch display — park the pill's top edge flush under the menu
            // bar (i.e. flush under the notch's lower edge).
            let y = visibleTop - topInset - size.height
            return NSRect(x: centerX, y: y, width: size.width, height: size.height)
        } else {
            // Non-notch — menu bar is ~24 pt tall on every modern Mac we
            // support; `frame.maxY - visibleFrame.maxY` is the exact value.
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            let y = visibleTop - menuBarHeight - size.height - nonNotchGap
            return NSRect(x: centerX, y: y, width: size.width, height: size.height)
        }
    }

    /// Resolves the "current" screen — the one the user is looking at now.
    /// Prefers the screen containing the focused window, then `NSScreen.main`,
    /// then any screen. Returns nil only if there are no screens (can't
    /// happen in practice but the API is optional).
    static func currentScreen() -> NSScreen? {
        if let screen = NSApp.keyWindow?.screen { return screen }
        if let main = NSScreen.main { return main }
        return NSScreen.screens.first
    }
}
