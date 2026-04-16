import AppKit
import SwiftUI

/// Floating, borderless, click-through-by-default NSPanel that hosts the
/// SwiftUI Dynamic Island-style pill. Lives above normal windows
/// (`.screenSaver` level) and survives Space switches.
///
/// The panel is created sized for the pill's natural footprint; the SwiftUI
/// pill itself manages internal expansion/collapse via `matchedGeometryEffect`
/// so the window frame is static per-state (we resize the window when the
/// *state* changes, not every animation frame).
final class OverlayPanel: NSPanel {
    init(rootView: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .screenSaver
        self.isOpaque = false
        // NSWindow-level shadow is off entirely — when the panel sits flush to
        // the top of the screen, AppKit's drop shadow has nowhere to render
        // above the window and clips into a squiggly artifact at the screen
        // edge. The SwiftUI capsule draws its own shadow inside the pill view.
        self.hasShadow = false
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: AnyView(rootView))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear

        let container = NSView(frame: self.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = CGColor.clear
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        self.contentView = container

        // Some AppKit paths reset backgroundColor after contentView is
        // assigned. Set it here, last, so nothing clobbers it.
        self.backgroundColor = NSColor.clear
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
