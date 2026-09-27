import Foundation

/// Shared streaming interface for the Nemotron engines — English
/// (`NemotronStreamingTranscriber`) and multilingual
/// (`NemotronMultilingualStreamingTranscriber`). Both are actors with
/// identical streaming control flow (ensure-load → start → enqueue → finish,
/// plus a one-shot path), so `DualPipelineTranscriber` holds either behind
/// this protocol and keeps a single set of engine switch arms instead of
/// duplicating each one per concrete type.
protocol NemotronStreamingEngine: Sendable {
    var isReady: Bool { get async }
    func ensureLoaded() async throws
    func start(generation: UInt64, onPartial: @escaping @Sendable (String, UInt64) -> Void) async
    nonisolated func enqueue(samples: [Float])
    func finish() async throws -> NemotronStreamedFinal
    func transcribeOneShot(_ samples: [Float]) async throws -> String
    /// The one-shot decode plus the decoder's per-token timings (the vocabulary
    /// gate places spotter detections on words by them — R10).
    func transcribeOneShotWithTimings(_ samples: [Float]) async throws -> NemotronDecode
    /// No-op unless `generation` is the session this engine is running, so
    /// a late cleanup for an abandoned session can never end a newer one.
    func cancel(generation: UInt64) async
}

/// What a live streaming session decoded, returned by `finish()`. The caller
/// uses `text` as the final transcript only when `decodedSampleCount` matches
/// the recording it is finalizing — proof the stream covered every sample.
struct NemotronStreamedFinal: Sendable {
    let text: String
    let generation: UInt64
    let decodedSampleCount: Int
    /// The decoder's per-token timings for `text` (FluidAudio
    /// `finishWithTokenTimings`). Only their times are meaningful — Nemotron's
    /// token confidence is a constant 1.0 and is never passed to the gate.
    var tokenTimings: [EngineTokenTiming] = []
}

/// A one-shot Nemotron decode: the text and its per-token timings.
struct NemotronDecode: Sendable {
    let text: String
    let tokenTimings: [EngineTokenTiming]
}

/// Why a live session could not supply the final transcript. The caller
/// logs the reason and falls back to a one-shot decode of the recording.
enum NemotronStreamingFailure: Error {
    case noSession
    case loadFailed
    case processFailed
    case cancelled
}
