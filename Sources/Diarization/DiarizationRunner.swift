import Foundation
import os.log

/// Shared entry point for the "Detect speakers" pipeline
/// (`docs/speaker-diarization/design.md`) — factored out of
/// `RecordingDetailView.detectSpeakers()` (design `docs/auto-diarize-imports/design.md`)
/// so both the manual detail-view action AND automatic post-import
/// diarization run the exact same steps: `prepareIfNeeded` (downloads the
/// ~22 MB model on first use) → decode the recording's audio to 16 kHz mono
/// Float32 → `process(samples:)` → timeline build.
///
/// Multi-speaker text strategy: when the caller supplies `sliceTranscribe`,
/// each coalesced speaker run's OWN audio slice is transcribed
/// (`SegmentSlicing`) — attribution exact by construction. The pre-existing
/// proportional distribute (+ sentence snapping) remains the fallback for any
/// sliced-path error, and the only strategy when no transcriber is supplied.
enum DiarizationRunner {
    private static let log = Logger(subsystem: "com.jot.Jot", category: "DiarizationRunner")

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

    /// Result of a full pipeline run.
    ///
    /// `payload == nil` means single-speaker (the `DiarizationTimelineBuilder`
    /// dominance gate, design D7) — callers should treat that as "nothing to
    /// label," not an error.
    ///
    /// `slicedTranscript` is non-nil ONLY when the segment-sliced path
    /// produced the payload's text: the runs' texts joined with blank lines
    /// (speaker changes = natural paragraph breaks). The IMPORT path persists
    /// it as the recording's plain transcript so transcript and timeline agree;
    /// `nil` means the payload text came from the proportional fallback (or
    /// there is no payload) and the existing transcript should be kept.
    struct Outcome {
        let payload: SpeakerTimelinePayload?
        let slicedTranscript: String?
    }

    /// Runs the full pipeline for `audioURL` and returns the built `Outcome`.
    /// Throws on a model-load failure, unreadable/empty audio, a `process`
    /// error, or — sliced path only — `TranscriberError.busy` (rethrown so
    /// the ingest can park the diarize pass for the recorder-idle resume hook,
    /// exactly like the transcription-phase salvage path) and cancellation.
    /// Every OTHER sliced-path error falls back to the proportional
    /// distribute — a diarized import never fails because slicing failed.
    ///
    /// Reads the audio off the main actor (`Task.detached`), matching
    /// `detectSpeakers()`'s original inline behavior, since decoding a long
    /// file synchronously would hitch the caller's actor.
    static func run(
        holder: DiarizerHolder,
        audioURL: URL,
        transcript: String,
        sliceTranscribe: SegmentSlicing.SliceTranscribe? = nil
    ) async throws -> Outcome {
        try await holder.prepareIfNeeded()
        let samples = await Task.detached(priority: .userInitiated) {
            (try? DiarizationAudio.readMono16kFloat(url: audioURL)) ?? []
        }.value
        guard !samples.isEmpty else {
            throw RunnerError.emptyAudio
        }
        let result = try await holder.process(samples: samples)
        let duration = Double(samples.count) / 16_000.0

        guard DiarizationTimelineBuilder.multiSpeaker(result),
              let merged = DiarizationTimelineBuilder.coalescedRuns(segments: result.segments)
        else {
            return Outcome(payload: nil, slicedTranscript: nil)
        }

        if let sliceTranscribe {
            do {
                let texts = try await SegmentSlicing.transcribeRuns(
                    runs: merged,
                    samples: samples,
                    transcribe: sliceTranscribe
                )
                let joined = SegmentSlicing.joinedTranscript(texts)
                if !joined.isEmpty {
                    return Outcome(
                        payload: DiarizationTimelineBuilder.slicedPayload(merged: merged, texts: texts),
                        slicedTranscript: joined
                    )
                }
                // Every slice came back empty (all runs short / no speech
                // recognized) — the sliced result would erase the transcript;
                // fall through to the proportional fallback instead.
                log.info("Segment-sliced transcription produced no text — falling back to proportional distribute")
            } catch is CancellationError {
                throw CancellationError()
            } catch TranscriberError.busy {
                // The engine is owned by someone else right now (e.g. a voice
                // capture that started between slices). Don't guess with the
                // fallback — let the caller park/retry or surface it.
                throw TranscriberError.busy
            } catch {
                if Task.isCancelled { throw CancellationError() }
                log.error("Segment-sliced transcription failed — falling back to proportional distribute: \(String(describing: error))")
            }
        }

        return Outcome(
            payload: DiarizationTimelineBuilder.proportionalPayload(
                merged: merged,
                transcript: transcript,
                duration: duration
            ),
            slicedTranscript: nil
        )
    }
}
