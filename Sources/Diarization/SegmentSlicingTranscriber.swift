import Foundation

extension SegmentSlicing {
    /// The production `SliceTranscribe` over the ACTIVE transcriber — the
    /// same engine instance the import itself used, via the existing
    /// samples-path entry points (no new engine APIs):
    ///
    /// - `DualPipelineTranscriber` routes through
    ///   `transcribeDetachedSamples` — file-import semantics for a samples
    ///   buffer (`consumeStreamedPayload: false`, so a pending recorder-
    ///   session CTC vocab payload is never consumed by a slice), same
    ///   scrub + language-aware cleanup chain as the whole-file import.
    /// - Plain `Transcriber` (batch models) uses the protocol samples call,
    ///   which runs the identical cleanup `transcribeFile` runs (that method
    ///   is just decode + the same `transcribe(samples)`).
    ///
    /// Vocabulary gating runs PER SLICE with that slice's samples — it is
    /// built into both reused entry points (batch: internal rescorer;
    /// Nemotron: one-shot CTC spot + gate over the slice audio), so the
    /// sliced path gets it for free rather than forking the chain.
    ///
    /// `ensureLoaded()` is called per slice — idempotent and cheap once
    /// loaded; it matters only for the detail-view "Detect speakers" path on
    /// a cold launch, where the model may not be loaded yet.
    static func sliceTranscriber(using transcriber: any Transcribing) -> SliceTranscribe {
        { samples in
            try await transcriber.ensureLoaded()
            if let dual = transcriber as? DualPipelineTranscriber {
                return try await dual.transcribeDetachedSamples(samples).text
            }
            return try await transcriber.transcribe(samples, recordsProvenance: false).text
        }
    }
}
