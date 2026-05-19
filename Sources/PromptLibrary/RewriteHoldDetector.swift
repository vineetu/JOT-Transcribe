import Combine
import Foundation
import os.log

/// Tap-vs-hold dispatcher for the `.rewrite` hotkey.
///
/// Press the key:
///   - Within 0–200ms: silent. Pill shows nothing.
///   - 200ms → threshold (1.2s): pill morphs into a `.holdProgress`
///     fill with "keep holding…" copy.
///   - At threshold: `onHoldComplete()` fires (opens the picker).
///     Subsequent key-up is a no-op.
///
/// Release before threshold: cancels the timer, clears the pill, calls
/// `onTap()` (today's default Rewrite firing).
///
/// All transitions are `@MainActor`. The 200ms grace window and 1.2s
/// threshold are the values locked in
/// `docs/plans/prompt-picker-ux.md` §2.
@MainActor
final class RewriteHoldDetector {
    static let threshold: TimeInterval = 1.2
    static let grace: TimeInterval = 0.2
    /// Cadence at which we push hold-progress updates to the pill while
    /// holding. Aligns with the pill's existing 0.5s recording tick —
    /// finer cadence here makes the ring fill smoother. The full
    /// animation is also handled by SwiftUI's `withAnimation` on the
    /// receiving side, so this is more "drive the animation target"
    /// than "paint every frame."
    private static let tickInterval: TimeInterval = 1.0 / 30.0

    private let onTap: @MainActor () -> Void
    private let onHoldComplete: @MainActor () -> Void
    private let setHoldProgress: @MainActor (Double) -> Void
    private let clearHoldProgress: @MainActor () -> Void
    private let log = Logger(subsystem: "com.jot.Jot", category: "RewriteHoldDetector")

    private var pressedAt: Date?
    private var tickTask: Task<Void, Never>?
    private var thresholdTask: Task<Void, Never>?
    /// Once true, subsequent key-up events are ignored (picker is open
    /// or about to open). Reset on cancel / next press.
    private var thresholdReached = false
    /// Guards against accidental double-down events (key-repeat, the
    /// chord + single-key paths both firing on the same physical press).
    /// While true, additional `keyDown()` calls no-op until `keyUp()` or
    /// `cancel()` resets state.
    private var isPressed = false

    init(
        onTap: @escaping @MainActor () -> Void,
        onHoldComplete: @escaping @MainActor () -> Void,
        setHoldProgress: @escaping @MainActor (Double) -> Void,
        clearHoldProgress: @escaping @MainActor () -> Void
    ) {
        self.onTap = onTap
        self.onHoldComplete = onHoldComplete
        self.setHoldProgress = setHoldProgress
        self.clearHoldProgress = clearHoldProgress
    }

    /// Hotkey was pressed. Starts the grace-then-progress-then-threshold
    /// chain. Idempotent — repeated down events while a hold is already
    /// in flight are dropped.
    func keyDown() {
        guard !isPressed else { return }
        isPressed = true
        thresholdReached = false
        pressedAt = .now

        // Schedule the threshold callback — the only place picker-open
        // is triggered. Cancelling this task is how key-up before the
        // threshold prevents the picker from opening.
        thresholdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.threshold * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.thresholdReached = true
            // Cancel the tick task BEFORE clearing the pill — otherwise
            // a final tick can push `setHoldProgress(1.0)` after the
            // clear, leaving the pill stuck in `.holdProgress` even
            // after the picker has taken over.
            self.tickTask?.cancel()
            self.tickTask = nil
            self.clearHoldProgress()
            self.log.info("rewrite hold completed → opening picker")
            self.onHoldComplete()
        }

        // Drive pill morph from 0.0 → 1.0 across (threshold - grace)
        // seconds, starting after the grace window. Cancelled by the
        // first early release.
        tickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.grace * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Anchor on the actual press time so a delayed start
            // doesn't visually trail the threshold task.
            let started = self.pressedAt ?? .now
            while !Task.isCancelled {
                // Second guard: even if our task hasn't been formally
                // cancelled, the threshold-task may have just fired and
                // is in the middle of clearing the pill. Avoid pushing
                // a stale tick on top of that.
                if self.thresholdReached { break }
                let elapsed = Date().timeIntervalSince(started)
                let progress = min(1.0, max(0.0, (elapsed - Self.grace) / (Self.threshold - Self.grace)))
                self.setHoldProgress(progress)
                if progress >= 1.0 { break }
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            }
        }
    }

    /// Hotkey was released. If the threshold already fired (picker is
    /// open), no-op. Otherwise: stop everything, clear the pill, fire
    /// default rewrite.
    func keyUp() {
        guard isPressed else { return }
        isPressed = false

        if thresholdReached {
            // Picker already opened. Release is a no-op.
            thresholdReached = false
            pressedAt = nil
            return
        }

        // Released before threshold → today's tap behavior.
        thresholdTask?.cancel()
        thresholdTask = nil
        tickTask?.cancel()
        tickTask = nil
        clearHoldProgress()
        pressedAt = nil
        log.info("rewrite tap → firing default rewrite")
        onTap()
    }

    /// External cancel (e.g. wizard override taking control, app losing
    /// focus). Drops all pending work and the pill state without firing
    /// either callback.
    func cancel() {
        isPressed = false
        thresholdReached = false
        pressedAt = nil
        thresholdTask?.cancel(); thresholdTask = nil
        tickTask?.cancel(); tickTask = nil
        clearHoldProgress()
    }
}
