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
    private let log = Logger(subsystem: "com.jot.Jot", category: "HotkeyRouter")

    private var stateObserver: AnyCancellable?
    private var activated = false
    private var cancelEnabled = false

    init(recorder: RecorderController, delivery: DeliveryService) {
        self.recorder = recorder
        self.delivery = delivery
    }

    /// Install shortcut handlers and start observing recorder state. Idempotent.
    func activate() {
        guard !activated else { return }
        activated = true

        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            guard let self else { return }
            self.log.info("toggleRecording fired")
            Task { @MainActor in await self.recorder.toggle() }
        }

        KeyboardShortcuts.onKeyDown(for: .cancelRecording) { [weak self] in
            guard let self else { return }
            self.log.info("cancelRecording fired")
            Task { @MainActor in await self.recorder.cancel() }
        }

        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            guard let self else { return }
            self.log.info("pushToTalk down")
            Task { @MainActor in
                if self.recorder.state == .idle {
                    await self.recorder.toggle()
                }
            }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            guard let self else { return }
            self.log.info("pushToTalk up")
            Task { @MainActor in
                if case .recording = self.recorder.state {
                    await self.recorder.toggle()
                }
            }
        }

        KeyboardShortcuts.onKeyDown(for: .pasteLastTranscription) { [weak self] in
            guard let self else { return }
            self.log.info("pasteLastTranscription fired")
            Task { @MainActor in await self.delivery.pasteLast() }
        }

        // Start with cancel disabled so Esc belongs to whoever else wants it.
        KeyboardShortcuts.disable(.cancelRecording)
        cancelEnabled = false

        // The source of truth for "are we currently recording" is
        // RecorderController.state. Every transition there drives the
        // enable/disable of the cancel shortcut.
        stateObserver = recorder.$state.sink { [weak self] newState in
            self?.applyCancelEnablement(for: newState)
        }
    }

    private func applyCancelEnablement(for state: RecorderController.State) {
        let shouldEnable: Bool
        switch state {
        case .recording: shouldEnable = true
        case .idle, .transcribing, .error: shouldEnable = false
        }
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
