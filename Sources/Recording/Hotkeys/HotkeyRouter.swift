import Combine
import Foundation
import KeyboardShortcuts
import os.log

/// Owns the wiring between global hotkeys and the recorder/delivery layers.
///
/// Responsibilities:
///   - Register the always-on shortcuts (toggleRecording, pushToTalk,
///     pasteLastTranscription, rewriteWithVoice, rewrite) at `activate()`.
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

    /// When non-nil, every `.toggleRecording` press routes here instead
    /// of into `recorder.toggle()`. The Setup Wizard's Test step sets
    /// this on appear (so the user can validate the real hotkey path
    /// without triggering paste / Library / chime side effects) and
    /// clears it on disappear. Single underlying KeyboardShortcuts
    /// handler — avoids the library's append-handler semantics that
    /// would otherwise fire both production and wizard logic on every
    /// press.
    private var toggleRecordingOverride: (() -> Void)?

    /// When non-nil, every `.rewrite` and `.rewriteWithVoice` press
    /// routes here instead of into `rewriteController.rewrite()` /
    /// `.toggle()`. The Setup Wizard's RewriteIntroStep sets this on
    /// appear so pressing either rewrite hotkey fires the wizard demo
    /// against bundled sample text instead of running the real
    /// selection-capture pipeline (which would target whatever app is
    /// behind the wizard window). Single handler for both names —
    /// callers don't care which path fired.
    private var rewriteOverride: (() -> Void)?

    /// One single-key handler per `SingleKey.Action`. Trigger-type state
    /// decides whether this handler or the corresponding Carbon-backed
    /// chord name is active. Pre-migration rows with no trigger type keep
    /// legacy behavior and allow both non-empty sides until the modal
    /// migration completes.
    private var singleKeyHotkeys: [SingleKey.Action: SingleKeyHotkey] = [:]
    private var singleKeyObserver: AnyCancellable?

    /// Tap-vs-hold dispatcher for the `.rewrite` hotkey. When non-nil,
    /// every press of `.rewrite` (chord or single-key) is funneled
    /// through here so a long-press can open the Prompt Picker instead
    /// of firing the default `RewriteController.rewrite()`. When nil
    /// (composition hasn't wired the pill + picker yet, or harness
    /// tests), presses fall back to direct invocation — preserving the
    /// pre-picker behavior.
    private var rewriteHoldDetector: RewriteHoldDetector?
    /// Closure invoked when the user holds `.rewrite` past the
    /// dispatcher's threshold. Set by composition once the
    /// `PromptPickerController` exists. Nil until then — pressing-and-
    /// holding before the opener is wired is a silent no-op (the tap
    /// path still works).
    private var promptPickerOpener: (@MainActor () -> Void)?

    init(recorder: RecorderController, delivery: DeliveryService, rewriteController: RewriteController? = nil) {
        self.recorder = recorder
        self.delivery = delivery
        self.rewriteController = rewriteController
    }

    /// Install shortcut handlers and start observing recorder state. Idempotent.
    func activate() {
        guard !activated else { return }
        activated = true

        installToggleRecording()
        applySingleKeys()
        // Observe UserDefaults so a Settings → Shortcuts edit takes
        // effect without an app relaunch. Any single-key or trigger-type
        // key can change; we rebind all of them on any defaults change
        // (cheap — five
        // `bind()` calls, each is O(1) when the key hasn't actually
        // changed).
        singleKeyObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                self?.applySingleKeys()
            }

        KeyboardShortcuts.onKeyDown(for: .cancelRecording) { [weak self] in
            guard let self else { return }
            self.log.info("cancelRecording fired")
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let rewrite = self.rewriteController, Self.isRewriteCancellable(rewrite.state) {
                    // Rewrite cancel semantics unchanged — voice-instruction
                    // captures are short and there's no transcript to keep.
                    await rewrite.cancel()
                } else if case .recording = self.recorder.state {
                    // v1.14 recording-safety contract: Esc while recording
                    // stops AND saves to Recents but skips the paste step.
                    // Same path as the in-app Record pill's click-to-stop
                    // — both reach `stopWithoutPaste()`. Esc no longer
                    // discards the recording; the user can delete from
                    // Recents if they meant to throw it away.
                    await self.recorder.stopWithoutPaste()
                } else {
                    // Transcribing / transforming / error — genuine abort.
                    // Past the "stop recording" moment, so the cancel-and-
                    // discard semantics still match user intent here.
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
            KeyboardShortcuts.onKeyDown(for: .rewriteWithVoice) { [weak self, weak rewriteController] in
                if let override = self?.rewriteOverride {
                    override()
                    return
                }
                guard let rewriteController else { return }
                Task { @MainActor in
                    await rewriteController.toggle()
                }
            }

            // v1.5 — fixed-prompt Rewrite, now with Prompt Picker tap-vs-hold.
            // Wired to `rewriteHoldDetector` when composition has installed
            // it (after the overlay + picker exist). The detector decides
            // tap-fires-default vs. hold-opens-picker based on press duration.
            // While `rewriteOverride` is set (Wizard demo), the detector is
            // bypassed entirely and presses go straight to the override.
            // Bypass also applies if no detector is wired (test seam /
            // pre-picker boot order) — falls back to today's direct call.
            KeyboardShortcuts.onKeyDown(for: .rewrite) { [weak self, weak rewriteController] in
                guard let self else { return }
                if let override = self.rewriteOverride {
                    override()
                    return
                }
                if let detector = self.rewriteHoldDetector {
                    detector.keyDown()
                    return
                }
                guard let rewriteController else { return }
                Task { @MainActor in
                    await rewriteController.rewrite()
                }
            }
            KeyboardShortcuts.onKeyUp(for: .rewrite) { [weak self] in
                guard let self else { return }
                // Override path doesn't differentiate between down and up
                // — the override fired on key-down. Drop the up cleanly.
                if self.rewriteOverride != nil { return }
                self.rewriteHoldDetector?.keyUp()
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

    /// Install the single `.toggleRecording` handler. Routes to the
    /// active override (if any) — otherwise to `recorder.toggle()`.
    ///
    /// We use a single underlying KeyboardShortcuts registration
    /// because the library APPENDS handlers per shortcut name; a
    /// naive "register a second wizard handler" would have BOTH the
    /// production and wizard logic fire on every press. Routing via
    /// the override property keeps exactly one registration alive
    /// and makes the wizard's commandeer/restore atomic.
    private func installToggleRecording() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            guard let self else { return }
            self.log.info("toggleRecording fired")
            if let override = self.toggleRecordingOverride {
                override()
                return
            }
            Task { @MainActor in
                if case .error = self.recorder.state {
                    self.recorder.clearError()
                }
                await self.recorder.toggle()
            }
        }
    }

    /// Route every `.toggleRecording` press to `handler` instead of
    /// the production recorder. Used by the Setup Wizard's Test step
    /// so the user can exercise the hotkey + Input Monitoring + global
    /// tap path without triggering paste / Library / chime side
    /// effects. Pair every call with `clearToggleRecordingOverride()`
    /// on disappear.
    func setToggleRecordingOverride(_ handler: @escaping () -> Void) {
        toggleRecordingOverride = handler
    }

    /// Stop routing `.toggleRecording` presses through the override —
    /// the next press goes back to `recorder.toggle()`.
    func clearToggleRecordingOverride() {
        toggleRecordingOverride = nil
    }

    /// Route every `.rewrite` and `.rewriteWithVoice` press to `handler`
    /// instead of the production rewrite pipeline. Used by the Setup
    /// Wizard's RewriteIntroStep so the user can fire the demo against
    /// bundled sample text using their real hotkey. Pair with
    /// `clearRewriteOverride()` on disappear.
    func setRewriteOverride(_ handler: @escaping () -> Void) {
        rewriteOverride = handler
    }

    /// Stop routing rewrite hotkey presses through the override —
    /// production rewrite resumes on the next press.
    func clearRewriteOverride() {
        rewriteOverride = nil
    }

    /// Install the Prompt Picker tap-vs-hold dispatcher for the
    /// `.rewrite` hotkey. Composition wires this AFTER the overlay
    /// exists so the detector can push hold-progress into the pill.
    /// `onHoldComplete` is intentionally NOT taken here — the picker
    /// controller is constructed later still; see
    /// `setPromptPickerOpener(_:)`. Until that opener is wired, a
    /// completed hold simply collapses the pill and is a silent no-op.
    func installRewriteHoldDispatch(
        setHoldProgress: @escaping @MainActor (Double) -> Void,
        clearHoldProgress: @escaping @MainActor () -> Void
    ) {
        rewriteHoldDetector = RewriteHoldDetector(
            onTap: { [weak self] in
                guard let self, let rc = self.rewriteController else { return }
                Task { @MainActor in await rc.rewrite() }
            },
            onHoldComplete: { [weak self] in
                self?.promptPickerOpener?()
            },
            setHoldProgress: setHoldProgress,
            clearHoldProgress: clearHoldProgress
        )
    }

    /// Register the closure that opens the Prompt Picker palette when
    /// the user holds `.rewrite` past the dispatcher's threshold.
    /// Composition wires this once the `PromptPickerController` is
    /// constructed. May be called multiple times safely (last writer
    /// wins).
    func setPromptPickerOpener(_ open: @escaping @MainActor () -> Void) {
        promptPickerOpener = open
    }

    /// Wire each `SingleKey.Action`'s `SingleKeyHotkey` to whatever the
    /// user has chosen in Settings → Shortcuts (or what migration set on
    /// first launch). Idempotent — safe to call on every `UserDefaults`
    /// change. Each action's callbacks are state-gated so a desync (e.g.
    /// Esc-cancel mid-recording while Caps Lock LED is still on) doesn't
    /// fire spurious actions on the next press.
    func applySingleKeys() {
        for action in SingleKey.Action.allCases {
            applySingleKey(for: action)
        }
    }

    private func applySingleKey(for action: SingleKey.Action) {
        let triggerType = SingleKeyMigration.storedTriggerType(for: action)
        let key = SingleKeyMigration.storedSingleKey(for: action)

        let hotkey = singleKeyHotkeys[action] ?? {
            let h = SingleKeyHotkey()
            singleKeyHotkeys[action] = h
            return h
        }()

        switch triggerType {
        case .singleKey:
            KeyboardShortcuts.disable(action.keyboardShortcutsName)
            bindSingleKey(key, for: action, hotkey: hotkey)
        case .chord:
            hotkey.unbind()
            KeyboardShortcuts.enable(action.keyboardShortcutsName)
        case nil:
            // Legacy mode for upgraded users until the migration wizard
            // completes: keep both sides live when they are bound.
            KeyboardShortcuts.enable(action.keyboardShortcutsName)
            bindSingleKey(key, for: action, hotkey: hotkey)
        }
    }

    private func bindSingleKey(
        _ key: SingleKey,
        for action: SingleKey.Action,
        hotkey: SingleKeyHotkey
    ) {
        if key == .none {
            hotkey.unbind()
            return
        }

        switch action {
        case .toggleRecording:
            bindToggleRecording(hotkey: hotkey, key: key)
        case .pushToTalk:
            bindPushToTalk(hotkey: hotkey, key: key)
        case .pasteLastTranscription:
            bindPasteLast(hotkey: hotkey, key: key)
        case .rewriteWithVoice:
            bindRewriteWithVoice(hotkey: hotkey, key: key)
        case .rewrite:
            bindRewrite(hotkey: hotkey, key: key)
        }
    }

    private func bindToggleRecording(hotkey: SingleKeyHotkey, key: SingleKey) {
        hotkey.bind(
            key,
            mode: SingleKey.Action.toggleRecording.mode,
            onStart: { [weak self] in
                guard let self else { return }
                self.log.info("singleKey toggleRecording \(key.rawValue, privacy: .public) → start")
                Task { @MainActor in
                    // Honor the wizard Test step's commandeer flag —
                    // single-key path mirrors the chord override contract.
                    if let override = self.toggleRecordingOverride {
                        override()
                        return
                    }
                    switch self.recorder.state {
                    case .idle, .error:
                        if case .error = self.recorder.state {
                            self.recorder.clearError()
                        }
                        await self.recorder.toggle()
                    case .recording, .transcribing, .transforming:
                        break
                    }
                }
            },
            onStop: { [weak self] in
                guard let self else { return }
                self.log.info("singleKey toggleRecording \(key.rawValue, privacy: .public) → stop")
                Task { @MainActor in
                    if let override = self.toggleRecordingOverride {
                        override()
                        return
                    }
                    switch self.recorder.state {
                    case .recording:
                        await self.recorder.toggle()
                    case .idle, .error, .transcribing, .transforming:
                        break
                    }
                }
            }
        )
    }

    private func bindPushToTalk(hotkey: SingleKeyHotkey, key: SingleKey) {
        hotkey.bind(
            key,
            mode: SingleKey.Action.pushToTalk.mode,
            onStart: { [weak self] in
                guard let self else { return }
                self.log.info("singleKey pushToTalk \(key.rawValue, privacy: .public) → down")
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
            },
            onStop: { [weak self] in
                guard let self else { return }
                self.log.info("singleKey pushToTalk \(key.rawValue, privacy: .public) → up")
                self.pttPendingRelease = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if case .recording = self.recorder.state {
                        await self.recorder.toggle()
                        self.pttPendingRelease = false
                    }
                }
            }
        )
    }

    private func bindPasteLast(hotkey: SingleKeyHotkey, key: SingleKey) {
        hotkey.bind(
            key,
            mode: SingleKey.Action.pasteLastTranscription.mode,
            onStart: { [weak self] in
                guard let self else { return }
                self.log.info("singleKey pasteLastTranscription \(key.rawValue, privacy: .public) → fire")
                Task { @MainActor in await self.delivery.pasteLast() }
            }
        )
    }

    private func bindRewriteWithVoice(hotkey: SingleKeyHotkey, key: SingleKey) {
        guard let rewriteController else {
            hotkey.unbind()
            return
        }
        hotkey.bind(
            key,
            mode: SingleKey.Action.rewriteWithVoice.mode,
            // Both edges call `.toggle()` — RewriteController owns its
            // own state machine; pressing tap-1 starts capture, tap-2
            // finishes it. The SingleKeyHotkey's synthetic toggle
            // alternates onStart/onStop on each ON edge, so wiring both
            // to `.toggle()` means every press hands control back to the
            // controller, which decides what to do based on its state.
            onStart: { [weak self, weak rewriteController] in
                if let override = self?.rewriteOverride {
                    override()
                    return
                }
                guard let rewriteController else { return }
                Task { @MainActor in await rewriteController.toggle() }
            },
            onStop: { [weak self, weak rewriteController] in
                if let override = self?.rewriteOverride {
                    override()
                    return
                }
                guard let rewriteController else { return }
                Task { @MainActor in await rewriteController.toggle() }
            }
        )
    }

    private func bindRewrite(hotkey: SingleKeyHotkey, key: SingleKey) {
        guard let rewriteController else {
            hotkey.unbind()
            return
        }
        // `.rewrite.mode` is `.hold`, so both edges are delivered. The
        // dispatcher (when installed) maps the press/release pair to
        // either default-rewrite (early release) or picker-open (held
        // past 1.2s). With no dispatcher wired, falls back to the
        // pre-picker behavior: press fires Rewrite, release is ignored.
        hotkey.bind(
            key,
            mode: SingleKey.Action.rewrite.mode,
            onStart: { [weak self, weak rewriteController] in
                guard let self else { return }
                if let override = self.rewriteOverride {
                    override()
                    return
                }
                if let detector = self.rewriteHoldDetector {
                    detector.keyDown()
                    return
                }
                guard let rewriteController else { return }
                Task { @MainActor in await rewriteController.rewrite() }
            },
            onStop: { [weak self] in
                guard let self else { return }
                if self.rewriteOverride != nil { return }
                self.rewriteHoldDetector?.keyUp()
            }
        )
    }

    private func updateCancelEnablement(
        recorderState: RecorderController.State,
        rewriteState: RewriteController.RewriteState?
    ) {
        let recorderActive: Bool
        switch recorderState {
        case .recording, .transcribing, .transforming: recorderActive = true
        case .idle, .error: recorderActive = false
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
