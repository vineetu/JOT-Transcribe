import Combine
import Foundation
import os.log

/// Voice-input bridge for the Ask Jot chatbot (spec v5 §8).
///
/// Responsibilities:
///   1. Own the "mic button in the chatbot TextField" lifecycle: start/stop
///      a Parakeet ASR capture through the shared `VoiceInputPipeline`.
///   2. On stop, run an Apple-Intelligence condensation pass (10-second
///      budget) to tighten the rambled spoken question into a single
///      clean sentence — if the pass fails or produces degenerate output,
///      we silently return the raw transcript.
///   3. Mutually exclude with the global dictation recorder so the user
///      can't run two captures on one pipeline.
///   4. Drive the status pill through "Recording → Transcribing →
///      Condensing" states while the pipeline churns, so the chatbot's
///      voice-input UX reads identically to Jot's main dictation flow.
///
/// Deliberately lives at the AskJot layer rather than inside the existing
/// Recording / Articulate layers — Ask Jot is product-owned infra and has
/// its own provider policy (always Apple Intelligence, regardless of the
/// user's configured Cleanup/Articulate provider). Mixing the provider
/// logic into the generic Articulate path would leak that policy.
///
/// NOTE(team2a): call `capture()` from the chatbot mic-button handler.
/// `capture()` returns the text to place in the chatbot TextField. The
/// caller decides whether to auto-send after a 2s idle or wait for the
/// user to confirm (spec v5 §8 explicitly forbids auto-send of raw
/// without user confirmation). `cancel()` from an Esc handler if the user
/// aborts mid-capture or mid-condensation.
@MainActor
final class ChatbotVoiceInput: ObservableObject {

    /// Drives the mic button glyph / tooltip / enablement. Mirrors spec
    /// §8 "Mic button states" exactly.
    enum MicState: Equatable, Sendable {
        case idle
        case disabled(reason: DisableReason)
        case recording
        case transcribing
        case condensing
        case error(String)

        enum DisableReason: Equatable, Sendable {
            /// Global dictation recording is in flight — finish that first.
            case globalRecordingActive
            /// Mic permission missing / denied.
            case micPermissionDenied
            /// Apple Intelligence unavailable (we still allow raw capture
            /// in principle, but without condensation the UX degrades; at
            /// the spec level we show the mic as available and fall back
            /// to raw. We keep this enum case for future use — currently
            /// unreferenced by `refreshAvailability()`).
            case appleIntelligenceUnavailable
        }
    }

    @Published private(set) var state: MicState = .idle

    // MARK: - Dependencies

    private let pipeline: VoiceInputPipeline
    private let recorder: RecorderController
    private let pill: PillViewModel?
    private let condenser: ChatbotCondenser
    private let log = Logger(subsystem: "com.jot.Jot", category: "ChatbotVoiceInput")

    // MARK: - Mutual exclusion with global recording

    private var recorderObservation: AnyCancellable?
    private var isGlobalRecordingActive = false {
        didSet {
            guard oldValue != isGlobalRecordingActive else { return }
            if isGlobalRecordingActive {
                // If we're currently capturing, cancel and discard.
                if case .recording = state {
                    Task { await self.cancel() }
                }
                // Advertise disabled state for the button.
                if case .idle = state {
                    state = .disabled(reason: .globalRecordingActive)
                }
            } else if case .disabled(.globalRecordingActive) = state {
                state = .idle
            }
        }
    }

    // MARK: - Active capture

    private var activeToken: VoiceInputPipeline.Token?
    private var activeCaptureTask: Task<String, Error>?
    /// The outer post-recording Task launched by `stop()` so cancel
    /// can interrupt the whole transcribe → condense pipeline at any
    /// stage. Phase 2 I1 fix: this used to be an unstored
    /// `Task { try? await stopAndProcess() }` — `cancel()` had no
    /// reference to it, so cancellation was a silent no-op.
    private var activeStopProcessTask: Task<Void, Never>?
    /// Wraps the inline `condenseIfEligible(...)` call inside
    /// `stopAndProcess()` so cancel can propagate into the condenser
    /// (which races a 10s budget timer against the Apple
    /// Intelligence call). Phase 2 I1 fix: previously declared but
    /// never assigned — `cancel()` cancelled a perpetually-nil
    /// reference.
    private var condensationTask: Task<String, Never>?

    // MARK: - Init

    init(
        pipeline: VoiceInputPipeline,
        recorder: RecorderController,
        pill: PillViewModel? = nil,
        condenser: ChatbotCondenser
    ) {
        self.pipeline = pipeline
        self.recorder = recorder
        self.pill = pill
        self.condenser = condenser

        // Observe global recording state so we can disable the mic and
        // cancel in-flight chatbot captures when the user kicks off a
        // normal dictation while the chatbot mic is live.
        recorderObservation = recorder.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recorderState in
                guard let self else { return }
                switch recorderState {
                case .recording, .transcribing, .transforming:
                    self.isGlobalRecordingActive = true
                case .idle, .error:
                    self.isGlobalRecordingActive = false
                }
            }
    }

    // MARK: - Public API

    /// Start-and-await entry point for the mic button.
    ///
    /// The typical integration for 2A's view is:
    ///   * first mic tap → `Task { try await voiceInput.capture() }` —
    ///     returns the final text (condensed or raw fallback)
    ///   * second mic tap → `voiceInput.stop()` — ends the capture so
    ///     the awaiting `capture()` resolves
    ///   * Esc or navigate-away → `voiceInput.cancel()` — silently discards
    ///
    /// Not re-entrant: call while the state is `.recording` / `.transcribing`
    /// / `.condensing` throws. Caller disables the button for the duration.
    ///
    /// TODO(team2a): connect this to your TextField's mic button handler.
    /// The returned string is what you put in the field (per spec §8,
    /// never auto-send without user confirmation).
    func capture() async throws -> String {
        if case .disabled(let reason) = state {
            throw VoiceInputError.disabled(reason)
        }
        if case .recording = state { throw VoiceInputError.alreadyRecording }
        if case .transcribing = state { throw VoiceInputError.alreadyRecording }
        if case .condensing = state { throw VoiceInputError.alreadyRecording }

        try await start()
        return try await waitForStopAndProcess()
    }

    /// Signal the awaiting `capture()` to finish. Kicks off transcription
    /// → condensation. Returns immediately; the result is delivered on
    /// the original `capture()` Task.
    func stop() {
        guard case .recording = state, activeToken != nil else { return }
        // Launch the process on its own Task so the UI's stop handler
        // can return without awaiting. **Stored** (`activeStopProcessTask`)
        // so `cancel()` can interrupt the post-recording pipeline at
        // any stage. Phase 2 I1 fix.
        activeStopProcessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.stopAndProcess()
        }
    }

    /// User-initiated cancel (Esc in chatbot, or mic re-tapped before the
    /// pipeline completes). Silent — no error surfaced to chat UI.
    func cancel() async {
        // Phase 2 I1 fix: cancel BOTH the inner condensation task AND
        // the outer post-recording task. Cancelling only
        // `condensationTask` was insufficient — the parent
        // `stopAndProcess` Task (launched from `stop()`) kept running
        // even after the inner task was cancelled. Both must be
        // stopped for cancel to actually propagate end-to-end.
        condensationTask?.cancel()
        condensationTask = nil

        activeStopProcessTask?.cancel()
        activeStopProcessTask = nil

        let token = activeToken
        activeToken = nil
        activeCaptureTask?.cancel()
        activeCaptureTask = nil
        pendingStopContinuation?.resume(throwing: CancellationError())
        pendingStopContinuation = nil

        if let token {
            await pipeline.cancel(token: token)
        }
        pill?.hideIfCondensing()
        state = isGlobalRecordingActive ? .disabled(reason: .globalRecordingActive) : .idle
    }

    // MARK: - Internal — recording lifecycle

    private var pendingStopContinuation: CheckedContinuation<String, Error>?

    private func start() async throws {
        guard !isGlobalRecordingActive else {
            throw VoiceInputError.disabled(.globalRecordingActive)
        }
        do {
            let token = try await pipeline.startRecording(owner: .articulate)
            activeToken = token
            state = .recording
        } catch VoiceInputPipeline.PipelineError.micNotGranted {
            state = .disabled(reason: .micPermissionDenied)
            throw VoiceInputError.disabled(.micPermissionDenied)
        } catch {
            state = .error("Couldn't start recording.")
            throw error
        }
    }

    /// Suspends until a matching `stopAndProcess()` call (second mic tap)
    /// resolves the continuation.
    private func waitForStopAndProcess() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            pendingStopContinuation = continuation
        }
    }

    /// Second-tap path — finishes the recording, transcribes, condenses,
    /// and fulfills the continuation from `waitForStopAndProcess`.
    private func stopAndProcess() async throws -> String {
        guard let token = activeToken else {
            throw VoiceInputError.notRecording
        }
        state = .transcribing
        do {
            try Task.checkCancellation()
            let result = try await pipeline.stopAndTranscribe(token)
            let raw = result.text
            // Condensation phase. Phase 2 I1 fix: wrap
            // `condenseIfEligible` in a stored Task so `cancel()` can
            // propagate cancellation into the condenser (which races
            // a 10s budget timer against the Apple Intelligence call).
            // The Task<String, Never> shape means cancel doesn't make
            // the awaiter throw — `condenseIfEligible` returns the
            // raw `trimmed` text on cancellation as its graceful
            // fallback. The cancel signal still reaches the
            // condenser's `Task.sleep` / `Task.checkCancellation`,
            // which is what the I1 regression test asserts on.
            try Task.checkCancellation()
            state = .condensing
            pill?.showCondensing()
            let condensation = Task { [condenser] in
                await Self.condenseIfEligible(raw: raw, condenser: condenser)
            }
            condensationTask = condensation
            let final = await condensation.value
            condensationTask = nil
            try Task.checkCancellation()
            pill?.hideIfCondensing()
            activeToken = nil
            state = isGlobalRecordingActive ? .disabled(reason: .globalRecordingActive) : .idle
            if let continuation = pendingStopContinuation {
                pendingStopContinuation = nil
                continuation.resume(returning: final)
            }
            return final
        } catch is CancellationError {
            // User-initiated cancel — `cancel()` already cleaned up
            // (cleared `activeToken`, hid the pill, transitioned to
            // `.idle`). Propagate the cancel to the awaiting
            // `capture()` continuation if it's still pending; do NOT
            // overwrite state with `.error("Voice capture failed.")`.
            condensationTask = nil
            if let continuation = pendingStopContinuation {
                pendingStopContinuation = nil
                continuation.resume(throwing: CancellationError())
            }
            throw CancellationError()
        } catch {
            condensationTask = nil
            activeToken = nil
            pill?.hideIfCondensing()
            state = .error("Voice capture failed.")
            if let continuation = pendingStopContinuation {
                pendingStopContinuation = nil
                continuation.resume(throwing: error)
            }
            throw error
        }
    }

    // MARK: - Condensation

    /// Apply the spec §8 skip rules, then run the condenser under a
    /// 10-second budget. Returns either the condensed text (when the
    /// condenser produced a good result within budget) or the raw
    /// transcript (when any skip condition fires or the budget elapses).
    ///
    /// Static + nonisolated so it's exercisable from unit tests without
    /// spinning up the full pipeline / pill / recorder graph.
    nonisolated static func condenseIfEligible(
        raw: String,
        condenser: ChatbotCondenser,
        budget: Duration = .seconds(10),
        clock: ContinuousClock = ContinuousClock()
    ) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if shouldSkipCondensation(raw: trimmed) {
            return trimmed
        }

        // Race condenser.condense(...) against a 10-second timer.
        return await withTaskGroup(of: CondenseOutcome.self) { group in
            group.addTask {
                do {
                    let out = try await condenser.condense(raw: trimmed)
                    return .produced(out)
                } catch {
                    return .failed
                }
            }
            group.addTask {
                try? await Task.sleep(for: budget, clock: clock)
                return .timedOut
            }
            guard let first = await group.next() else {
                group.cancelAll()
                return trimmed
            }
            group.cancelAll()
            switch first {
            case .produced(let candidate):
                if isDegenerate(condensed: candidate, raw: trimmed) {
                    return trimmed
                }
                return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            case .failed, .timedOut:
                return trimmed
            }
        }
    }

    private enum CondenseOutcome {
        case produced(String)
        case timedOut
        case failed
    }

    /// Skip conditions per spec §8 — raw too short or too long means
    /// condensation can't help (short inputs become the same sentence;
    /// long inputs exceed the condenser's useful window).
    nonisolated static func shouldSkipCondensation(raw: String) -> Bool {
        let wordCount = Self.wordCount(raw)
        if wordCount < 15 { return true }
        if wordCount > 300 { return true }
        return false
    }

    /// Degenerate-output detection for the condensed string. Fires on
    /// suspiciously short collapses (< 30 % of input length) and on
    /// textual refusal markers. Used both in the live pipeline and in
    /// unit tests.
    nonisolated static func isDegenerate(condensed: String, raw: String) -> Bool {
        let c = condensed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return true }

        // Length-floor check: condensed < 30 % of raw characters → the
        // model probably rewrote the question into "OK." or similar.
        let ratio = Double(c.count) / Double(max(1, raw.count))
        if ratio < 0.30 { return true }

        // Refusal markers — case-insensitive substring match.
        let lower = c.lowercased()
        let refusals = [
            "i cannot",
            "i can't",
            "i don't understand",
            "i do not understand",
            "i'm unable",
        ]
        for marker in refusals {
            if lower.contains(marker) { return true }
        }
        return false
    }

    nonisolated static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { !$0.isEmpty }
            .count
    }
}

// MARK: - Errors

enum VoiceInputError: Error, Equatable {
    case disabled(ChatbotVoiceInput.MicState.DisableReason)
    case notRecording
    case alreadyRecording
}

// MARK: - Condenser abstraction

/// Protocol seam so unit tests can inject a fake condenser without
/// touching Apple Intelligence. Real calls route through
/// `AppleIntelligenceCondenser` (spec §8: chatbot condensation is
/// hardcoded to Apple Intelligence regardless of the user's configured
/// Articulate provider).
protocol ChatbotCondenser: Sendable {
    func condense(raw: String) async throws -> String
}

extension ChatbotCondenser where Self == AppleIntelligenceCondenser {
    /// Live default: routes through `AppServices.appleIntelligence` so the
    /// harness can inject a stub conformer. Resolved at MainActor read time
    /// because `AppServices.live` is `@MainActor` — the read happens
    /// synchronously inside this `@MainActor` factory.
    @MainActor
    static var appleIntelligence: AppleIntelligenceCondenser {
        AppleIntelligenceCondenser(client: AppServices.live?.appleIntelligence)
    }
}

/// Production condenser — wraps an `AppleIntelligenceClienting` (Phase 0.6
/// seam) with the spec §8 condensation prompt. We reuse the `articulate`
/// path (not `transform`) because its instruction/selection framing happens
/// to match how we want to describe "the spoken question is the selection,
/// condense it."
struct AppleIntelligenceCondenser: ChatbotCondenser {
    /// Spec §8 prompt verbatim. Keep the trailing `Condensed:` cue — it
    /// gives the model a clear insertion point for completion.
    static let prompt = """
        Condense this spoken question about the Jot Mac app into a clear, single \
        sentence. Remove filler, self-corrections, and rambling. Preserve intent \
        exactly. Do not answer — just rewrite the question.
        """

    /// Apple Intelligence seam. Captured at init time (the static factory
    /// `ChatbotCondenser.appleIntelligence` reads `AppServices.live` on
    /// `@MainActor` and hands the resolved instance in here) so
    /// `condense(raw:)` doesn't need a MainActor hop.
    private let client: any AppleIntelligenceClienting

    init(client: (any AppleIntelligenceClienting)? = nil) {
        self.client = client ?? AppleIntelligenceClient()
    }

    func condense(raw: String) async throws -> String {
        // We call `articulate(...)` because its content framing ("take
        // this selection, follow the instruction, return only the
        // rewrite") is exactly what we need. The "instruction" slot
        // carries our condensation prompt; the "selection" slot carries
        // the raw spoken question.
        return try await client.articulate(
            selectedText: raw,
            instruction: "Condense the <selection> into a clear, single question sentence, preserving intent.",
            branchPrompt: Self.prompt
        )
    }
}
