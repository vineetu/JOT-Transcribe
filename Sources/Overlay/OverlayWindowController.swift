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
    private let model: PillViewModel
    private let amplitudePublisher = AmplitudePublisher()

    private var panel: OverlayPanel?
    private var screenChangeObserver: NSObjectProtocol?
    private var reduceMotionObserver: NSObjectProtocol?
    private var stateCancellable: AnyCancellable?

    /// Natural footprint of the pill (visual surface, not including shadow).
    /// The hosting window is sized larger than this, with extra room on the
    /// sides and bottom so the SwiftUI drop shadow can render without being
    /// clipped at the window boundary. No extra room is needed on top — the
    /// pill hugs the top of the window (and the top of the screen).
    static let pillSize = NSSize(width: 360, height: 36)
    static let horizontalPadding: CGFloat = 12
    static let bottomPadding: CGFloat = 24

    init(recorder: RecorderController, delivery: DeliveryService, articulateController: ArticulateController? = nil) {
        self.recorder = recorder
        self.delivery = delivery
        self.model = PillViewModel(recorder: recorder, delivery: delivery, articulateController: articulateController)
    }

    func install() {
        recorder.setAmplitudePublisher(amplitudePublisher)
        let rootView = PillView(model: model)
            .environmentObject(amplitudePublisher)
        let panel = OverlayPanel(rootView: rootView)
        self.panel = panel

        updateFrame()
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

        // Click-through policy: follow pill state. During recording /
        // transcribing the pill is pure status (ignore mouse). In success /
        // error states the user can interact with the copy glyph or info
        // tooltip, so the window must receive events.
        stateCancellable = model.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.applyClickThrough(for: state)
            }
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Placement

    private func updateFrame() {
        guard let panel else { return }
        guard let screen = OverlayPlacement.currentScreen() else {
            log.info("no screen available for overlay placement")
            return
        }
        // Size the window larger than the pill so the SwiftUI shadow has room
        // to render (primarily below the pill). No padding on top — the pill's
        // top edge should align with the window's top edge so it sits flush at
        // the top of the screen.
        let windowSize = NSSize(
            width: Self.pillSize.width + Self.horizontalPadding * 2,
            height: Self.pillSize.height + Self.bottomPadding
        )
        let pillRect = OverlayPlacement.frame(for: Self.pillSize, on: screen)
        // Place the window so the pill's top edge lines up with the window's
        // top edge (= top of screen). In AppKit bottom-left coordinates:
        //   window.maxY == pill.maxY  →  window.origin.y = pillRect.maxY - windowSize.height
        let windowFrame = NSRect(
            x: pillRect.midX - windowSize.width / 2,
            y: pillRect.maxY - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
        panel.setFrame(windowFrame, display: true, animate: false)
    }

    // MARK: - Click-through

    private func applyClickThrough(for state: PillViewModel.PillState) {
        guard let panel else { return }
        switch state {
        case .hidden, .recording, .transcribing, .rewriting, .transforming:
            panel.ignoresMouseEvents = true
        case .success, .error:
            panel.ignoresMouseEvents = false
        }
    }
}
