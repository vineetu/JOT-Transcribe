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
        case recording(elapsed: TimeInterval)
        case transcribing
        case condensing   // Ask Jot voice-input condensation (spec v5 §8).
        case rewriting
        case transforming
        case success(preview: String)
        case error(message: String)
    }

    @Published private(set) var state: PillState = .hidden

    /// Auto-dismiss windows (seconds).
    static let successLinger: TimeInterval = 2.4
    /// Non-actionable errors can clear sooner because the pill has no follow-up affordance yet.
    static let errorLinger: TimeInterval = 7.0
    /// Actionable errors should linger longer so a future labeled button has time to be noticed and used.
    static let actionableErrorLinger: TimeInterval = 15.0

    private var recordingStartedAt: Date?
    private var tickTimer: Timer?
    private var dismissTask: Task<Void, Never>?

    private var recorderCancellable: AnyCancellable?
    private var deliveryCancellable: AnyCancellable?
    private var articulateCancellable: AnyCancellable?
    private var articulateResultCancellable: AnyCancellable?

    private weak var recorder: RecorderController?
    private weak var delivery: DeliveryService?
    private weak var articulateController: ArticulateController?

    init(recorder: RecorderController, delivery: DeliveryService, articulateController: ArticulateController? = nil) {
        self.recorder = recorder
        self.delivery = delivery
        self.articulateController = articulateController

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

        if let articulateController {
            articulateCancellable = articulateController.$state
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.articulateStateChanged(state)
                }
            articulateResultCancellable = articulateController.$lastArticulation
                .compactMap { $0 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] result in
                    self?.showArticulateSuccess(result)
                }
        }
    }

    deinit {
        tickTimer?.invalidate()
        dismissTask?.cancel()
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
            // success/error, leave that alone. If we're in recording or
            // transcribing, hide (e.g. a cancel).
            switch self.state {
            case .success, .error, .hidden, .rewriting, .condensing:
                break
            case .recording, .transcribing, .transforming:
                transition(to: .hidden)
            }
        case .recording(let startedAt):
            recordingStartedAt = startedAt
            transition(to: .recording(elapsed: Date().timeIntervalSince(startedAt)))
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

    // MARK: - Articulate transitions

    private func articulateStateChanged(_ articulateState: ArticulateController.ArticulateState) {
        switch articulateState {
        case .idle:
            switch self.state {
            case .success, .error, .hidden, .condensing:
                break
            case .recording, .transcribing, .rewriting, .transforming:
                transition(to: .hidden)
            }
        case .capturing:
            break
        case .recording(let startedAt):
            recordingStartedAt = startedAt
            transition(to: .recording(elapsed: Date().timeIntervalSince(startedAt)))
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

    func showArticulateSuccess(_ result: String) {
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
            state = .recording(elapsed: elapsed)
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

    /// Format a duration as `mm:ss` — caps at `99:59`, which is fine because
    /// nobody is using dictation for a 100-minute monologue.
    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let m = min(99, total / 60)
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
