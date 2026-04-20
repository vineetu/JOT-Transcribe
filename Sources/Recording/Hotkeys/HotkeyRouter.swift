import Combine
import Foundation
import KeyboardShortcuts
import os.log

/// Owns the wiring between global hotkeys and the recorder/delivery layers.
///
/// Responsibilities:
///   - Register the always-on shortcuts (toggleRecording, pushToTalk,
///     pasteLastTranscription, articulateCustom, articulate) at `activate()`.
///   - Dynamically enable/disable `cancelRecording` (plain Esc) so that
///     other apps keep Esc while Jot is idle. Cancel is active only while
///     a cancellable pipeline is running (recording, transforming,
///     capturing for articulate, transcribing for articulate, rewriting).
@MainActor
final class HotkeyRouter {
    private let recorder: RecorderController
    private let delivery: DeliveryService
    private let articulateController: ArticulateController?
    private let log = Logger(subsystem: "com.jot.Jot", category: "HotkeyRouter")

    private var stateObserver: AnyCancellable?
    private var articulateStateObserver: AnyCancellable?
    private var activated = false
    private var cancelEnabled = false
    private var pttPendingRelease = false

    init(recorder: RecorderController, delivery: DeliveryService, articulateController: ArticulateController? = nil) {
        self.recorder = recorder
        self.delivery = delivery
        self.articulateController = articulateController
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let articulate = self.articulateController, Self.isArticulateCancellable(articulate.state) {
                    await articulate.cancel()
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

        if let articulateController {
            KeyboardShortcuts.onKeyDown(for: .articulateCustom) { [weak articulateController] in
                guard let articulateController else { return }
                Task { @MainActor in
                    await articulateController.toggle()
                }
            }

            // v1.5 — fixed-prompt Articulate. Selection → LLM → paste with
            // the literal "Articulate this" instruction (no voice step, no
            // classifier). Shares the selection-capture + paste-back path
            // with Articulate (Custom).
            KeyboardShortcuts.onKeyDown(for: .articulate) { [weak articulateController] in
                guard let articulateController else { return }
                Task { @MainActor in
                    await articulateController.articulate()
                }
            }
        }

        // Start with cancel disabled so Esc belongs to whoever else wants it.
        KeyboardShortcuts.disable(.cancelRecording)
        cancelEnabled = false

        // Every transition in recorder/articulate state drives enable/disable
        // of the cancel shortcut. Each observer MUST pass its own new value
        // into `updateCancelEnablement` — `@Published` fires on willSet, so
        // re-reading `recorder.state` / `articulateController.state` inside the
        // closure would return the pre-transition value and miss the edge.
        stateObserver = recorder.$state.sink { [weak self] newRecorderState in
            guard let self else { return }
            self.updateCancelEnablement(
                recorderState: newRecorderState,
                articulateState: self.articulateController?.state
            )
        }

        if let articulateController {
            articulateStateObserver = articulateController.$state.sink { [weak self] newArticulateState in
                guard let self else { return }
                self.updateCancelEnablement(
                    recorderState: self.recorder.state,
                    articulateState: newArticulateState
                )
            }
        }
    }

    private static func isArticulateCancellable(_ state: ArticulateController.ArticulateState) -> Bool {
        switch state {
        case .idle, .error: false
        case .capturing, .recording, .transcribing, .rewriting: true
        }
    }

    private func updateCancelEnablement(
        recorderState: RecorderController.State,
        articulateState: ArticulateController.ArticulateState?
    ) {
        let recorderActive: Bool
        switch recorderState {
        case .recording, .transforming: recorderActive = true
        case .idle, .transcribing, .error: recorderActive = false
        }

        let articulateActive: Bool
        if let articulateState {
            articulateActive = Self.isArticulateCancellable(articulateState)
        } else {
            articulateActive = false
        }

        let shouldEnable = recorderActive || articulateActive
        guard shouldEnable != cancelEnabled else { return }
        cancelEnabled = shouldEnable
        if shouldEnable {
            KeyboardShortcuts.enable(.cancelRecording)
            log.info("cancelRecording ENABLED (cancellable pipeline active)")
        } else {
            KeyboardShortcuts.disable(.cancelRecording)
            log.info("cancelRecording DISABLED (pipeline idle)")
        }
    }
}
