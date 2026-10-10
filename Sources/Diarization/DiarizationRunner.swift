import Foundation
import os.log

/// Shared entry point for the "Detect speakers" pipeline
/// (`docs/speaker-diarization/design.md`) — factored out of
/// `RecordingDetailView.detectSpeakers()` (design `docs/auto-diarize-imports/design.md`)
/// so both the manual detail-view action AND automatic post-import
/// diarization run the exact same steps: `prepareIfNeeded` (downloads the
/// ~190 MB Nemotron 3 model on first use) → decode the recording's audio to
/// 16 kHz mono Float32 → `process(samples:)` → timeline build.
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

    /// Live progress for the "Detecting speakers" captions. Up to two timed
    /// steps: finding speakers (the diarizer over the whole file), then — on
    /// the segment-sliced path with more than one voice — matching words to
    /// speakers (re-transcribing each speaker run). Both fractions are audio
    /// processed, so they are real, not guessed.
    struct Progress: Sendable, Equatable {
        enum Phase: Sendable, Equatable {
            /// Loading (or first-use downloading) the model and decoding audio.
            case preparing
            case findingSpeakers
            case matchingWords
        }
        let phase: Phase
        /// 1-based step and the number of timed steps this run can have.
        let step: Int
        let stepCount: Int
        /// `nil` while preparing (no honest fraction).
        let fraction: Double?
        /// Seconds left in this step, measured from this run's own speed;
        /// `nil` until enough of the step has run to estimate it.
        let remaining: TimeInterval?
    }

    typealias ProgressHandler = @Sendable (Progress) -> Void

    /// Time left in a step, extrapolated from elapsed time and fraction done.
    /// Waits for 5% and 1.5 s so the first block's warm-up doesn't produce a
    /// wild number.
    private struct StepClock {
        let start = Date()
        var elapsed: TimeInterval { Date().timeIntervalSince(start) }
        func remaining(at fraction: Double) -> TimeInterval? {
            let e = elapsed
            guard fraction >= 0.05, fraction < 1, e >= 1.5 else { return fraction >= 1 ? 0 : nil }
            return e * (1 - fraction) / fraction
        }
    }

    /// Result of a full pipeline run.
    ///
    /// `payload == nil` means single-speaker (the `DiarizationProjection`
    /// solo gate, or folding left one voice) — callers should treat that as "nothing to
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
        sliceTranscribe: SegmentSlicing.SliceTranscribe? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws -> Outcome {
        let stepCount = sliceTranscribe == nil ? 1 : 2
        onProgress?(Progress(phase: .preparing, step: 1, stepCount: stepCount, fraction: nil, remaining: nil))
        let prepareClock = StepClock()
        try await holder.prepareIfNeeded()
        let samples = await Task.detached(priority: .userInitiated) {
            (try? DiarizationAudio.readMono16kFloat(url: audioURL)) ?? []
        }.value
        guard !samples.isEmpty else {
            throw RunnerError.emptyAudio
        }
        let duration = Double(samples.count) / 16_000.0
        let prepareSeconds = prepareClock.elapsed

        let findClock = StepClock()
        onProgress?(Progress(phase: .findingSpeakers, step: 1, stepCount: stepCount, fraction: 0, remaining: nil))
        let segments = try await holder.process(samples: samples) { fraction in
            onProgress?(Progress(phase: .findingSpeakers, step: 1, stepCount: stepCount,
                                 fraction: fraction, remaining: findClock.remaining(at: fraction)))
        }
        let findSeconds = findClock.elapsed
        log.notice("Speaker detection timing: \(Self.clock(duration), privacy: .public) of audio — prepare+decode \(Self.secs(prepareSeconds), privacy: .public), finding speakers \(Self.secs(findSeconds), privacy: .public) (\(Self.speed(duration, findSeconds), privacy: .public))")

        guard let merged = DiarizationTimelineBuilder.coalescedRuns(segments: segments, duration: duration) else {
            return Outcome(payload: nil, slicedTranscript: nil)
        }

        if let sliceTranscribe {
            do {
                let matchClock = StepClock()
                onProgress?(Progress(phase: .matchingWords, step: 2, stepCount: stepCount, fraction: 0, remaining: nil))
                let texts = try await SegmentSlicing.transcribeRuns(
                    runs: merged,
                    samples: samples,
                    transcribe: sliceTranscribe
                ) { fraction in
                    onProgress?(Progress(phase: .matchingWords, step: 2, stepCount: stepCount,
                                         fraction: fraction, remaining: matchClock.remaining(at: fraction)))
                }
                log.notice("Speaker detection timing: matching words to \(merged.count, privacy: .public) speaker turns \(Self.secs(matchClock.elapsed), privacy: .public) (\(Self.speed(duration, matchClock.elapsed), privacy: .public))")
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

    private static func secs(_ t: TimeInterval) -> String { String(format: "%.1fs", t) }
    private static func clock(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    private static func speed(_ audio: TimeInterval, _ wall: TimeInterval) -> String {
        wall > 0 ? String(format: "%.0f× real time", audio / wall) : "—"
    }
}

extension DiarizationRunner.Progress {
    /// One line for the "Detecting speakers" captions, e.g.
    /// "Finding speakers (1 of 2)… 40% · ~0:12 left".
    var summary: String {
        let name: String
        switch phase {
        case .preparing: return "Getting ready…"
        case .findingSpeakers: name = "Finding speakers"
        case .matchingWords: name = "Matching words to speakers"
        }
        var text = name + (stepCount > 1 ? " (\(step) of \(stepCount))…" : "…")
        if let fraction {
            text += " \(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
        }
        if let remaining {
            if remaining < 1 {
                text += " · almost done"
            } else {
                let total = Int(remaining.rounded())
                text += " · ~" + String(format: "%d:%02d", total / 60, total % 60) + " left"
            }
        }
        return text
    }
}
