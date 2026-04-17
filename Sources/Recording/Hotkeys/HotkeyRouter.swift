import Combine
import Foundation
import KeyboardShortcuts
import os.log

/// Owns the wiring between global hotkeys and the recorder/delivery layers.
///
/// Responsibilities:
///   - Register the always-on shortcuts (toggleRecording, pushToTalk,
///     pasteLastTranscription) at `activate()`.
///   - Dynamically enable `cancelRecording` while, and only while, the
///     recorder is in `.recording`. This is the point of spike S2: other
///     apps must keep Esc when Jot is idle.
///
/// Kept deliberately thin. No SDK-specific types leak out — callers couple
/// to this class, not to `KeyboardShortcuts.Name`. If the S2 primary path
/// (KeyboardShortcuts.enable/.disable) turns out to be unreliable, the
/// cancel hotkey can be swapped for a Carbon `RegisterEventHotKey`
/// implementation behind the same public API.
@MainActor
final class HotkeyRouter {
    private let recorder: RecorderController
    private let delivery: DeliveryService
    private let rewriteController: RewriteController?
    private let log = Logger(subsystem: "com.jot.Jot", category: "HotkeyRouter")

    private var stateObserver: AnyCancellable?
    private var rewriteStateObserver: AnyCancellable?
    private var activated = false
    private var cancelEnabled = false
    private var pttPendingRelease = false

    init(recorder: RecorderController, delivery: DeliveryService, rewriteController: RewriteController? = nil) {
        self.recorder = recorder
        self.delivery = delivery
        self.rewriteController = rewriteController
    }

    /// Install shortcut handlers and start observing recorder state. Idempotent.
    func activate() {
        guard !activated else { return }
        activated = true

        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            guard let self else { return }
            self.log.info("toggleRecording fired")
            Task { @MainActor in
                if case .error = self.recorder.state {
                    self.recorder.clearError()
                }
                await self.recorder.toggle()
            }
        }

        KeyboardShortcuts.onKeyDown(for: .cancelRecording) { [weak self] in
            guard let self else { return }
            self.log.info("cancelRecording fired")
            Task { @MainActor in
                // Route to whichever pipeline is in a cancellable state.
                // Rewrite takes precedence because its active window
                // overlaps recorder.idle, but `.error` must not steal the
                // key — it auto-recovers in 2.5s and would otherwise
                // swallow Esc while the main recorder is active.
                if let rewrite = self.rewriteController, Self.isRewriteCancellable(rewrite.state) {
                    await rewrite.cancel()
                } else {
                    await self.recorder.cancel()
                }
            }
        }

        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            guard let self else { return }
            self.log.info("pushToTalk down")
            self.pttPendingRelease = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .idle = self.recorder.state {
                    await self.recorder.toggle()
                } else if case .error = self.recorder.state {
                    self.recorder.clearError()
                    await self.recorder.toggle()
                }
                if self.pttPendingRelease, case .recording = self.recorder.state {
                    await self.recorder.toggle()
                    self.pttPendingRelease = false
                }
            }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            guard let self else { return }
            self.log.info("pushToTalk up")
            self.pttPendingRelease = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .recording = self.recorder.state {
                    await self.recorder.toggle()
                    self.pttPendingRelease = false
                }
            }
        }

        KeyboardShortcuts.onKeyDown(for: .pasteLastTranscription) { [weak self] in
            guard let self else { return }
            self.log.info("pasteLastTranscription fired")
            Task { @MainActor in await self.delivery.pasteLast() }
        }

        if let rewriteController {
            KeyboardShortcuts.onKeyDown(for: .rewriteSelection) { [weak rewriteController] in
                guard let rewriteController else { return }
                Task { @MainActor in
                    await rewriteController.toggle()
                }
            }
        }

        // Start with cancel disabled so Esc belongs to whoever else wants it.
        KeyboardShortcuts.disable(.cancelRecording)
        cancelEnabled = false

        // The source of truth for "are we currently recording" is
        // RecorderController.state. Every transition there drives the
        // enable/disable of the cancel shortcut.
        stateObserver = recorder.$state.sink { [weak self] _ in
            self?.updateCancelEnablement()
        }

        if let rewriteController {
            rewriteStateObserver = rewriteController.$state.sink { [weak self] _ in
                self?.updateCancelEnablement()
            }
        }
    }

    private static func isRewriteCancellable(_ state: RewriteController.RewriteState) -> Bool {
        switch state {
        case .idle, .error: false
        case .capturing, .recording, .transcribing, .rewriting: true
        }
    }

    private func updateCancelEnablement() {
        let recorderActive: Bool
        switch recorder.state {
        case .recording, .transforming: recorderActive = true
        case .idle, .transcribing, .error: recorderActive = false
        }

        let rewriteActive: Bool
        if let rewriteState = rewriteController?.state {
            rewriteActive = Self.isRewriteCancellable(rewriteState)
        } else {
            rewriteActive = false
        }

        let shouldEnable = recorderActive || rewriteActive
        guard shouldEnable != cancelEnabled else { return }
        cancelEnabled = shouldEnable
        if shouldEnable {
            KeyboardShortcuts.enable(.cancelRecording)
            log.info("cancelRecording ENABLED (state entered .recording)")
        } else {
            KeyboardShortcuts.disable(.cancelRecording)
            log.info("cancelRecording DISABLED (state left .recording)")
        }
    }
}
