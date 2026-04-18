import AppKit

/// Proxy `NSWindowDelegate` installed on the unified Jot window so that
/// clicking the red close button hides the window instead of destroying
/// the SwiftUI `Window` scene.
///
/// The app runs as a menu-bar agent (`LSUIElement = true`), so if the
/// scene is torn down the user has no way to reopen it from AppKit
/// chrome — they'd have to use the menu-bar extra. Hiding (via
/// `orderOut(_:)`) keeps the scene and its state tree alive so the menu
/// bar's "Open Jot…" / "Settings…" items can just re-order-front.
///
/// Critically, this is a **proxy** delegate — it forwards every
/// selector to SwiftUI's own delegate via `forwardingTarget(for:)`, and
/// only intercepts `windowShouldClose(_:)`. Setting our delegate
/// directly would evict SwiftUI's delegate and break the scene
/// lifecycle (window restoration, first-responder bookkeeping,
/// commands routing).
@MainActor
final class MainWindowCloseInterceptor: NSObject, NSWindowDelegate {
    /// The SwiftUI-provided delegate we snapshot at install time.
    /// `weak` so we don't keep a torn-down scene's delegate alive.
    weak var wrappedDelegate: NSWindowDelegate?

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(windowShouldClose(_:)) { return true }
        return wrappedDelegate?.responds(to: aSelector) ?? super.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        // Keep `windowShouldClose` on us; everything else flows to
        // SwiftUI's original delegate (or nil if it has gone away).
        if aSelector == #selector(windowShouldClose(_:)) { return nil }
        return wrappedDelegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
