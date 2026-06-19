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
    private static let errorChromeWidth: CGFloat = expandedPillWidth - PillView.errorTextMaxWidth

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

        // Click-through policy: follow pill state. During recording the
        // pill is tappable (toggle expand/collapse for streaming
        // partial). During transcribing the pill is pure status (ignore
        // mouse). In success / error states the user can interact with
        // the copy glyph or info tooltip.
        stateCancellable = model.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.applyClickThrough(for: state)
                self?.updateFrame(for: state)
            }
        // Re-layout when the user taps to expand or collapse the
        // recording pill. Frame change is animated by AppKit since
        // panel.setFrame uses display:true. Also (un)installs the
        // outside-click monitors that dismiss the expanded pill when
        // the user clicks anywhere off it.
        expansionCancellable = model.$isPillExpanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in
                self?.updateFrame()
                self?.applyOutsideClickMonitor(expanded: expanded)
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
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
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
                    self?.model.collapsePillExpandedIfNeeded()
                }
            }
        }

        if outsideClickLocalMonitor == nil {
            outsideClickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: matching) { [weak self] event in
                // Click on the overlay panel itself: let the pill's
                // own .onTapGesture handle expand/collapse.
                if let panel = self?.panel, event.window === panel {
                    return event
                }
                Task { @MainActor [weak self] in
                    self?.model.collapsePillExpandedIfNeeded()
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
        // Expanded recording: taller multi-line transcript view.
        if model.isPillExpanded, case .recording = state {
            return NSSize(
                width: PillView.expandedRecordingWidth,
                height: PillView.expandedRecordingHeight
            )
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
        case .hidden, .transcribing, .condensing, .rewriting, .transforming, .notice, .holdProgress:
            // Notices are pure informational — no copy glyph or follow-up.
            // Hold-progress is also non-interactive — the user is busy
            // holding the hotkey.
            panel.ignoresMouseEvents = true
        case .recording:
            // Recording pill is tappable ONLY during a streaming
            // session — that's the only state where tap-to-expand has
            // anything to show. Non-streaming primaries (v3 / JA) stay
            // click-through so a tap near the notch passes to whatever
            // app the user is working in.
            panel.ignoresMouseEvents = !model.isStreamingSessionActive
        case .success, .error, .savedToRecents, .repairingModel:
            // v1.14: `.savedToRecents` is the click-to-open-Recents
            // affordance — must be tappable for the whole linger window.
            // The repairing pill is tappable so it can route to Settings →
            // Transcription on click.
            panel.ignoresMouseEvents = false
        }
    }
}
