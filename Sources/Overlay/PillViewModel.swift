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
        case error(message: String)
        /// Press-and-hold progress for the Prompt Picker entry. `progress`
        /// is 0.0 → 1.0 across the (threshold − grace) window — the pill
        /// renders a fill / ring driven by this value. Yields to any
        /// active recorder / rewrite state — see `showHoldProgress(_:)`.
        case holdProgress(progress: Double)
    }

    @Published private(set) var state: PillState = .hidden

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

    init(recorder: RecorderController, delivery: DeliveryService, rewriteController: RewriteController? = nil) {
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
             .condensing, .success, .notice, .error:
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
            case .success, .error, .notice, .hidden, .rewriting, .condensing, .holdProgress:
                break
            case .recording, .transcribing, .transforming:
                transition(to: .hidden)
            }
        case .recording(let startedAt):
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
            case .success, .error, .notice, .hidden, .condensing, .holdProgress:
                break
            case .recording, .transcribing, .rewriting, .transforming:
                transition(to: .hidden)
            }
        case .capturing:
            break
        case .recording(let startedAt):
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
        state = new
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.state = .hidden
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
        stopTick()
        transition(to: .notice(message: trimmed))
        scheduleDismiss(after: Self.successLinger)
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
