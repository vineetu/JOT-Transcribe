import Foundation
import Testing
@testable import Jot

/// Phase 1.6 acceptance: drive `JotHarness.askJotVoice(...)` end-to-end
/// through the live `ChatbotVoiceInput` graph.
///
/// Three tests:
/// 1. **Happy path** — condensation completes, `result.condensed`
///    carries the canned output, `condensationTaskWasCancelled == false`.
/// 2. **Short-input skip** (spec §8) — transcripts with <15 words
///    bypass condensation; the `StubCondenser`'s `condense(raw:)` is
///    never invoked.
/// 3. **I1 regression** — `withKnownIssue` wrapper. The
///    `StubCondenser` sleeps 5 seconds; cancel-during-condensation
///    should propagate immediately and outcome should land
///    `.cancelled`. Today the bug at
///    `Sources/AskJot/ChatbotVoiceInput.swift:229` (the inline
///    `await Self.condenseIfEligible(...)` call is never wrapped in
///    a Task and never assigned to `condensationTask`) means
///    `cancel()` is a silent no-op. Outcome stays nil at the 500ms
///    observation window. Phase 2 fix (capture the Task, propagate
///    cancellation) flips the outcome to `.cancelled` within ms.
///
/// `.serialized` because the suite shares process-global state
/// (`@AppStorage` keys, `StubURLProtocol.pending`,
/// `FirstRunState.shared`) with other harness suites. Same rationale
/// as `ArticulateFlowTests`.
@MainActor
@Suite(.serialized)
struct AskJotFlowTests {

    // MARK: - Happy path

    @Test func askJotVoiceHappyPath() async throws {
        let harness = try await JotHarness(seed: .default)
        // The canned output must be ≥30% of the raw transcript by
        // character count, otherwise `ChatbotVoiceInput.isDegenerate`
        // (line 323) rejects it as a degenerate response and the
        // flow falls back to the raw transcript. The harness's
        // default raw is ~150 chars; 50+ chars of canned condense
        // clears the 30% floor.
        let canned = "How do I change the dictation hotkey and where does Jot store my recordings?"
        let stubCondenser = StubCondenser(
            cannedOutput: canned,
            sleepDuration: .milliseconds(50)
        )

        let result = try await harness.askJotVoice(
            audio: .samples([Float](repeating: 0, count: 16_000)),
            condenserOverride: stubCondenser
        )

        #expect(stubCondenser.outcome == .completed(canned))
        #expect(result.condensed == canned)
        #expect(result.condensationTaskWasCancelled == false)
    }

    // MARK: - Short-input skip (spec §8)

    @Test func askJotVoiceShortInputSkipsCondensation() async throws {
        let harness = try await JotHarness(seed: .default)
        let stubCondenser = StubCondenser(
            cannedOutput: "Condensed.",
            sleepDuration: .milliseconds(50)
        )

        let result = try await harness.askJotVoice(
            audio: .samples([Float](repeating: 0, count: 16_000)),
            transcript: "hi",  // <15 words → shouldSkipCondensation returns true
            condenserOverride: stubCondenser
        )

        // Condenser was never invoked.
        #expect(stubCondenser.outcome == nil)
        // Raw transcript passes through untouched.
        #expect(result.condensed == "hi")
        #expect(result.condensationTaskWasCancelled == false)
    }

    // MARK: - I1 regression (currently FAILING — fixed in Phase 2)

    /// `cleanup-roadmap.md` I1: `ChatbotVoiceInput.stopAndProcess()`
    /// (line 229) awaits `Self.condenseIfEligible(...)` inline —
    /// never wraps it in a Task, never assigns to
    /// `condensationTask`. So `cancel()` (line 170) reads
    /// `condensationTask?.cancel()` against a perpetually-nil
    /// reference: silent no-op.
    ///
    /// **Reproduction:** inject a `StubCondenser` with a 5-second
    /// sleep, drive the flow into `.condensing`, call cancel, then
    /// observe outcome at the 500ms mark.
    ///
    /// **Today:** the StubCondenser's `Task.sleep(.seconds(5))`
    /// runs to completion — the cancel never reached it. Outcome at
    /// 500ms is still nil → `#expect(outcome == .cancelled)` fails
    /// → captured as known issue.
    ///
    /// **Phase 2 (fix):** `condensationTask = Task { ... }` →
    /// cancel propagates → sleep throws → outcome flips to
    /// `.cancelled` within ms → assertion passes → withKnownIssue
    /// flips red because the known issue cleared. That's the cue
    /// to remove the wrapper.
    @Test func askJotVoiceCancelDuringCondensation_I1() async throws {
        let harness = try await JotHarness(seed: .default)
        let stubCondenser = StubCondenser(
            cannedOutput: "Condensed.",
            sleepDuration: .seconds(5)
        )

        let result = try await harness.askJotVoice(
            audio: .samples([Float](repeating: 0, count: 16_000)),
            cancelAfter: .condensing,
            condenserOverride: stubCondenser
        )

        // Phase 2 I1 fix landed: `ChatbotVoiceInput.cancel()` now
        // cancels both the outer `activeStopProcessTask` (launched
        // by `stop()`) and the inner `condensationTask` (wrapping
        // the inline `condenseIfEligible` call at the former
        // line 229). Cancellation propagates into the StubCondenser's
        // `Task.sleep`, which throws CancellationError → outcome
        // flips to `.cancelled`. Two equivalent assertions:
        // mechanism-level (StubCondenser outcome) and field-level
        // (AskJotResult).
        #expect(stubCondenser.outcome == .cancelled)
        #expect(result.condensationTaskWasCancelled == true)
    }
}
