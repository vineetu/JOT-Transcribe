import FluidAudio
import Foundation

/// Output of a single transcription pass.
///
/// `rawText` is the model's output before Jot's `PostProcessing` runs —
/// preserved so a future "re-apply post-processing" operation (e.g. after a
/// custom-vocabulary edit) doesn't need to rerun the model.
/// `text` is the user-facing version — post-processing applied.
public struct TranscriptionResult: Sendable {
    public let text: String
    public let rawText: String
    public let duration: TimeInterval
    public let processingTime: TimeInterval
    public let confidence: Float
    /// Slice D (ask-before-paste). The de-duped vocabulary corrections the gate
    /// produced for this transcript, carried as structured `{from,to,askCandidate}`
    /// pairs (NOT char offsets — those don't survive the downstream Transform
    /// rewrite; see `ask-ux.md` §8 B1). The delivery bridge string-matches the
    /// `askCandidate` ones against the FINAL text to decide whether to hold the
    /// paste and ask "Did you mean X?". Empty for the no-vocab / no-correction
    /// path (the overwhelming majority) → zero added latency there.
    public let corrections: [VocabularyRescorerHolder.UXCorrection]
    /// Speaker diarization (design `docs/speaker-diarization/design.md`,
    /// "Token→speaker alignment"): per-word timing from the Parakeet TDT
    /// decoder, surfaced so a future diarization pass could refine
    /// speaker-turn boundaries against the RAW transcript. Populated only
    /// on the Parakeet `AsrManager` path (`Transcriber.transcribeWithAsrManager`);
    /// `nil` for Nemotron (no per-word timings) and for every other caller.
    /// Every initializer defaults this to `nil` so the ripple is
    /// compiler-checked, not a behavior change for existing call sites.
    public let tokenTimings: [TokenTiming]?

    public init(
        text: String,
        rawText: String,
        duration: TimeInterval,
        processingTime: TimeInterval,
        confidence: Float,
        corrections: [VocabularyRescorerHolder.UXCorrection] = [],
        tokenTimings: [TokenTiming]? = nil
    ) {
        self.text = text
        self.rawText = rawText
        self.duration = duration
        self.processingTime = processingTime
        self.confidence = confidence
        self.corrections = corrections
        self.tokenTimings = tokenTimings
    }
}
