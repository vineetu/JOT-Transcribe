import Combine
import Foundation
import KeyboardShortcuts
import os.log

/// Owns the wiring between global hotkeys and the recorder/delivery layers.
///
/// Responsibilities:
///   - Register the always-on shortcuts (toggleRecording, pushToTalk,
///     pasteLastTranscription, rewriteSelection) at `activate()`.
///   - Dynamically enable/disable `cancelRecording` (plain Esc) so that
///     other apps keep Esc while Jot is idle. Cancel is active only while
///     a cancellable pipeline is running (recording, transforming,
///     capturing for rewrite, transcribing for rewrite, rewriting).
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
            Task { @MainActor [weak self] in
                guard let self else { return }
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

        // Every transition in recorder/rewrite state drives enable/disable
        // of the cancel shortcut. Each observer MUST pass its own new value
        // into `updateCancelEnablement` — `@Published` fires on willSet, so
        // re-reading `recorder.state` / `rewriteController.state` inside the
        // closure would return the pre-transition value and miss the edge.
        stateObserver = recorder.$state.sink { [weak self] newRecorderState in
            guard let self else { return }
            self.updateCancelEnablement(
                recorderState: newRecorderState,
                rewriteState: self.rewriteController?.state
            )
        }

        if let rewriteController {
            rewriteStateObserver = rewriteController.$state.sink { [weak self] newRewriteState in
                guard let self else { return }
                self.updateCancelEnablement(
                    recorderState: self.recorder.state,
                    rewriteState: newRewriteState
                )
            }
        }
    }

    private static func isRewriteCancellable(_ state: RewriteController.RewriteState) -> Bool {
        switch state {
        case .idle, .error: false
        case .capturing, .recording, .transcribing, .rewriting: true
        }
    }

    private func updateCancelEnablement(
        recorderState: RecorderController.State,
        rewriteState: RewriteController.RewriteState?
    ) {
        let recorderActive: Bool
        switch recorderState {
        case .recording, .transforming: recorderActive = true
        case .idle, .transcribing, .error: recorderActive = false
        }

        let rewriteActive: Bool
        if let rewriteState {
            rewriteActive = Self.isRewriteCancellable(rewriteState)
        } else {
            rewriteActive = false
        }

        let shouldEnable = recorderActive || rewriteActive
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
