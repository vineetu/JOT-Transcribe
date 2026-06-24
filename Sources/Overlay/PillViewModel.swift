import Combine
import Foundation
import SwiftUI

/// Drives the Dynamic Island-style pill. Subscribes to the recorder's state
/// and the delivery service's last event, and collapses the cross-product
/// into a single `PillState` that the view can render directly.
///
/// Auto-dismiss for success/error states lives here rather than in the view
/// so the view can stay pure; cancelling the dismiss timer on a fresh state
/// transition is also a ViewModel concern.
@MainActor
final class PillViewModel: ObservableObject {
    enum PillState: Equatable {
        case hidden
        /// `streamingPartial` is the live preview text from
        /// `StreamingPartialStore` for the streaming option's EOU 120M
        /// engine. `nil` for non-streaming primaries (v3 / JA) and for
        /// streaming sessions before the first partial lands. The pill
        /// view conditionally swaps the middle slot to render the
        /// partial when non-empty; `OverlayWindowController` widens
        /// the frame on the same condition.
        case recording(elapsed: TimeInterval, streamingPartial: String?)
        case transcribing
        case condensing   // Ask Jot voice-input condensation (spec v5 §8).
        case rewriting
        case transforming
        case success(preview: String)
        /// Informational toast (e.g. "Recorded with system default — \(savedName)
        /// was unavailable.") — surfaces successful recording with a caveat the
        /// user should know about. Distinct from `.error` so a benign fallback
        /// doesn't read as a failure. Auto-dismisses on the same cadence as
        /// `.success`. See `docs/plans/mic-disconnect-handling.md`.
        case notice(message: String)
        /// v1.14: shown after a recording was stopped without pasting
        /// (the in-app Record pill or Esc). Clickable — opens Recents.
        /// Lingers ~5 s so the user can find the affordance even if
        /// they were typing in another app and looked up late. The
        /// click handler is stored on `PillViewModel.onSavedToRecentsTap`
        /// rather than embedded in the case payload so `PillState`
        /// stays `Equatable`.
        case savedToRecents(preview: String)
        /// Slice D (ask-before-paste, §9 Option B). The live "Did you mean
        /// \"<term>\"?" prompt shown BEFORE the paste lands, while the delivery
        /// bridge holds the staged text. `original` is the word currently in the
        /// text (what TDT wrote, or — for the silent-OOV case — what the gate
        /// would revert to on keep); `term` is the vocabulary term offered. The
        /// resolution closures live on `PillViewModel` (`onAskConfirm` /
        /// `onAskDismiss`), mirroring `savedToRecents`, so the case stays
        /// `Equatable`. This state ALWAYS terminates via exactly one of those
        /// closures — never via `scheduleDismiss` (which would hide WITHOUT
        /// delivering and orphan the held paste; see §8 M4/M5).
        /// `contextBefore` / `contextAfter` are the (trimmed, ellipsized)
        /// snippet of staged text on each side of the in-text word, so the
        /// expanded ask can show the word in its sentence. `applied` is `true`
        /// when the term is currently in the text (silent-OOV APPLIED case —
        /// the in-text word is `term`) and `false` when the original is in the
        /// text (common-word BLOCKED near-miss — the in-text word is `original`).
        case askCorrection(original: String, term: String, contextBefore: String, contextAfter: String, applied: Bool)
        case error(message: String)
        /// Press-and-hold progress for the Prompt Picker entry. `progress`
        /// is 0.0 → 1.0 across the (threshold − grace) window — the pill
        /// renders a fill / ring driven by this value. Yields to any
        /// active recorder / rewrite state — see `showHoldProgress(_:)`.
        case holdProgress(progress: Double)
        /// Startup model-integrity self-heal (design §Phase 3). Persistent —
        /// driven DIRECTLY off `TranscriberHolder.$repairState`, NOT the
        /// recorder lifecycle, so it is never handed to `scheduleDismiss` /
        /// `scheduleAutoRecoveryIfNeeded`. `modelName` names the model being
        /// repaired; `progress` is `nil` until the first byte fraction lands;
        /// `isError` is `true` once the heal has failed and the user has been
        /// routed to Settings.
        case repairingModel(modelName: String, progress: Double?, isError: Bool)
    }

    @Published private(set) var state: PillState = .hidden

    /// Per-use voice-augment hint for a Prompt-Picker-augmented Rewrite with
    /// Voice run (e.g. 'Say the target language…'). Mirrored straight off
    /// `RewriteController.augmentHint` so the recording pill can show the user
    /// what detail to speak. `nil` for ordinary recordings (dictation and the
    /// plain `.rewriteWithVoice` hotkey path), where the recording pill renders
    /// exactly as before.
    @Published private(set) var augmentHint: String?

    /// True while the current `.recording` pill is a Rewrite-with-Voice capture
    /// (both entry points: the `.rewriteWithVoice` hotkey AND the Prompt-Picker
    /// voice-augment). Drives the stop-hotkey hint to show the user's AI
    /// Rewrite-with-Voice binding instead of the dictation toggle. Set by the
    /// rewrite vs. recorder state handlers; only read while `.recording`.
    @Published private(set) var isRewriteVoiceCapture: Bool = false

    /// True while the user has tapped the recording pill to expand it
    /// into the multi-line streaming-transcript view. Only meaningful
    /// when `state == .recording` AND a streaming session is active.
    /// Reset to `false` automatically on any non-recording state
    /// transition so a stale expansion doesn't outlive the session.
    @Published private(set) var isPillExpanded: Bool = false

    /// Mirrors `StreamingPartialStore.shared.isActive`. `true` only
    /// while the streaming option is the active primary AND the
    /// pipeline has wired the streaming session for the current
    /// recording. Non-streaming primaries (v3 / JA) keep this `false`
    /// so their recording pills stay click-through and don't surface
    /// a tap-to-expand affordance the user can't act on.
    @Published private(set) var isStreamingSessionActive: Bool = false

    /// Measured ideal height of the ask-before-paste ("Did you mean X?") pill
    /// content, published by `PillView.expandedAskBody` so the window can grow
    /// VERTICALLY to fit a long context/mapping instead of clipping the
    /// Use/Keep buttons under a fixed height. `nil` until first measured; the
    /// window controller floors it at `expandedAskHeight` and caps it.
    @Published var measuredAskHeight: CGFloat?

    /// Toggle the expanded view. No-op outside a recording, AND
    /// no-op for non-streaming recordings — the expanded mode only
    /// makes sense while a streaming session is producing partial
    /// text. (#10 from the cleanup list.)
    func togglePillExpanded() {
        guard case .recording = state else { return }
        guard isStreamingSessionActive else { return }
        isPillExpanded.toggle()
    }

    /// One-way collapse used by the outside-click dismissal path in
    /// `OverlayWindowController`. Distinct from `togglePillExpanded()`
    /// so a stray collapse call from the click monitor can't
    /// accidentally re-expand the pill if `isPillExpanded` was already
    /// false (which can happen if the recording ended a microsecond
    /// before the click landed).
    func collapsePillExpandedIfNeeded() {
        guard isPillExpanded else { return }
        isPillExpanded = false
    }

    /// Auto-dismiss windows (seconds).
    static let successLinger: TimeInterval = 2.4
    /// Non-actionable errors can clear sooner because the pill has no follow-up affordance yet.
    static let errorLinger: TimeInterval = 7.0
    /// Actionable errors should linger longer so a future labeled button has time to be noticed and used.
    static let actionableErrorLinger: TimeInterval = 15.0
    /// v1.14: linger for the saved-to-Recents click affordance. Longer
    /// than `successLinger` so a user who Esc'd from a deep focus state
    /// has time to notice the pill and click.
    static let savedToRecentsLinger: TimeInterval = 5.0

    /// Slice D: how long the ask pill waits for a decision before it
    /// auto-resolves to keep-original + deliver (the safe default, §7). Long
    /// enough that a user who looked away can still read + answer; short enough
    /// that an ignored ask doesn't park the paste indefinitely.
    static let askLinger: TimeInterval = 10.0

    /// Slice D: true while the pill is showing a `.askCorrection` prompt that
    /// has not yet resolved. `HotkeyRouter` observes this to enable the
    /// ask-scoped Return / Esc shortcuts ONLY while an ask is live (mirroring
    /// the dynamic `cancelRecording` machinery), and disable them otherwise so
    /// Jot never steals Return / Esc from other apps.
    @Published private(set) var isAwaitingAskCorrection: Bool = false

    /// Slice D resolution closures, supplied by the delivery bridge for the
    /// CURRENT ask. The bridge owns the staged text + the single `deliver()`;
    /// these closures route the pill's confirm / dismiss decision back to it.
    /// Stored on the view model (not in the case payload) so `PillState` stays
    /// `Equatable`. Exactly one fires per ask (idempotent — `resolveAsk`
    /// guarantees single resolution).
    private var onAskConfirm: (() -> Void)?
    private var onAskDismiss: (() -> Void)?
    /// Fired when the ask resolves by NON-interaction — the 10s timeout or an
    /// outside-click. Distinct from dismiss: it ACCEPTS the gate's current
    /// decision (delivers the staged text as-is) rather than reverting to the
    /// original. So an ignored auto-correction stays applied, and an ignored
    /// common-word near-miss stays un-replaced — i.e. the user never has to click
    /// for the gate's default to take effect.
    private var onAskAccept: (() -> Void)?
    /// Dedicated dismiss task for the ask timeout. Kept SEPARATE from
    /// `dismissTask` so an unrelated pill transition's `dismissTask?.cancel()`
    /// can never silently kill the ask's auto-resolve (§8 M4/M5).
    private var askTimeoutTask: Task<Void, Never>?

    /// v1.14: click handler invoked when the user taps the saved-to-
    /// Recents pill. Takes the audio filename captured at the moment
    /// the pill was shown — that's the persistent identifier the
    /// Recents view uses to look up the SwiftData row. AppDelegate sets
    /// this during composition to a closure that opens Recents and
    /// pushes the corresponding Recording detail onto the navigation
    /// path.
    var onSavedToRecentsTap: ((_ audioFileName: String?) -> Void)?

    /// Tap handler for the persistent repairing pill (design §Phase 3). Routes
    /// the user to Settings → Transcription — the same primary recovery surface
    /// the holder opens on detection. Wired by composition.
    var onRepairPillTap: (() -> Void)?

    /// Called by `PillView` when the repairing pill is tapped.
    func invokeRepairPillTap() {
        onRepairPillTap?()
    }

    /// v1.14: paired with `state == .savedToRecents`. Set by
    /// `showSavedToRecents(...)` and read by `invokeSavedToRecentsTap()`
    /// when the pill is clicked. Cleared on the next pill transition so
    /// a stale identifier can't outlive its session.
    private var pendingSavedRecordingAudioFile: String?

    private var recordingStartedAt: Date?
    private var tickTimer: Timer?
    private var dismissTask: Task<Void, Never>?

    /// Cached latest streaming partial. Read by `tick()` to preserve
    /// the partial across the 0.5 s timer-driven state rebuilds —
    /// otherwise the timer would clear the partial twice a second.
    /// Written by the `StreamingPartialStore.$partial` subscriber.
    private var latestPartial: String?

    private var recorderCancellable: AnyCancellable?
    private var deliveryCancellable: AnyCancellable?
    private var rewriteCancellable: AnyCancellable?
    private var rewriteResultCancellable: AnyCancellable?
    /// Mirrors `RewriteController.augmentHint` onto the view model so the
    /// recording pill can surface the per-use augment hint during a
    /// picker-augmented Rewrite with Voice capture.
    private var rewriteAugmentHintCancellable: AnyCancellable?
    /// Subscriber on `StreamingPartialStore.shared.$partial`. Updates
    /// `latestPartial` and rebuilds the pill state when currently
    /// `.recording`. Same subscriber covers all three voice-capture
    /// sites (Dictation, Articulate, Ask Jot) — the partial store is
    /// owner-agnostic.
    private var streamingPartialCancellable: AnyCancellable?
    /// Subscriber on `StreamingPartialStore.shared.$isActive`. Mirrors
    /// the active flag onto `isStreamingSessionActive` for click-through
    /// and tap-to-expand gating.
    private var streamingActiveCancellable: AnyCancellable?
    /// Subscription that surfaces `RecorderController.lastFallbackNotice`
    /// as a `.notice(...)` pill once a fresh `lastResult` has landed and
    /// the success pill has dismissed. See `docs/plans/mic-disconnect-handling.md`.
    private var fallbackNoticeCancellable: AnyCancellable?

    private weak var recorder: RecorderController?
    private weak var delivery: DeliveryService?
    private weak var rewriteController: RewriteController?

    /// Subscriber on `TranscriberHolder.$repairState` (design §Phase 3 / G4).
    /// Drives the persistent repairing pill directly off the holder — this
    /// path NEVER calls `scheduleDismiss`/`scheduleAutoRecoveryIfNeeded`, so
    /// the pill stays up for the whole repair, independent of the recording
    /// lifecycle.
    private var repairCancellable: AnyCancellable?
    /// Latest repair state mirrored from the holder. Read when a transient
    /// recorder/rewrite state clears so the persistent repair pill reasserts.
    private var latestRepairState: TranscriberHolder.RepairState?
    /// Holder reference for the defensive self-clear guard (self-heal Fix-c):
    /// before re-showing a `.failed` pill, check whether the active model is
    /// actually present on disk and, if so, clear the stale failure instead.
    private weak var transcriberHolder: TranscriberHolder?

    init(
        recorder: RecorderController,
        delivery: DeliveryService,
        rewriteController: RewriteController? = nil,
        transcriberHolder: TranscriberHolder? = nil
    ) {
        self.recorder = recorder
        self.delivery = delivery
        self.rewriteController = rewriteController

        recorderCancellable = recorder.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.recorderStateChanged(state)
            }

        deliveryCancellable = delivery.$lastDelivery
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.deliveryEvent(event)
            }

        // Notice pill surfaces after delivery — subscribe to the trigger
        // publisher (`lastResult`) and read the companion
        // `lastFallbackNotice` synchronously off `recorder`. Per the
        // documented sequencing, `lastFallbackNotice` is set BEFORE
        // `lastResult` so the read here is consistent.
        fallbackNoticeCancellable = recorder.$lastResult
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak recorder] _ in
                guard let self, let recorder else { return }
                guard let notice = recorder.consumeFallbackNotice() else { return }
                // Defer slightly so the success pill can register its
                // dismiss timer before we replace the state. Without
                // this, the notice would steal the linger on a fresh
                // success.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.successLinger * 1_000_000_000))
                    self?.showNotice(notice)
                }
            }

        if let rewriteController {
            rewriteCancellable = rewriteController.$state
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.rewriteStateChanged(state)
                }
            rewriteResultCancellable = rewriteController.$lastRewrite
                .compactMap { $0 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] result in
                    self?.showRewriteSuccess(result)
                }
            rewriteAugmentHintCancellable = rewriteController.$augmentHint
                .receive(on: DispatchQueue.main)
                .sink { [weak self] hint in
                    self?.augmentHint = hint
                }
        }

        // Streaming partial subscriber — drives the live preview text
        // shown inside the recording pill for the streaming option.
        // No-op for non-streaming primaries because the store stays
        // empty (the pipeline never calls `beginSession` / `publish`
        // unless the active transcriber is a `DualPipelineTranscriber`).
        streamingPartialCancellable = StreamingPartialStore.shared.$partial
            .receive(on: DispatchQueue.main)
            .sink { [weak self] partial in
                self?.streamingPartialChanged(partial)
            }

        // Streaming-session-active subscriber — drives whether the pill
        // is tappable / expandable. `false` for non-streaming primaries
        // so v3 / JA recordings stay click-through.
        streamingActiveCancellable = StreamingPartialStore.shared.$isActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.isStreamingSessionActive = active
                if !active {
                    self?.isPillExpanded = false
                }
            }

        // Persistent repairing pill — driven straight off the holder's
        // self-heal producer. Yields to any in-flight recording/rewrite so it
        // never masks live dictation, and reasserts once those clear.
        self.transcriberHolder = transcriberHolder
        if let transcriberHolder {
            repairCancellable = transcriberHolder.$repairState
                .receive(on: DispatchQueue.main)
                .sink { [weak self] repair in
                    self?.repairStateChanged(repair)
                }
        }
    }

    // MARK: - Repair (self-heal) transitions

    /// Mirror the holder's `repairState` onto the pill. Persistent: this never
    /// schedules a dismiss. Yields to an in-flight recorder/rewrite pipeline so
    /// live dictation isn't masked; `reassertRepairIfNeeded()` brings the pill
    /// back when those transient states clear.
    private func repairStateChanged(_ repair: TranscriberHolder.RepairState?) {
        latestRepairState = repair
        guard let repair else {
            // Heal finished — clear the pill only if it's currently the repair
            // pill (don't stomp an in-flight recording/success/error).
            if case .repairingModel = state {
                transition(to: .hidden)
            }
            return
        }
        // Don't override an in-flight recording / transcribing / rewrite — the
        // user is actively dictating (possibly on the transient fallback).
        switch state {
        case .recording, .transcribing, .transforming, .rewriting, .condensing, .holdProgress:
            return
        case .askCorrection:
            // An in-flight ask is holding a paste decision — don't mask it with
            // the (persistent) repair pill; it reasserts once the ask resolves.
            return
        case .hidden, .success, .notice, .savedToRecents, .error, .repairingModel:
            transition(to: Self.repairPillState(for: repair))
        }
    }

    /// Re-show the persistent repair pill if a heal is still in flight and the
    /// pill is currently idle/terminal. Called from the recorder/rewrite
    /// `.idle` branches so the backup surface reappears after a recording.
    private func reassertRepairIfNeeded() {
        guard let repair = latestRepairState else { return }
        // Defensive self-clear (self-heal Fix-c): never re-show a `.failed`
        // pill for a model that is actually present on disk — the failure is
        // stale (the download completed via some other path). Ask the holder to
        // drop it; `installedModelIDs` reflects the on-disk presence scan. This
        // is a cheap presence check (won't catch a corrupt-but-present bundle),
        // but Fix-a (clear on a real successful transcription) covers that case.
        if case .failed = repair,
           let holder = transcriberHolder,
           holder.installedModelIDs.contains(holder.activeModelID) {
            holder.noteActiveModelHealthy()
            latestRepairState = nil
            return
        }
        switch state {
        case .hidden:
            transition(to: Self.repairPillState(for: repair))
        default:
            break
        }
    }

    private static func repairPillState(for repair: TranscriberHolder.RepairState) -> PillState {
        switch repair {
        case .downloading(let modelName, let progress):
            return .repairingModel(modelName: modelName, progress: progress, isError: false)
        case .failed(let modelName, _):
            return .repairingModel(modelName: modelName, progress: nil, isError: true)
        }
    }

    private func streamingPartialChanged(_ partial: String?) {
        latestPartial = partial
        // Only rebuild state while we're currently recording —
        // streaming text only renders inside the recording pill.
        if case .recording(let elapsed, _) = state {
            let next: PillState = .recording(elapsed: elapsed, streamingPartial: partial)
            if next != state {
                state = next
            }
        }
    }

    deinit {
        tickTimer?.invalidate()
        dismissTask?.cancel()
    }

    // MARK: - External transitions (Prompt Picker hold detection)

    /// Drive the press-and-hold progress fill. Called every frame by
    /// `RewriteHoldDetector` between the 200ms grace and the 1.2s
    /// threshold. Yields if the user is mid-recording / rewriting /
    /// transcribing so an in-flight pipeline isn't masked.
    /// Returns whether the transition was accepted.
    @discardableResult
    func showHoldProgress(_ progress: Double) -> Bool {
        switch state {
        case .hidden, .holdProgress:
            transition(to: .holdProgress(progress: max(0.0, min(1.0, progress))))
            return true
        case .recording, .transcribing, .transforming, .rewriting,
             .condensing, .success, .notice, .savedToRecents, .error,
             .repairingModel, .askCorrection:
            return false
        }
    }

    /// Tear the hold-progress pill down. Called on early release or
    /// on threshold (when the picker takes over). Only clears if the
    /// pill is currently showing hold-progress — leaves other states
    /// alone.
    func clearHoldProgress() {
        if case .holdProgress = state {
            transition(to: .hidden)
        }
    }

    // MARK: - External transitions (Ask Jot voice input)

    /// Show the "Condensing" pill while `ChatbotVoiceInput` runs the
    /// Apple-Intelligence condensation step on a freshly transcribed
    /// question. Idempotent — repeated calls stay on the condensing
    /// state. Overrides transient success/error from prior flows so the
    /// pill reads the current work.
    func showCondensing() {
        stopTick()
        transition(to: .condensing)
    }

    /// Hide the pill if and only if it's currently showing condensing.
    /// Called when the condensation pipeline finishes (either with the
    /// condensed text or the silent raw-fallback).
    func hideIfCondensing() {
        if case .condensing = state {
            transition(to: .hidden)
        }
    }

    // MARK: - Recorder transitions

    private func recorderStateChanged(_ state: RecorderController.State) {
        switch state {
        case .idle:
            // Don't immediately clear — the recorder hops through .idle on its
            // way to delivering a transcript. If we're currently showing
            // success/error/notice, leave that alone. If we're in recording or
            // transcribing, hide (e.g. a cancel).
            switch self.state {
            case .success, .error, .notice, .savedToRecents, .hidden, .rewriting, .condensing, .holdProgress, .repairingModel, .askCorrection:
                // .askCorrection: the ask lives entirely POST-pipeline (the
                // recorder is already .idle while the bridge holds the paste), so
                // a hop through .idle must NOT tear it down.
                break
            case .recording, .transcribing, .transforming:
                transition(to: .hidden)
                // Backup repairing pill reasserts after a recording clears.
                reassertRepairIfNeeded()
            }
        case .recording(let startedAt):
            // §6: a NEW recording ABANDONS any pending ask (the prior transcript
            // is already safe in Recents) BEFORE the recording pill claims the
            // surface — we deliberately do NOT fire the held paste, to avoid a
            // late async paste landing in the new focus / stomping this pill.
            forceResolvePendingAskKeepOriginal()
            isRewriteVoiceCapture = false
            recordingStartedAt = startedAt
            transition(to: .recording(elapsed: Date().timeIntervalSince(startedAt), streamingPartial: latestPartial))
            startTick()
        case .transcribing:
            stopTick()
            transition(to: .transcribing)
        case .transforming:
            stopTick()
            transition(to: .transforming)
        case .error(let message):
            stopTick()
            transition(to: .error(message: message))
            scheduleDismiss(after: Self.errorLinger)
        }
    }

    // MARK: - Rewrite transitions

    private func rewriteStateChanged(_ rewriteState: RewriteController.RewriteState) {
        switch rewriteState {
        case .idle:
            switch self.state {
            case .success, .error, .notice, .savedToRecents, .hidden, .condensing, .holdProgress, .repairingModel, .askCorrection:
                break
            case .recording, .transcribing, .rewriting, .transforming:
                transition(to: .hidden)
                reassertRepairIfNeeded()
            }
        case .capturing:
            break
        case .recording(let startedAt):
            isRewriteVoiceCapture = true
            recordingStartedAt = startedAt
            transition(to: .recording(elapsed: Date().timeIntervalSince(startedAt), streamingPartial: latestPartial))
            startTick()
        case .transcribing:
            stopTick()
            transition(to: .transcribing)
        case .rewriting:
            stopTick()
            transition(to: .rewriting)
        case .error(let message):
            stopTick()
            transition(to: .error(message: message))
            scheduleDismiss(after: Self.errorLinger)
        }
    }

    func showRewriteSuccess(_ result: String) {
        stopTick()
        transition(to: .success(preview: Self.previewText(result)))
        scheduleDismiss(after: Self.successLinger)
    }

    // MARK: - Delivery transitions

    private func deliveryEvent(_ event: DeliveryEvent) {
        stopTick()
        switch event {
        case .pasted(let text):
            transitionToSuccessIfNotError(text)
        case .clipboardOnly(let text, _):
            // Still a successful transcript from the user's point of view —
            // it's on their clipboard. Any "why didn't it paste" nuance
            // lives in the menu bar / toast, not in the pill.
            transitionToSuccessIfNotError(text)
        case .failed(let reason):
            transition(to: .error(message: reason))
            scheduleDismiss(after: Self.errorLinger)
        }
    }

    // MARK: - State transition plumbing

    private func transition(to new: PillState) {
        dismissTask?.cancel()
        dismissTask = nil
        // Collapse the expanded recording view on any state transition.
        // Keeps the expanded panel from outliving the streaming session.
        if case .recording = new {
            // Stay in current expanded state across rebuilds of the
            // recording state (timer tick, partial update). Only reset
            // when the pill leaves recording entirely.
        } else {
            isPillExpanded = false
        }
        // v1.14: pending saved-recording id is only valid while the
        // savedToRecents pill is on screen. Clear on any other transition
        // so a stale id can't ride a future click handler invocation.
        if case .savedToRecents = new {
            // keep the id we just stored in `showSavedToRecents(...)`
        } else {
            pendingSavedRecordingAudioFile = nil
        }
        state = new
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.state = .hidden
            // A still-in-flight repair (incl. a terminal `.failed`) is the
            // persistent backup surface — bring it back once this transient
            // success/notice/error pill auto-dismisses.
            self.reassertRepairIfNeeded()
        }
    }

    // MARK: - Elapsed-time tick

    private func startTick() {
        stopTick()
        // Fire at 0.5s cadence — the pill displays mm:ss so sub-second
        // precision is wasted; a 0.5s tick keeps the seconds digit tidy
        // without redrawing every frame.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard let started = recordingStartedAt else { return }
        let elapsed = Date().timeIntervalSince(started)
        if case .recording = state {
            // Preserve the cached streaming partial across rebuilds.
            // Without this, the 0.5 s tick clears the partial text
            // twice a second — visible flicker. Equality on the new
            // state is built into PillState's `Equatable` synthesis,
            // so SwiftUI redraws only when elapsed or partial actually
            // changed.
            state = .recording(elapsed: elapsed, streamingPartial: latestPartial)
        }
    }

    // MARK: - Helpers

    private static func previewText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 40 { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: 40)
        return String(trimmed[..<idx]) + "…"
    }

    private func transitionToSuccessIfNotError(_ text: String) {
        guard case .error = state else {
            transition(to: .success(preview: Self.previewText(text)))
            scheduleDismiss(after: Self.successLinger)
            return
        }
    }

    // MARK: - Notice (informational, non-failure)

    /// Surface a short informational pill (e.g. "Recorded with system default —
    /// \(savedName) was unavailable."). Yields to an in-flight error so a real
    /// failure isn't masked, but otherwise replaces success/notice/idle. The
    /// `RecorderController.lastFallbackNotice` flow chains this after the
    /// success pill has dismissed.
    func showNotice(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .error = state { return }
        // Slice D: never stomp a live ask — the held paste must resolve first.
        if isAwaitingAskCorrection { return }
        stopTick()
        transition(to: .notice(message: trimmed))
        scheduleDismiss(after: Self.successLinger)
    }

    /// v1.14: surface the post-Esc / post-pill-click affordance. Renders
    /// as a clickable pill that opens Recents when tapped. Yields to an
    /// in-flight error so a real failure isn't masked; otherwise replaces
    /// any other terminal state. The click handler must already be set
    /// on `onSavedToRecentsTap` for the affordance to act on the click.
    /// `audioFileName` is the identifier the click handler uses to
    /// navigate to the specific Recording detail.
    func showSavedToRecents(preview: String, audioFileName: String?) {
        if case .error = state { return }
        stopTick()
        pendingSavedRecordingAudioFile = audioFileName
        transition(to: .savedToRecents(preview: Self.previewText(preview)))
        scheduleDismiss(after: Self.savedToRecentsLinger)
    }

    /// v1.14: called by the `PillView` when the saved-to-Recents pill
    /// is tapped. Looks up the captured `pendingSavedRecordingAudioFile`
    /// and forwards it to the installed `onSavedToRecentsTap` handler.
    /// No-op if the handler hasn't been wired by composition.
    func invokeSavedToRecentsTap() {
        onSavedToRecentsTap?(pendingSavedRecordingAudioFile)
    }

    // MARK: - Ask-before-paste (Slice D)

    /// Show the live "Did you mean \"<term>\"?" prompt and hold here until the
    /// user confirms / dismisses, the ask times out, or an outside click /
    /// new recording force-resolves it. The delivery bridge supplies the
    /// resolution closures — `onConfirm` applies the term + delivers, `onDismiss`
    /// keeps the original + delivers. Exactly ONE of them runs (single-resolution
    /// invariant), then the ask is torn down. The bridge sequences multiple
    /// candidates by calling this again from inside its own closures.
    func showAskCorrection(
        original: String,
        term: String,
        contextBefore: String,
        contextAfter: String,
        applied: Bool,
        onConfirm: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onAccept: @escaping () -> Void
    ) {
        // Tear down any in-flight ask WITHOUT delivering — the bridge that
        // started this new ask is the single owner of the deliver() decision and
        // is driving the sequence; a stale closure firing here would double-fire.
        askTimeoutTask?.cancel()
        askTimeoutTask = nil
        onAskConfirm = onConfirm
        onAskDismiss = onDismiss
        onAskAccept = onAccept
        isAwaitingAskCorrection = true
        stopTick()
        transition(to: .askCorrection(
            original: original,
            term: term,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            applied: applied
        ))
        // After the linger, auto-ACCEPT the gate's decision (deliver staged
        // as-is) — NOT revert. The user shouldn't have to click for the default
        // to take effect. Dedicated task so an unrelated transition can't cancel
        // it (§8 M4/M5).
        askTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.askLinger * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.resolveAsk(outcome: .accept)
        }
    }

    /// How an ask resolves. `confirm` = apply the offered term (+ learn);
    /// `keepOriginal` = explicit revert to the spoken word; `accept` = take the
    /// gate's current decision unchanged (timeout / outside-click — no click).
    private enum AskOutcome { case confirm, keepOriginal, accept }

    /// Confirm the current ask (⏎ / "Use term" button) — apply the offered term.
    func confirmAsk() { resolveAsk(outcome: .confirm) }

    /// Explicit keep-original (esc / "Keep" button) — revert to the spoken word.
    func dismissAsk() { resolveAsk(outcome: .keepOriginal) }

    /// Non-interactive resolution (10s timeout / outside-click) — accept the
    /// gate's default (staged text as-is), so an ignored ask still delivers.
    func acceptAsk() { resolveAsk(outcome: .accept) }

    /// THE single resolution path for an ask (§8 M4/M5). Idempotent: the first
    /// call consumes the closures and fires exactly one of them; subsequent calls
    /// are no-ops. ALWAYS ends by invoking a bridge closure — each of which
    /// terminates in exactly one `deliver()` — so the held paste can never be
    /// silently dropped. Does NOT itself transition the pill to a terminal state;
    /// the bridge either starts the next ask (sequential) or, on the last one,
    /// the resulting `deliver()` drives the normal success pill.
    private func resolveAsk(outcome: AskOutcome) {
        // Snapshot-and-clear so a re-entrant call (e.g. outside-click racing the
        // timeout) can't fire twice.
        guard isAwaitingAskCorrection else { return }
        let confirm = onAskConfirm
        let dismiss = onAskDismiss
        let accept = onAskAccept
        onAskConfirm = nil
        onAskDismiss = nil
        onAskAccept = nil
        isAwaitingAskCorrection = false
        askTimeoutTask?.cancel()
        askTimeoutTask = nil
        switch outcome {
        case .confirm: confirm?()
        case .keepOriginal: dismiss?()
        case .accept: (accept ?? dismiss)?()
        }
    }

    /// Force-abandon a pending ask when a NEW recording begins (the recorder is
    /// about to claim the pill). §6 offers two options — deliver-kept-original, or
    /// abandon since the recording is already saved to Recents. We ABANDON: the
    /// alternative (firing the deliver chain here) would async-paste the prior
    /// transcript into whatever now has focus AND stomp the fresh `.recording`
    /// pill with a late `.success`. The user can paste-last or open Recents to
    /// recover the abandoned transcript. Closures are dropped WITHOUT firing, and
    /// the ask is torn down so the recording pill takes over cleanly.
    func forceResolvePendingAskKeepOriginal() {
        guard isAwaitingAskCorrection else { return }
        onAskConfirm = nil
        onAskDismiss = nil
        onAskAccept = nil
        isAwaitingAskCorrection = false
        askTimeoutTask?.cancel()
        askTimeoutTask = nil
    }

    /// Format a duration as `mm:ss` — caps at `99:59`, which is fine because
    /// nobody is using dictation for a 100-minute monologue.
    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let m = min(99, total / 60)
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
