import Foundation

/// Shared entry point for the "Detect speakers" pipeline
/// (`docs/speaker-diarization/design.md`) — factored out of
/// `RecordingDetailView.detectSpeakers()` (design `docs/auto-diarize-imports/design.md`)
/// so both the manual detail-view action AND automatic post-import
/// diarization run the exact same steps: `prepareIfNeeded` (downloads the
/// ~22 MB model on first use) → decode the recording's audio to 16 kHz mono
/// Float32 → `process(samples:)` → `DiarizationTimelineBuilder.buildPayload`.
enum DiarizationRunner {
    /// Mirrors the inline "couldn't read this recording's audio" failure
    /// `detectSpeakers()` used to surface directly — kept as a distinct,
    /// localized error so callers get the identical message via
    /// `error.localizedDescription`.
    enum RunnerError: Error, LocalizedError {
        case emptyAudio

        var errorDescription: String? {
            switch self {
            case .emptyAudio:
                return "Couldn't read this recording's audio."
            }
        }
    }

    /// Runs the full pipeline for `audioURL` and returns the built
    /// `SpeakerTimelinePayload`, or `nil` when the recording is single-speaker
    /// (the `DiarizationTimelineBuilder` dominance gate, design D7) — callers
    /// should treat `nil` as "nothing to label," not an error. Throws on a
    /// model-load failure, unreadable/empty audio, or a `process` error.
    ///
    /// Reads the audio off the main actor (`Task.detached`), matching
    /// `detectSpeakers()`'s original inline behavior, since decoding a long
    /// file synchronously would hitch the caller's actor.
    static func run(
        holder: DiarizerHolder,
        audioURL: URL,
        transcript: String
    ) async throws -> SpeakerTimelinePayload? {
        try await holder.prepareIfNeeded()
        let samples = await Task.detached(priority: .userInitiated) {
            (try? DiarizationAudio.readMono16kFloat(url: audioURL)) ?? []
        }.value
        guard !samples.isEmpty else {
            throw RunnerError.emptyAudio
        }
        let result = try await holder.process(samples: samples)
        return try await DiarizationTimelineBuilder.buildPayload(
            result: result,
            transcript: transcript,
            duration: Double(samples.count) / 16_000.0
        )
    }
}
