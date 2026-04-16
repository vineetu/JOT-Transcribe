import AppKit

@MainActor
final class OverlayController {
    private var window: OverlayWindow?

    func show() {
        let rect = NSRect(origin: .zero, size: Placement.pillSize)
        let w = OverlayWindow(contentRect: rect)
        window = w
        replace()
        w.orderFrontRegardless()
    }

    func replace() {
        guard let window else { return }
        guard let screen = currentScreen() else {
            NSLog("[OverlayPlacement] no screen — skipping placement")
            return
        }
        let origin = Placement.origin(for: screen)
        window.setFrameOrigin(origin)
        NSLog(
            "[OverlayPlacement] placed on screen %@ inset.top=%.1f origin=(%.0f,%.0f)",
            "\(screen.localizedName)",
            screen.safeAreaInsets.top,
            origin.x, origin.y
        )
    }

    private func currentScreen() -> NSScreen? {
        // Prefer the screen containing the cursor; fall back to main.
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return hit
        }
        return NSScreen.main
    }
}
