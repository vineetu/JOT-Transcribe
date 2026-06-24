import AppKit
import Combine
import SwiftUI
import os.log

/// Owns the overlay `NSPanel`, the `PillViewModel`, and the placement lifecycle.
/// Call `install()` from `AppDelegate.applicationDidFinishLaunching` after the
/// recorder + delivery services are live.
@MainActor
final class OverlayWindowController {
    private let log = Logger(subsystem: "com.jot.Jot", category: "Overlay")

    private let recorder: RecorderController
    private let delivery: DeliveryService
    private let rewriteController: RewriteController?
    private let pipeline: VoiceInputPipeline
    /// Exposed read-only so the hotkey router can drive
    /// `.holdProgress` transitions for the Prompt Picker entry path.
    /// All other consumers should stick to the published `state`
    /// stream rather than poking the view model directly.
    let pillViewModel: PillViewModel
    private var model: PillViewModel { pillViewModel }
    private let amplitudePublisher = AmplitudePublisher()

    private var panel: OverlayPanel?
    private var screenChangeObserver: NSObjectProtocol?
    private var reduceMotionObserver: NSObjectProtocol?
    private var stateCancellable: AnyCancellable?
    private var expansionCancellable: AnyCancellable?
    private var streamingActiveCancellable: AnyCancellable?
    /// Slice D: installs the outside-click monitors while an ask is awaiting so
    /// a click anywhere off the pill resolves it to keep-original.
    private var askActiveCancellable: AnyCancellable?
    /// Movable pill (v2): observes `NSWindow.didMoveNotification` for the panel
    /// so a window-server drag (`performDrag`) can be captured into
    /// `committedDelta` when it lands.
    private var windowMoveObserver: NSObjectProtocol?

    /// Movable pill (v2, design §D.2): session-only center delta from the
    /// natural (default) window position, captured on drag end and re-applied in
    /// every `updateFrame()`. In-memory only — NOT persisted; resets to `.zero`
    /// on relaunch and on a resolved-screen change. A CENTER delta (not
    /// top-left) preserves the center-anchor semantics so a later width change
    /// re-centers around the dragged position.
    private var committedDelta: CGSize = .zero

    /// Movable pill (v2, design §D.2 / HIGH 2): set `true` for the duration of a
    /// `performDrag` so BOTH outside-click monitors early-return and a drag of an
    /// expanded / awaiting-ask pill never self-dismisses it.
    private var isDraggingWindow = false

    /// Drives per-cursor click-through. A borderless panel only lets clicks reach
    /// the app beneath when `ignoresMouseEvents == true`; returning nil from
    /// `hitTest` merely SWALLOWS the click. So while the pill is visible we poll
    /// the cursor and set `ignoresMouseEvents` false ONLY while it's over the
    /// capsule (so the pill stays draggable/tappable), true everywhere else.
    private var cursorTrackTimer: Timer?

    /// Movable pill (v1→v2, design §D.2): the `NSScreenNumber` of the screen the
    /// current `committedDelta` was set on. `NSScreen` has no stable identity
    /// across display reconfiguration, so we key the reset on this device number
    /// rather than object identity. When the resolved screen differs, the delta
    /// is meaningful only on the screen it was set on, so we reset it to `.zero`.
    /// `nil` means "no delta committed on any screen yet".
    private var dragOffsetScreenNumber: NSNumber?

    /// NSEvent monitors installed while the pill is expanded so any
    /// click outside the pill's panel collapses it. Cleared when the
    /// pill collapses (either via the tap-to-toggle path or via these
    /// monitors themselves) and in `deinit`. `Any?` because
    /// `addGlobalMonitorForEvents` / `addLocalMonitorForEvents` return
    /// an opaque token. See `applyOutsideClickMonitor(expanded:)`.
    private var outsideClickGlobalMonitor: Any?
    private var outsideClickLocalMonitor: Any?

    /// Natural footprint of the compact pill (visual surface, not including
    /// shadow). Error pills can grow beyond this, up to `expandedPillWidth`.
    static let compactPillWidth: CGFloat = PillView.compactPillWidth
    static let expandedPillWidth: CGFloat = PillView.expandedPillWidth
    /// Width used when the recording pill is showing a streaming
    /// partial. Single source of truth on `PillView` so layout / window
    /// sizing can't drift apart.
    static let streamingPillWidth: CGFloat = PillView.streamingPillWidth
    static let pillHeight: CGFloat = PillView.pillHeight
    static let horizontalPadding: CGFloat = 12
    static let bottomPadding: CGFloat = 24
    /// Upper bound for the dynamically-grown ask pill so a pathological measured
    /// height can't run off-screen (clampCapsuleOnScreen is the final guard anyway).
    static let maxAskHeight: CGFloat = 420
    private static let errorChromeWidth: CGFloat = expandedPillWidth - PillView.errorTextMaxWidth

    /// Stable-canvas (v3): the overlay window is a FIXED-size transparent canvas
    /// sized to the LARGEST pill state. The visible capsule is sized per-state by
    /// SwiftUI and floats top-center INSIDE this canvas, so content changes (live
    /// preview text, ask-pill growth, expansion) never resize or reposition the
    /// window — only the capsule animates within it. The window is the single
    /// drag target; text reflows inside it, so content-resize and drag can never
    /// collide (the snap-back-during-dictation bug class is structurally
    /// impossible, not merely suppressed). The capsule's on-screen position is
    /// what we clamp — the larger canvas may hang off-screen (it's transparent
    /// and per-pixel click-through).
    static let canvasContentWidth: CGFloat = max(expandedPillWidth, PillView.expandedRecordingWidth)
    static let canvasContentHeight: CGFloat = max(PillView.expandedRecordingHeight, maxAskHeight)

    /// The fixed canvas window size (largest content + shadow/padding room).
    private var canvasWindowSize: NSSize {
        NSSize(
            width: Self.canvasContentWidth + Self.horizontalPadding * 2,
            height: Self.canvasContentHeight + Self.bottomPadding
        )
    }

    init(
        recorder: RecorderController,
        delivery: DeliveryService,
        rewriteController: RewriteController? = nil,
        pipeline: VoiceInputPipeline,
        transcriberHolder: TranscriberHolder? = nil
    ) {
        self.recorder = recorder
        self.delivery = delivery
        self.rewriteController = rewriteController
        self.pipeline = pipeline
        self.pillViewModel = PillViewModel(
            recorder: recorder,
            delivery: delivery,
            rewriteController: rewriteController,
            transcriberHolder: transcriberHolder
        )
    }

    func install() {
        pipeline.setAmplitudePublisher(amplitudePublisher)
        // Movable pill (v2): the panel is created first so the escalation
        // closure can capture it; PillView hands off to `panel.beginUserDrag()`
        // when a press crosses the slop threshold.
        var capturedPanel: OverlayPanel?
        let rootView = PillView(
            model: model,
            onDragEscalate: { capturedPanel?.beginUserDrag() }
        )
        .environmentObject(amplitudePublisher)
        let panel = OverlayPanel(rootView: rootView)
        capturedPanel = panel
        self.panel = panel

        // Movable pill (v2, design §D.1/§D.2): install the geometry-only drag
        // layer's providers. `pillRectProvider` returns the current capsule rect
        // (refreshed by `applyClickThrough`); `isDraggingProvider` flips the
        // monitor guard around a `performDrag` (HIGH 2). Both capture `[weak
        // self]` to avoid a controller↔panel↔dragView retain cycle (LOW 1).
        panel.dragView.pillRectProvider = { [weak self, weak panel] in
            guard let self, let panel else { return .zero }
            return self.capsuleRect(for: self.model.state, in: panel)
        }
        panel.dragView.isDraggingProvider = { [weak self] dragging in
            guard let self else { return }
            let wasDragging = self.isDraggingWindow
            self.isDraggingWindow = dragging
            // Movable pill (v2): on drag END, deterministically capture the
            // landed position and re-apply the frame. While the drag is in
            // flight, `updateFrame()` suppresses its `setFrame` so a live-preview
            // state change (or ask-height / expansion update) landing mid-drag
            // can't fight the window-server drag and yank the pill back to its
            // start (the snap-back-during-dictation bug). The size/position
            // change suppressed during the drag is applied here, once, at the
            // dragged center.
            if wasDragging && !dragging {
                self.finalizeDrag()
            }
        }

        updateFrame(for: model.state)
        // Panel stays ordered-front at all times — we toggle visibility/click
        // behaviour off of the model's published state instead of showing and
        // hiding the window, so the SwiftUI transitions can play.
        panel.orderFrontRegardless()

        // Re-place on screen-parameter changes: resolution change, external
        // display plug/unplug, HiDPI toggle, dock re-positioning.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFrame()
            }
        }

        // Reduce Motion: the view reads @Environment(\.accessibilityReduceMotion)
        // so SwiftUI re-renders automatically when the system preference
        // flips. The notification listener here is belt-and-suspenders in case
        // we ever add non-SwiftUI motion (e.g. Core Animation on the panel).
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.panel?.invalidateShadow()
            }
        }

        // Click-through policy: follow pill state via `applyClickThrough`.
        // The panel is hittable in EVERY visible state (so the drag layer can
        // grab the capsule from any state); per-pixel click-through to the app
        // below is handled by the drag view's geometry-only hitTest, and the
        // panel is fully click-through only when `.hidden`.
        //
        // Stable-canvas (v3): we DO NOT reposition the window here. The window is
        // a fixed-size canvas placed once at `install()`; content changes only
        // resize the capsule INSIDE it (via SwiftUI), never the window. Crucially
        // the per-second elapsed-timer tick flows through `$state` (elapsed is
        // part of `.recording(elapsed:)`), so calling `updateFrame` here would
        // re-set the window's position every second and yank it back from wherever
        // the user dragged it — the periodic snap-back bug. The only programmatic
        // `setFrame` writers are `install()` (initial placement), the screen-change
        // observer (re-place on a display reconfiguration), and `finalizeDrag()`
        // (one-time on-screen clamp at drag end). The window server owns the
        // position the rest of the time.
        stateCancellable = model.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.applyClickThrough(for: state)
            }
        // Expand/collapse only (un)installs the outside-click monitors that
        // dismiss the expanded pill. No reframe: the expanded recording capsule
        // grows INSIDE the fixed canvas (v3), so the window neither moves nor
        // resizes.
        expansionCancellable = model.$isPillExpanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshOutsideClickMonitor()
            }
        // Refresh click-through when a streaming session begins or
        // ends. Without this, a v3-then-streaming sequence would keep
        // the v3 ignoresMouseEvents=true setting through the streaming
        // session and the user couldn't tap to expand.
        streamingActiveCancellable = model.$isStreamingSessionActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyClickThrough(for: self.model.state)
            }
        // Stable-canvas (v3): the ask pill grows vertically INSIDE the fixed
        // canvas (its max height equals the canvas content height), so a taller
        // measured height needs no window reframe — SwiftUI lays it out within
        // the stationary canvas. The old `$measuredAskHeight → updateFrame` sink
        // is gone (it was a per-content reframe, the class of call that caused the
        // snap-back).
        // Slice D: while an ask is awaiting, a click anywhere off the pill
        // resolves it to keep-original (the safe default, §2). Reuse the same
        // outside-click monitor pair the expanded pill uses.
        askActiveCancellable = model.$isAwaitingAskCorrection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshOutsideClickMonitor()
            }
        // Movable pill (v2, design §D.2): capture a window-server drag into
        // `committedDelta` when the panel lands. `performDrag` moves the window
        // directly (not via `setFrame`), so we observe `didMoveNotification`
        // rather than driving an offset. `updateFrame()` stays the single
        // PROGRAMMATIC `setFrame` writer; the drag path is the window server.
        windowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.windowDidMove()
            }
        }
    }

    /// Movable pill (v2, design §D.2): the panel moved during a window-server
    /// drag. Capture the new position live. The authoritative capture is
    /// `finalizeDrag()` at drag end (deterministic, not subject to the async
    /// `didMove` Task race); this live observer is belt-and-suspenders and only
    /// acts on real user drags by gating on `isDraggingWindow`. Programmatic
    /// moves can't reach here mid-drag because `updateFrame()` early-returns
    /// while `isDraggingWindow` is set.
    private func windowDidMove() {
        guard isDraggingWindow else { return }
        captureCommittedDelta()
    }

    /// Movable pill (v2, design §D.2): record the panel's CURRENT position as a
    /// center delta from the natural frame for the current state, and re-key the
    /// multi-display reset off the landed screen. A center delta (not top-left)
    /// is size-independent, so a size change suppressed during the drag
    /// (compact→streaming width, ask growth) re-centers around the dragged
    /// position rather than jumping. We do NOT clamp here — `performDrag` already
    /// constrained the drop to the screen, and `updateFrame()` clamps on apply.
    private func captureCommittedDelta() {
        guard let panel else { return }
        guard let natural = naturalWindowFrame(for: model.state) else { return }
        committedDelta = CGSize(
            width: panel.frame.midX - natural.midX,
            height: panel.frame.midY - natural.midY
        )
        // MEDIUM 1: derive the landed display from `panel.screen` (the screen
        // containing the window frame), NOT `OverlayPlacement.currentScreen()` —
        // the panel can never be `keyWindow` (`canBecomeKey == false`), so
        // `currentScreen()` would track some other window's screen.
        let landedScreen = panel.screen
            ?? NSScreen.screens.first { $0.frame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.midY)) }
        if let landedScreen {
            dragOffsetScreenNumber = Self.screenNumber(of: landedScreen)
        }
    }

    /// Movable pill (v2): a window-server drag just ended. `performDrag` returns
    /// synchronously and the drag flag clears on the same call stack, so the
    /// async `didMove` Tasks queued during the drag can run AFTER the flag clears
    /// and be skipped — capture the landed position here deterministically
    /// instead. Then re-apply the frame (now that `isDraggingWindow` is false, so
    /// `updateFrame` no longer suppresses `setFrame`) to pick up any size change
    /// that was deferred during the drag, landing it at the dragged center.
    private func finalizeDrag() {
        captureCommittedDelta()
        updateFrame()
    }

    /// Outside-click monitors are needed while EITHER the recording pill is
    /// expanded OR an ask is awaiting. Single source of truth so the two
    /// observers can't fight over install/remove.
    private func refreshOutsideClickMonitor() {
        applyOutsideClickMonitor(expanded: model.isPillExpanded || model.isAwaitingAskCorrection)
    }

    /// Route an outside click to the right action: a live ask ACCEPTS the gate's
    /// default (same as the timeout — clicking back into your app is not an
    /// explicit revert), else collapse an expanded recording pill.
    private func handleOutsideClick() {
        if model.isAwaitingAskCorrection {
            model.acceptAsk()
        } else {
            model.collapsePillExpandedIfNeeded()
        }
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = windowMoveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // NSEvent monitors must be removed via `NSEvent.removeMonitor`,
        // not NotificationCenter. They're owned by AppKit's process-wide
        // event tap registry, so leaving them installed past the
        // controller's lifetime would keep dispatching to a freed
        // closure on the next click.
        if let monitor = outsideClickGlobalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = outsideClickLocalMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Outside-click dismissal

    /// Mounts a pair of NSEvent monitors while the pill is expanded
    /// (`expanded == true`) and tears them down when it collapses.
    ///
    /// Two monitors are needed because AppKit splits event delivery:
    /// - `addGlobalMonitorForEvents` only sees events dispatched to
    ///   *other* applications. Catches clicks outside Jot entirely.
    /// - `addLocalMonitorForEvents` only sees events dispatched to
    ///   Jot's own process. Catches clicks in Jot's Settings / Home /
    ///   Ask Jot windows so they also collapse the pill.
    ///
    /// The local monitor must skip events targeting the overlay panel
    /// itself — those are the user clicking the pill to toggle, and
    /// the existing SwiftUI `.onTapGesture` already handles that path.
    /// Without the skip we'd collapse twice (and on a fresh expand the
    /// monitor would race the toggle).
    private func applyOutsideClickMonitor(expanded: Bool) {
        if expanded {
            installOutsideClickMonitorsIfNeeded()
        } else {
            removeOutsideClickMonitors()
        }
    }

    private func installOutsideClickMonitorsIfNeeded() {
        let matching: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        if outsideClickGlobalMonitor == nil {
            outsideClickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: matching) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Movable pill (v2, HIGH 2): a nonactivating panel that
                    // `acceptsFirstMouse` can receive the drag-initiating
                    // mouseDown while another app is frontmost — the global
                    // monitor (which has no window guard) would otherwise
                    // self-dismiss an expanded / awaiting-ask pill the instant a
                    // drag starts. Ignore clicks while dragging.
                    if self.isDraggingWindow { return }
                    self.handleOutsideClick()
                }
            }
        }

        if outsideClickLocalMonitor == nil {
            outsideClickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: matching) { [weak self] event in
                // Movable pill (v2, HIGH 2): don't dismiss while dragging.
                if self?.isDraggingWindow == true { return event }
                // Click on the overlay panel itself: let the pill's
                // own .onTapGesture / buttons handle it.
                if let panel = self?.panel, event.window === panel {
                    return event
                }
                Task { @MainActor [weak self] in
                    self?.handleOutsideClick()
                }
                return event
            }
        }
    }

    private func removeOutsideClickMonitors() {
        if let monitor = outsideClickGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickGlobalMonitor = nil
        }
        if let monitor = outsideClickLocalMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickLocalMonitor = nil
        }
    }

    // MARK: - Placement

    /// Movable pill (v2, MEDIUM 1/2): resolve the screen the pill currently
    /// occupies, NOT the "current" (focused-window) screen. `windowDidMove`
    /// keys `dragOffsetScreenNumber` off `panel.screen`; the apply path
    /// (`naturalWindowFrame` / `updateFrame`'s reset comparison) must use the
    /// SAME resolution, otherwise focus moving to a Jot window on another
    /// display flips `OverlayPlacement.currentScreen()` and silently resets a
    /// committed delta even though the pill itself never changed displays.
    /// Prefer `panel.screen` (the display the window frame is on); fall back to
    /// `currentScreen()` only when the panel has no screen yet (pre-order-front
    /// / off all screens). The panel can never be `keyWindow`
    /// (`canBecomeKey == false`), so `currentScreen()` would track some other
    /// window's screen — using it for the apply path is the MEDIUM 1/2 bug.
    private func resolvedScreen() -> NSScreen? {
        if let panel, let screen = panel.screen { return screen }
        return OverlayPlacement.currentScreen()
    }

    /// Stable-canvas (v3): the FIXED default window frame — a canvas sized to the
    /// largest pill state, centered horizontally on the resolved screen with its
    /// top edge flush to the screen top, so the top-pinned capsule sits under the
    /// notch exactly where it always has. The size is INDEPENDENT of `state`: the
    /// capsule inside changes size, the canvas never does. The `state` parameter
    /// is kept for call-site symmetry with the capture path (`captureCommittedDelta`).
    /// Used at BOTH drag capture and apply (`updateFrame`) so they stay symmetric
    /// by construction. Returns `nil` only when there is no screen.
    ///
    /// `OverlayPlacement` already centers at `screen.midX` and pins the top edge
    /// to `screenTop` regardless of size, so a fixed canvas placed this way keeps
    /// the capsule's default position identical to v2.
    private func naturalWindowFrame(for state: PillViewModel.PillState) -> NSRect? {
        guard let screen = resolvedScreen() else { return nil }
        let size = canvasWindowSize
        let screenTop = screen.frame.maxY
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screenTop - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func updateFrame(for state: PillViewModel.PillState? = nil) {
        guard let panel else { return }
        // Movable pill (v2): while a window-server `performDrag` is in flight the
        // OS owns the panel's position. A programmatic `setFrame` here — fired by
        // a live-preview state change, ask-height growth, or expansion toggle
        // that lands mid-drag — fights the drag loop and yanks the window back
        // (the snap-back-during-dictation bug). Suppress ALL re-framing during
        // the drag; `finalizeDrag()` re-applies the correct size + dragged
        // position the instant the drag ends.
        if isDraggingWindow { return }
        // MEDIUM 1/2: resolve the screen the pill is on (panel.screen), matching
        // the capture path in `windowDidMove`. Using `currentScreen()` here would
        // reset a committed delta on a mere focus change to another display.
        guard let screen = resolvedScreen() else {
            log.info("no screen available for overlay placement")
            return
        }
        let resolvedState = state ?? model.state

        // Movable pill (v2, design §D.2): the delta is meaningful only on the
        // screen it was set on. If the resolved screen changed (focus moved to
        // another display, or a display was reconfigured), drop the delta. Key
        // on `NSScreenNumber` — `NSScreen` has no stable object identity.
        let screenNumber = Self.screenNumber(of: screen)
        if committedDelta != .zero,
           dragOffsetScreenNumber != nil,
           dragOffsetScreenNumber != screenNumber {
            committedDelta = .zero
            dragOffsetScreenNumber = nil
        }

        // Movable pill (v2, design §D.2): start from the natural frame for the
        // CURRENT size, apply the center delta, then clamp the WINDOW to the
        // screen. Because the delta is measured against the natural origin for
        // the current size (not accumulated), widening 360→480→640 and
        // collapsing back returns to the same spot — no ratchet.
        guard let natural: NSRect = naturalWindowFrame(for: resolvedState) else { return }
        var windowFrame = natural
        windowFrame.origin.x += committedDelta.width
        windowFrame.origin.y += committedDelta.height
        // Stable-canvas (v3): clamp the VISIBLE CAPSULE on screen, not the canvas
        // — the canvas is larger than the capsule and may legitimately hang
        // off-screen (transparent + per-pixel click-through). Using the capsule
        // lets the user drag the pill right up to any screen edge.
        let clamped = Self.clampCapsuleOnScreen(windowFrame, pillSize: pillSize(for: resolvedState), screen: screen)
        // BLOCKER 1: fold the clamp correction back into the stored delta so the
        // delta and the on-screen position stay consistent — otherwise a
        // `performDrag` near a screen edge (where clamp would never place the
        // window) makes the next `updateFrame()` snap. A hard-corner drag then
        // widened can settle a few px in; that is the only self-consistent
        // resolution of drop-anywhere + stay-on-screen + no-jump-on-resize.
        if clamped.origin != windowFrame.origin {
            committedDelta.width += clamped.origin.x - windowFrame.origin.x
            committedDelta.height += clamped.origin.y - windowFrame.origin.y
        }
        // Track the screen the (non-zero) delta belongs to so a later change can
        // be detected. Cleared above when reset.
        if committedDelta != .zero {
            dragOffsetScreenNumber = screenNumber
        }
        panel.setFrame(clamped, display: true, animate: false)
    }

    /// Stable-canvas (v3): shift the fixed `windowFrame` so the VISIBLE CAPSULE —
    /// top-pinned, horizontally centered inside the canvas — stays fully on
    /// `screen`. The canvas itself may hang off-screen (transparent + per-pixel
    /// click-through), so only the capsule must remain reachable; this lets the
    /// pill be dragged right up to any screen edge instead of the (larger) canvas
    /// hitting the edge first. Shifts origin only — never resizes. Uses the full
    /// `screen.frame` (not `visibleFrame`): the pill deliberately sits flush to
    /// the very top, above the menu bar's notch region. The capsule
    /// (≤ 640 × 420) is always smaller than the screen in practice, so the
    /// min/max checks per axis can't fight.
    private static func clampCapsuleOnScreen(_ windowFrame: NSRect, pillSize: NSSize, screen: NSScreen) -> NSRect {
        let bounds = screen.frame
        var f = windowFrame
        // Capsule rect implied by this window placement: top-pinned, centered.
        let capMaxY = f.maxY
        let capMinY = capMaxY - pillSize.height
        let capMidX = f.midX
        let capMinX = capMidX - pillSize.width / 2
        let capMaxX = capMidX + pillSize.width / 2
        if capMaxX > bounds.maxX { f.origin.x -= capMaxX - bounds.maxX }
        if capMinX < bounds.minX { f.origin.x += bounds.minX - capMinX }
        if capMaxY > bounds.maxY { f.origin.y -= capMaxY - bounds.maxY }
        if capMinY < bounds.minY { f.origin.y += bounds.minY - capMinY }
        return f
    }

    /// The screen's `NSScreenNumber` (`CGDirectDisplayID`) wrapped as `NSNumber`
    /// — a stable identity across display reconfiguration, unlike `NSScreen`
    /// object identity. Design §10.
    private static func screenNumber(of screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private func pillSize(for state: PillViewModel.PillState) -> NSSize {
        // Expanded recording: taller multi-line transcript view.
        if model.isPillExpanded, case .recording = state {
            return NSSize(
                width: PillView.expandedRecordingWidth,
                height: PillView.expandedRecordingHeight
            )
        }
        // Slice D: the ask-before-paste pill is an expanded, multi-line
        // rounded-rect — wider and much taller than the 36pt capsule so the
        // context line, mapping line, and full-label buttons all fit.
        if case .askCorrection = state {
            // Grow vertically to fit the measured content (long context/mapping)
            // so the Use/Keep buttons are never clipped; floor at the design
            // height, cap so a pathological value can't run off-screen
            // (clampCapsuleOnScreen is the final guard).
            let measured = model.measuredAskHeight ?? PillView.expandedAskHeight
            let height = min(max(measured, PillView.expandedAskHeight), Self.maxAskHeight)
            return NSSize(width: PillView.expandedAskWidth, height: height)
        }
        return NSSize(width: pillWidth(for: state), height: Self.pillHeight)
    }

    private func pillWidth(for state: PillViewModel.PillState) -> CGFloat {
        switch state {
        case .error(let message):
            return errorPillWidth(for: message)
        case .notice(let message):
            // Notices use the same text-driven sizing as `.error` so a long
            // fallback message ("Recorded with system default — \(savedName)
            // was unavailable.") doesn't truncate to ellipsis.
            return errorPillWidth(for: message)
        case .savedToRecents(let preview):
            // v1.14: the saved-to-Recents affordance lays out as
            // [icon | "Saved to Recents" + preview line | arrow]. Reuse
            // the text-driven sizing so the preview can breathe.
            return errorPillWidth(for: preview)
        case .recording(_, let streamingPartial):
            // Streaming option only: when the partial is non-empty,
            // widen the pill so the live preview text has room. A
            // fixed wider width (rather than text-measured per
            // emission) avoids churning `setFrame` calls.
            if let text = streamingPartial,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Self.streamingPillWidth
            }
            return Self.compactPillWidth
        case .repairingModel(let modelName, _, let isError):
            // Persistent self-heal pill: text-driven width so the progress /
            // failure copy isn't truncated. The width is capped at
            // `expandedPillWidth` inside `errorPillWidth`, so a long
            // model name won't blow out the layout.
            let label = isError
                ? "Couldn’t download \(modelName) — open Settings"
                : "Repairing transcription model — downloading \(modelName)… 100%"
            return errorPillWidth(for: label)
        case .askCorrection:
            // Slice D: the ask is an expanded multi-line rounded-rect; its size
            // is resolved directly in `pillSize(for:)` (fixed expanded width +
            // height), so this width branch is never the size source. Return the
            // expanded width for completeness / any caller that only asks width.
            return PillView.expandedAskWidth
        case .hidden, .transcribing, .condensing, .rewriting, .transforming, .success, .holdProgress:
            return Self.compactPillWidth
        }
    }

    private func errorPillWidth(for message: String) -> CGFloat {
        let displayMessage = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        let measuredTextWidth = ceil(
            NSString(string: displayMessage).size(withAttributes: [.font: font]).width
        ) + 2
        let boundedTextWidth = min(measuredTextWidth, PillView.errorTextMaxWidth)
        return min(Self.expandedPillWidth, Self.errorChromeWidth + boundedTextWidth)
    }

    // MARK: - Click-through

    private func applyClickThrough(for state: PillViewModel.PillState) {
        guard let panel else { return }
        switch state {
        case .hidden:
            stopCursorTracking()
            panel.dragView.pillRectProvider = { .zero }
            panel.hostingView.pillRectProvider = { .zero }
            panel.ignoresMouseEvents = true
        default:
            // The capsule rect routes taps to the right view WHILE the window is
            // hittable; the cursor tracker decides WHEN it's hittable (only over
            // the capsule), so clicks/selection pass through everywhere else.
            let capsule: () -> CGRect = { [weak self, weak panel] in
                guard let self, let panel else { return .zero }
                return self.capsuleRect(for: self.model.state, in: panel)
            }
            panel.dragView.pillRectProvider = capsule
            panel.hostingView.pillRectProvider = capsule
            startCursorTracking()
            updateClickThroughForCursor()   // apply for the first frame, pre-timer
        }
    }

    /// Poll the cursor (~60 Hz) while the pill is visible and flip
    /// `ignoresMouseEvents`: FALSE only while the cursor is over the capsule (pill
    /// draggable/tappable), TRUE everywhere else so clicks and text selection
    /// reach the app beneath. This is the only reliable partial-click-through for
    /// a borderless panel — hitTest→nil swallows the click instead of passing it.
    private func startCursorTracking() {
        guard cursorTrackTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            // Timer fires on RunLoop.main → already on the main thread.
            MainActor.assumeIsolated { self?.updateClickThroughForCursor() }
        }
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)   // fire during tracking/scroll
        cursorTrackTimer = timer
    }

    private func stopCursorTracking() {
        cursorTrackTimer?.invalidate()
        cursorTrackTimer = nil
    }

    /// Set `ignoresMouseEvents` from the cursor's position relative to the capsule.
    private func updateClickThroughForCursor() {
        guard let panel else { return }
        // Mid-drag: stay hittable so the in-flight drag isn't interrupted.
        if isDraggingWindow {
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            return
        }
        let capsuleScreenRect = panel.convertToScreen(capsuleRect(for: model.state, in: panel))
        let shouldIgnore = !capsuleScreenRect.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents != shouldIgnore {
            panel.ignoresMouseEvents = shouldIgnore
        }
    }

    /// Movable pill (v2/v3, design §D.2 / MEDIUM 3): the visible capsule rect in
    /// the drag view's (full-window, non-flipped) coordinate space. AppKit views
    /// are non-flipped by default (origin bottom-left); the capsule floats
    /// top-CENTER inside the fixed canvas, so it occupies the high-y band and is
    /// horizontally centered. Sourced from the SAME `pillSize(for:)` used by the
    /// clamp so expanded / ask states report their real footprint.
    private func capsuleRect(for state: PillViewModel.PillState, in panel: OverlayPanel) -> CGRect {
        let pill = pillSize(for: state)
        let viewWidth = panel.dragView.bounds.width
        let viewHeight = panel.dragView.bounds.height
        // Stable-canvas (v3): the capsule floats top-CENTER inside the larger
        // fixed canvas, so it is horizontally centered (not pinned at
        // `horizontalPadding` as in v2 when the window hugged the pill).
        return CGRect(
            x: (viewWidth - pill.width) / 2,
            y: viewHeight - pill.height,   // top-pinned in non-flipped coords
            width: pill.width,
            height: pill.height
        )
    }
}

