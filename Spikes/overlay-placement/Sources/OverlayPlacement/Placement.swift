import AppKit

enum Placement {
    /// Pill footprint roughly matching a Dynamic Island under the notch.
    static let pillSize = NSSize(width: 200, height: 35)

    /// Returns the origin (bottom-left, in screen coordinates) to place a pill.
    /// Uses NSScreen.safeAreaInsets.top to detect a notch. Falls back to centered under menu bar.
    static func origin(for screen: NSScreen, pillSize: NSSize = pillSize) -> NSPoint {
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top
        let centerX = frame.midX - pillSize.width / 2

        if topInset > 0 {
            // Notch Mac: park flush under the notch footprint.
            let topY = frame.maxY - topInset - pillSize.height - 2
            return NSPoint(x: centerX, y: topY)
        } else {
            // Non-notch: center under the menu bar (~24 px tall on most Macs).
            let menuBarHeight: CGFloat = 24
            let topY = frame.maxY - menuBarHeight - pillSize.height - 4
            return NSPoint(x: centerX, y: topY)
        }
    }
}
