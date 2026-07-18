import AppKit

/// Computes where the Dynamic Island-style pill should live on a given screen.
///
/// - Notch Macs (`safeAreaInsets.top > 0`): pill occupies the notch strip —
///   its top edge is flush with the top of the screen so it visually "grows
///   from" the notch with no gap between pill and menu bar. The notch's
///   horizontal center is always `screen.frame.midX`, so we center there.
/// - Non-notch Macs: pill top edge is flush with the top of the screen
///   (overlapping the menu bar), matching the "grows from the top" feel.
enum OverlayPlacement {
    /// Returns the frame (bottom-left origin, screen coordinates) for a pill
    /// of the given size on the given screen.
    static func frame(for size: NSSize, on screen: NSScreen) -> NSRect {
        let screenTop = screen.frame.maxY
        let centerX = screen.frame.midX - size.width / 2

        if screen.safeAreaInsets.top > 0 {
            // Notch display — pin the pill's top edge to the top of the screen
            // so it occupies the notch strip. `origin.y` in AppKit (bottom-left
            // origin) is `screenTop - size.height`.
            let y = screenTop - size.height
            return NSRect(x: centerX, y: y, width: size.width, height: size.height)
        } else {
            // Non-notch — sit flush at the very top of the screen, overlapping
            // the menu bar area for the same "grows from notch" visual cue.
            let y = screenTop - size.height
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

    /// Resolves the display the user is actually working on, MOUSE-FIRST.
    ///
    /// Why mouse-first (and not `NSScreen.main`): `NSScreen.main` is documented
    /// as the screen containing the *key window*. Jot is a non-activating
    /// menu-bar app with no key window (the pill panel is `canBecomeKey == false`
    /// and the typed pane takes key WITHOUT activating), so `NSScreen.main`
    /// resolves to whatever *other* app owns the key window — reliably the WRONG
    /// display in a multi-monitor setup. The cursor, by contrast, is where the
    /// user just pressed the hotkey, so the screen under it is the best proxy for
    /// where their attention is — and it needs no extra permission to read.
    /// Falls back to `NSScreen.main`, then any screen, only if the cursor somehow
    /// isn't over a known display.
    static func activeScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
