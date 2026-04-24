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
    private let articulateController: ArticulateController?
    private let pipeline: VoiceInputPipeline
    private let model: PillViewModel
    private let amplitudePublisher = AmplitudePublisher()

    private var panel: OverlayPanel?
    private var screenChangeObserver: NSObjectProtocol?
    private var reduceMotionObserver: NSObjectProtocol?
    private var stateCancellable: AnyCancellable?

    /// Natural footprint of the compact pill (visual surface, not including
    /// shadow). Error pills can grow beyond this, up to `expandedPillWidth`.
    static let compactPillWidth: CGFloat = PillView.compactPillWidth
    static let expandedPillWidth: CGFloat = PillView.expandedPillWidth
    static let pillHeight: CGFloat = PillView.pillHeight
    static let horizontalPadding: CGFloat = 12
    static let bottomPadding: CGFloat = 24
    private static let errorChromeWidth: CGFloat = expandedPillWidth - PillView.errorTextMaxWidth

    init(
        recorder: RecorderController,
        delivery: DeliveryService,
        articulateController: ArticulateController? = nil,
        pipeline: VoiceInputPipeline
    ) {
        self.recorder = recorder
        self.delivery = delivery
        self.articulateController = articulateController
        self.pipeline = pipeline
        self.model = PillViewModel(recorder: recorder, delivery: delivery, articulateController: articulateController)
    }

    func install() {
        pipeline.setAmplitudePublisher(amplitudePublisher)
        let rootView = PillView(model: model)
            .environmentObject(amplitudePublisher)
        let panel = OverlayPanel(rootView: rootView)
        self.panel = panel

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

        // Click-through policy: follow pill state. During recording /
        // transcribing the pill is pure status (ignore mouse). In success /
        // error states the user can interact with the copy glyph or info
        // tooltip, so the window must receive events.
        stateCancellable = model.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.applyClickThrough(for: state)
                self?.updateFrame(for: state)
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

    private func updateFrame(for state: PillViewModel.PillState? = nil) {
        guard let panel else { return }
        guard let screen = OverlayPlacement.currentScreen() else {
            log.info("no screen available for overlay placement")
            return
        }
        let pillSize = pillSize(for: state ?? model.state)
        // Size the window larger than the pill so the SwiftUI shadow has room
        // to render (primarily below the pill). No padding on top — the pill's
        // top edge should align with the window's top edge so it sits flush at
        // the top of the screen.
        let windowSize = NSSize(
            width: pillSize.width + Self.horizontalPadding * 2,
            height: pillSize.height + Self.bottomPadding
        )
        let pillRect = OverlayPlacement.frame(for: pillSize, on: screen)
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

    private func pillSize(for state: PillViewModel.PillState) -> NSSize {
        NSSize(width: pillWidth(for: state), height: Self.pillHeight)
    }

    private func pillWidth(for state: PillViewModel.PillState) -> CGFloat {
        switch state {
        case .error(let message):
            return errorPillWidth(for: message)
        case .hidden, .recording, .transcribing, .condensing, .rewriting, .transforming, .success:
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
        case .hidden, .recording, .transcribing, .condensing, .rewriting, .transforming:
            panel.ignoresMouseEvents = true
        case .success, .error:
            panel.ignoresMouseEvents = false
        }
    }
}
