import Foundation

/// Turns the diarizer's exclusive speech runs (`[DiarSegment]`, from
/// `DiarizerHolder.process`) into the persisted `SpeakerTimelinePayload`.
/// The run geometry — solo gate, phantom fold, merge/coalesce, gap fill,
/// short-run fold — lives in `DiarizationProjection` (shared verbatim with
/// the `jot` CLI); this type owns what only the app does with those runs:
/// anonymous-speaker labeling and text distribution (Phase 0's
/// `SpeakerTimelineBuilder.distributeText`, or per-run slice text).
enum DiarizationTimelineBuilder {

    // MARK: - Anonymous speaker labeling

    /// Resolve a rendered "Speaker N" label for every distinct `speakerId`,
    /// numbered in `orderedSpeakerIds` order. Owner auto-ID (matching a
    /// voice against a stored "device owner" centroid) was removed — the
    /// threshold lived in an uncalibrated metric space and never reliably
    /// fired, so every speaker is anonymous by default. Callers can still
    /// manually rename a speaker per-recording (`RecordingDetailView`).
    ///
    /// `orderedSpeakerIds` is caller-supplied in first-appearance order
    /// (see `buildPayload`), which is what makes the numbering stable
    /// across repeated "Detect speakers" runs on the same recording.
    static func resolveLabels(orderedSpeakerIds: [String]) -> [String: String] {
        var labels: [String: String] = [:]
        for (index, id) in orderedSpeakerIds.enumerated() {
            labels[id] = "Speaker \(index + 1)"
        }
        return labels
    }

    // MARK: - Payload build

    /// End-to-end on the proportional text strategy: diarizer runs →
    /// `SpeakerTimelinePayload`, or `nil` for the single-speaker case (the
    /// solo gate, or folding collapsed to one voice) — the caller should
    /// clear any existing `speakerTimeline` and show "Single speaker".
    static func buildPayloadCore(
        segments: [DiarSegment],
        transcript: String,
        duration: Double
    ) -> SpeakerTimelinePayload? {
        guard let merged = coalescedRuns(segments: segments, duration: duration) else { return nil }
        return proportionalPayload(merged: merged, transcript: transcript, duration: duration)
    }

    /// The geometry half of the pipeline (`DiarizationProjection.speakerRuns`)
    /// on the tuple shape the text strategies take. Split out of
    /// `buildPayloadCore` so the segment-sliced import path
    /// (`DiarizationRunner`) can obtain the runs BEFORE deciding how their
    /// text is produced. The runs are gap-free over `[0, duration]` and none
    /// is shorter than `SegmentSlicing.minRunSeconds`, so slicing them loses
    /// no audio (design A1). `nil` = single speaker.
    static func coalescedRuns(
        segments: [DiarSegment],
        duration: Double
    ) -> [(speakerId: String, start: Double, end: Double)]? {
        DiarizationProjection.speakerRuns(from: segments, duration: duration)?
            .map { ($0.speakerId, $0.start, $0.end) }
    }

    /// Rendered-label segments for the coalesced runs — first-appearance
    /// order drives stable "Speaker 1 / 2 / 3 / …" numbering (see
    /// `resolveLabels`).
    static func labeledSegments(
        for merged: [(speakerId: String, start: Double, end: Double)]
    ) -> [SpeakerTimelineBuilder.LabeledSegment] {
        var orderedSpeakerIds: [String] = []
        for seg in merged where !orderedSpeakerIds.contains(seg.speakerId) {
            orderedSpeakerIds.append(seg.speakerId)
        }
        let labels = resolveLabels(orderedSpeakerIds: orderedSpeakerIds)
        return merged.map {
            SpeakerTimelineBuilder.LabeledSegment(
                label: labels[$0.speakerId] ?? $0.speakerId,
                startSec: $0.start,
                endSec: $0.end
            )
        }
    }

    /// The pre-existing text strategy: apportion the whole-file transcript
    /// across the runs proportionally-by-time with sentence snapping
    /// (`SpeakerTimelineBuilder.distributeText`). Stays as the fallback for
    /// any error on the segment-sliced path, and the only strategy when no
    /// slice transcriber is available.
    static func proportionalPayload(
        merged: [(speakerId: String, start: Double, end: Double)],
        transcript: String,
        duration: Double
    ) -> SpeakerTimelinePayload {
        let segments = SpeakerTimelineBuilder.distributeText(
            transcript: transcript,
            duration: max(duration, 0.001),
            segments: labeledSegments(for: merged)
        )
        return SpeakerTimelinePayload(segments: segments)
    }

    /// The segment-sliced text strategy: each run carries the transcript of
    /// its OWN audio slice (`texts` is index-aligned with `merged`, `""` for
    /// runs below `SegmentSlicing.minRunSeconds`). Attribution is exact by
    /// construction — no distribution, no snapping.
    static func slicedPayload(
        merged: [(speakerId: String, start: Double, end: Double)],
        texts: [String]
    ) -> SpeakerTimelinePayload {
        let labeled = labeledSegments(for: merged)
        let segments = zip(labeled, texts).map { seg, text in
            SpeakerTimelineSegment(
                speakerLabel: seg.label,
                startSec: seg.startSec,
                endSec: seg.endSec,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return SpeakerTimelinePayload(segments: segments)
    }
}
