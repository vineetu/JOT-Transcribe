import Foundation

/// OS-boundary seam for ASR. The live conformer is `Transcriber`
/// (FluidAudio AsrManager + Parakeet TDT 0.6B v3 on the ANE);
/// the harness conformer in `Tests/JotHarness/` returns canned
/// `TranscriptionResult` values without touching CoreML.
///
/// Surface mirrors what call sites currently consume on the concrete
/// `Transcriber` actor: the live `transcribe(_:)` path used by
/// `VoiceInputPipeline`, the `transcribeFile(_:)` path used by Library
/// re-transcribe + Wizard TestStep, the `ensureLoaded()` warmup, and
/// the `isReady` readiness flag the pipeline checks before awaiting
/// transcription.
///
/// Field ownership: `JotComposition.build` constructs a single
/// `Transcriber` and passes it both as `AppServices.transcriber` and
/// as the `transcriber:` argument to `VoiceInputPipeline.init`, so
/// the live graph and any harness-substituted conformer share one
/// instance — no parallel-graph hazard.
///
/// `Sendable` because `Transcriber` is an actor (implicitly Sendable)
/// and a fixture-driven harness conformer can be a `Sendable` struct.
protocol Transcribing: Sendable {
    /// Load Parakeet onto the ANE if not already loaded. Idempotent.
    func ensureLoaded() async throws

    /// Transcribe a 16 kHz mono Float32 buffer into a
    /// `TranscriptionResult` (text + rawText + duration +
    /// processingTime + confidence). Throws `TranscriberError.busy`
    /// if a previous call is still running.
    func transcribe(_ samples: [Float]) async throws -> TranscriptionResult

    /// Transcribe a WAV file at `url` (assumed canonical 16 kHz mono
    /// Float32 format). Used by Library's re-transcribe action and
    /// the Wizard's TestStep.
    func transcribeFile(_ url: URL) async throws -> TranscriptionResult

    /// True once the model is loaded on the ANE and ready to infer.
    /// Async-getter form so actor conformers can satisfy from outside
    /// their isolation boundary.
    var isReady: Bool { get async }
}
