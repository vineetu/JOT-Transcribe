import AppKit
import SwiftUI

/// A geometry-only drag layer that lives BELOW the SwiftUI hosting view
/// (movable pill v2, design §B/§D.1). It exists so the borderless overlay
/// panel can be dragged by its visible capsule in EVERY pill state without
/// reverse-engineering SwiftUI's internal hit-testing.
///
/// Z-order is the whole mechanism: SwiftUI controls sit ABOVE this view, so
/// AppKit hit-tests them first and they win taps purely by being higher in the
/// view tree. Only pixels the hosting view declines fall through to this view.
/// Its `hitTest` decides drag-vs-margin by capsule *geometry alone*:
///   - inside the capsule rect  → return `self` (a press there drags the window)
///   - in the transparent margin → return `nil` (the click falls through to the
///     app behind the pill — true per-pixel click-through)
///
/// `mouseDown` here is the FALLBACK capsule-background drag path. The PRIMARY
/// tap-vs-drag arbiter on the capsule is the SwiftUI escalation gesture in
/// `PillView`, which calls `OverlayPanel.beginUserDrag()` directly. Both share
/// this view's `hitTest` for margin click-through.
final class OverlayDragView: NSView {
    /// Capsule rect (in THIS view's non-flipped AppKit coordinates) that should
    /// grab the mouse for dragging. Controller-installed (with `[weak self]`),
    /// refreshed whenever the pill's size/expansion changes. `.zero` means the
    /// whole view is click-through (hidden state).
    var pillRectProvider: () -> CGRect = { .zero }

    /// Notifies the controller that a window drag is starting (`true`) / ended
    /// (`false`) so its outside-click monitors can early-return during a drag
    /// (design §D.2, HIGH 2). Controller-installed with `[weak self]`.
    var isDraggingProvider: (Bool) -> Void = { _ in }

    /// The panel is `.nonactivatingPanel` with `canBecomeKey == false`, so
    /// without this the first press on the pill is eaten as an activation click
    /// and the drag silently won't start until Jot is frontmost (design §C).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // SwiftUI controls are ABOVE this view → AppKit already gave them first
        // refusal; we only see pixels they declined. Decide drag-vs-margin by
        // geometry alone — never probe the hosting view.
        if pillRectProvider().contains(point) { return self }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        // Fallback capsule-background drag path (the SwiftUI escalation gesture
        // is the primary arbiter). `performDrag` is synchronous: it runs
        // AppKit's modal drag-tracking loop and returns when the mouse is
        // released, so toggling the flag around it is safe.
        isDraggingProvider(true)
        window?.performDrag(with: event)
        isDraggingProvider(false)
    }
}

/// `NSHostingView` that is click-through OUTSIDE the pill. The stable canvas is
/// large (≈664×444) and this host fills it sitting ABOVE the drag layer, so a
/// plain `NSHostingView` swallows every click across the whole transparent
/// canvas — blocking text selection / clicks in the app beneath while the pill
/// is visible. Gating `hitTest` to the capsule rect (the SAME rect the drag
/// view uses) makes everything outside the pill pass through, while taps INSIDE
/// the capsule still reach SwiftUI controls (ask buttons, drag) exactly as
/// before. `{ .zero }` ⇒ fully transparent (hidden state).
final class ClickThroughHostingView: NSHostingView<AnyView> {
    var pillRectProvider: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard pillRectProvider().contains(point) else { return nil }
        return super.hitTest(point)
    }

    @MainActor required init(rootView: AnyView) { super.init(rootView: rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
}

/// Floating, borderless, click-through-by-default NSPanel that hosts the
/// SwiftUI Dynamic Island-style pill. Lives above normal windows
/// (`.screenSaver` level) and survives Space switches.
///
/// The panel is created sized for the pill's natural footprint; the SwiftUI
/// pill itself manages internal expansion/collapse via `matchedGeometryEffect`
/// so the window frame is static per-state (we resize the window when the
/// *state* changes, not every animation frame).
final class OverlayPanel: NSPanel {
    /// The geometry-only drag layer below the hosting view. Exposed so the
    /// controller can install `pillRectProvider` / `isDraggingProvider`.
    let dragView = OverlayDragView()
    /// The SwiftUI host, exposed so the controller can install the same
    /// capsule-rect provider used by the drag layer — keeping the large canvas
    /// click-through outside the pill (otherwise it swallows clicks beneath).
    let hostingView: ClickThroughHostingView

    init(rootView: some View) {
        self.hostingView = ClickThroughHostingView(rootView: AnyView(rootView))
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

        let hosting = hostingView
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear

        let container = NSView(frame: self.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = CGColor.clear

        // Movable pill v2 (design §B/§D.1): the geometry-only drag layer sits
        // BELOW the hosting view so SwiftUI controls hit-test first and win taps
        // by Z-order; only pixels they decline reach the drag view. Added (and
        // constrained) BEFORE the hosting view so it is lower in the subview
        // stack.
        dragView.translatesAutoresizingMaskIntoConstraints = false
        dragView.wantsLayer = true
        dragView.layer?.backgroundColor = CGColor.clear
        container.addSubview(dragView)

        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            dragView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dragView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dragView.topAnchor.constraint(equalTo: container.topAnchor),
            dragView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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

    /// Window-level drag entry for `PillView`'s escalation gesture (design
    /// §D.1). Reads the current mouse event and starts AppKit's window-server
    /// drag, bracketing it with the controller's drag flag so the outside-click
    /// monitors early-return during the drag (HIGH 2). `performDrag` is
    /// synchronous (runs the modal drag-tracking loop), so the flag is cleared
    /// the moment the drag ends.
    func beginUserDrag() {
        guard let event = self.currentEvent ?? NSApp.currentEvent else { return }
        dragView.isDraggingProvider(true)
        performDrag(with: event)
        dragView.isDraggingProvider(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
