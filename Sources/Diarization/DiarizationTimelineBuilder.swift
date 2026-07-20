import FluidAudio
import Foundation

/// Turns a raw `DiarizationResult` (offline VBx) into the persisted
/// `SpeakerTimelinePayload` — the solo-skip gate (D7), isolated-segment
/// smoothing (cluster noise), phantom-speaker folding, same-speaker run
/// coalescing, anonymous-speaker labeling, and text distribution (Phase 0's
/// `SpeakerTimelineBuilder.distributeText`) all live here.
enum DiarizationTimelineBuilder {

    // MARK: - D7: dominance-threshold solo-skip

    /// Absolute floor only — NOT a fraction of total duration. An earlier
    /// version also gated on `minSecondaryFraction` (5% of total), which
    /// folded away a legitimate short second speaker in a long recording
    /// (e.g. a real 20-30s speaker after 6+ minutes of a dominant voice is
    /// >5% of total but was still being treated as noise). The phantom
    /// clusters this gate exists to reject top out around 2.8s in practice
    /// (design's worst-case control), so a flat ~6s floor rejects phantoms
    /// while keeping real short-but-genuine second speakers, regardless of
    /// how long the recording is.
    static let minSecondarySeconds: Double = 6.0

    /// Per-speaker total speech seconds across all segments.
    static func perSpeakerSeconds(_ segments: [TimedSpeakerSegment]) -> [String: Double] {
        var totals: [String: Double] = [:]
        for seg in segments {
            totals[seg.speakerId, default: 0] += Double(seg.durationSeconds)
        }
        return totals
    }

    /// Whether `result` should be treated as genuinely multi-speaker.
    /// Gates on the LARGEST SINGLE secondary speaker, not the sum of all
    /// secondaries (design S3: summing lets several small phantom clusters
    /// trip the gate even though no real second voice exists).
    static func multiSpeaker(_ result: DiarizationResult) -> Bool {
        let totals = perSpeakerSeconds(result.segments)
        guard totals.count > 1 else { return false }
        let sortedDesc = totals.values.sorted(by: >)
        let largestSecondary = sortedDesc.count > 1 ? sortedDesc[1] : 0
        return largestSecondary >= minSecondarySeconds
    }

    // MARK: - Isolated-segment smoothing (cluster noise)

    /// A raw segment this short, sitting BETWEEN two segments that agree on a
    /// different speaker, is treated as cluster noise (the observed phantom
    /// pattern is isolated 2-4s flips inside one narrator's run).
    static let maxIsolatedSeconds: Double = 4.0

    /// One-pass cluster-noise smoothing, run BEFORE `foldPhantomSpeakers` so
    /// a speaker that smoothing empties below the 6s floor is folded by the
    /// existing phantom pass — no second fold call needed. A segment is
    /// reassigned to its neighbors' speaker iff:
    ///  - it is short (≤ `maxIsolatedSeconds`), and
    ///  - both temporal neighbors AGREE on a different speaker, and
    ///  - both neighbors are themselves LONGER than `maxIsolatedSeconds`
    ///    (a flip "isolated inside one narrator's run" implies long
    ///    neighbors; without this, uniform-score all-short genuine
    ///    alternation like A/B/A/B would have its middle turns SWAP
    ///    speakers — each middle segment sees agreeing original neighbors),
    ///    and
    ///  - its `qualityScore` is at-or-below the run's median (when all
    ///    scores are equal — e.g. an engine that doesn't populate them —
    ///    the quality gate is vacuously true, by design).
    /// Decisions read the ORIGINAL neighbor labels (no cascade): a run of
    /// two+ short segments of the same speaker is NOT smoothed away, so
    /// legitimately alternating dialogue survives.
    static func smoothIsolatedSegments(_ segments: [TimedSpeakerSegment]) -> [TimedSpeakerSegment] {
        guard segments.count >= 3 else { return segments }
        let sorted = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }

        let qualities = sorted.map(\.qualityScore).sorted()
        let mid = qualities.count / 2
        let medianQuality: Float = qualities.count % 2 == 1
            ? qualities[mid]
            : (qualities[mid - 1] + qualities[mid]) / 2

        var out = sorted
        for i in 1..<(sorted.count - 1) {
            let seg = sorted[i]
            let prev = sorted[i - 1]
            let next = sorted[i + 1]
            guard Double(seg.durationSeconds) <= maxIsolatedSeconds,
                  Double(prev.durationSeconds) > maxIsolatedSeconds,
                  Double(next.durationSeconds) > maxIsolatedSeconds,
                  prev.speakerId == next.speakerId,
                  prev.speakerId != seg.speakerId,
                  seg.qualityScore <= medianQuality
            else { continue }
            out[i] = TimedSpeakerSegment(
                speakerId: prev.speakerId,
                embedding: seg.embedding,
                startTimeSeconds: seg.startTimeSeconds,
                endTimeSeconds: seg.endTimeSeconds,
                qualityScore: seg.qualityScore
            )
        }
        return out
    }

    // MARK: - Phantom folding + merge

    /// Fold any speaker whose total speech falls below the D7 threshold
    /// into whichever "real" (above-threshold) speaker is temporally
    /// adjacent, so the phantom's words aren't dropped from the transcript.
    /// If NO speaker clears the threshold (shouldn't happen once
    /// `multiSpeaker` has already gated true, but defensive), the single
    /// largest speaker is kept as the fallback "real" one.
    static func foldPhantomSpeakers(_ segments: [TimedSpeakerSegment]) -> [TimedSpeakerSegment] {
        guard !segments.isEmpty else { return [] }
        let totals = perSpeakerSeconds(segments)
        var realSpeakers = Set(totals.filter { $0.value >= minSecondarySeconds }.keys)
        if realSpeakers.isEmpty, let top = totals.max(by: { $0.value < $1.value }) {
            realSpeakers = [top.key]
        }

        let sorted = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var result: [TimedSpeakerSegment] = []
        result.reserveCapacity(sorted.count)

        for (idx, seg) in sorted.enumerated() {
            if realSpeakers.contains(seg.speakerId) {
                result.append(seg)
                continue
            }
            let prevReal = result.last(where: { realSpeakers.contains($0.speakerId) })
            let nextReal = sorted[(idx + 1)...].first(where: { realSpeakers.contains($0.speakerId) })
            let foldInto: String
            switch (prevReal, nextReal) {
            case let (.some(prev), .some(next)):
                let distPrev = seg.startTimeSeconds - prev.endTimeSeconds
                let distNext = next.startTimeSeconds - seg.endTimeSeconds
                foldInto = distPrev <= distNext ? prev.speakerId : next.speakerId
            case let (.some(prev), .none):
                foldInto = prev.speakerId
            case let (.none, .some(next)):
                foldInto = next.speakerId
            case (.none, .none):
                foldInto = seg.speakerId
            }
            result.append(TimedSpeakerSegment(
                speakerId: foldInto,
                embedding: seg.embedding,
                startTimeSeconds: seg.startTimeSeconds,
                endTimeSeconds: seg.endTimeSeconds,
                qualityScore: seg.qualityScore
            ))
        }
        return result
    }

    /// Merge adjacent same-speaker segments (post phantom-fold) — matches
    /// the merge-tolerance the Sortformer-era builder used, kept here since
    /// exclusive VBx segments can still leave short same-speaker gaps.
    static func mergeAdjacent(_ segments: [TimedSpeakerSegment], gapTolerance: Double = 0.5) -> [(speakerId: String, start: Double, end: Double)] {
        let sorted = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var merged: [(speakerId: String, start: Double, end: Double)] = []
        for seg in sorted {
            let start = Double(seg.startTimeSeconds)
            let end = Double(seg.endTimeSeconds)
            guard end > start else { continue }
            if let last = merged.last, last.speakerId == seg.speakerId, start - last.end <= gapTolerance {
                merged[merged.count - 1] = (seg.speakerId, last.start, max(last.end, end))
            } else {
                merged.append((seg.speakerId, start, end))
            }
        }
        return merged
    }

    /// Collapse consecutive same-speaker runs into ONE segment REGARDLESS of
    /// gap size (post `mergeAdjacent`). The gap between two same-speaker
    /// segments belongs to no other speaker — it's silence/music — so the
    /// display timeline treats the whole run as one turn. This is what turns
    /// a narrator fragmented into dozens of pause-separated segments into a
    /// single block. The persisted payload IS this coalesced shape (single
    /// payload, no parallel fine-grained copy); the WebVTT export therefore
    /// gets longer cues for new recordings — an accepted trade-off.
    static func coalesceSameSpeakerRuns(
        _ segments: [(speakerId: String, start: Double, end: Double)]
    ) -> [(speakerId: String, start: Double, end: Double)] {
        var out: [(speakerId: String, start: Double, end: Double)] = []
        out.reserveCapacity(segments.count)
        for seg in segments {
            if let last = out.last, last.speakerId == seg.speakerId {
                out[out.count - 1] = (seg.speakerId, last.start, max(last.end, seg.end))
            } else {
                out.append(seg)
            }
        }
        return out
    }

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

    /// End-to-end: raw `DiarizationResult` → `SpeakerTimelinePayload`, or
    /// `nil` for the solo-recording case (design D7) — caller should clear
    /// any existing `speakerTimeline` and show a "Single speaker" state.
    static func buildPayload(
        result: DiarizationResult,
        transcript: String,
        duration: Double
    ) async throws -> SpeakerTimelinePayload? {
        guard multiSpeaker(result) else { return nil }
        return buildPayloadCore(
            segments: result.segments,
            transcript: transcript,
            duration: duration
        )
    }

    /// Pure synchronous core of `buildPayload`, post the `multiSpeaker`
    /// gate. Split out so the DEBUG harness can exercise the full pipeline
    /// without constructing a `DiarizationResult` or awaiting.
    static func buildPayloadCore(
        segments rawSegments: [TimedSpeakerSegment],
        transcript: String,
        duration: Double
    ) -> SpeakerTimelinePayload? {
        guard let merged = coalescedRuns(segments: rawSegments) else { return nil }
        return proportionalPayload(merged: merged, transcript: transcript, duration: duration)
    }

    /// The geometry half of the pipeline: smoothing → phantom fold →
    /// adjacent-merge → run coalescing, plus the post-collapse single-speaker
    /// gate. Split out of `buildPayloadCore` so the segment-sliced import
    /// path (`DiarizationRunner`) can obtain the coalesced runs BEFORE
    /// deciding how their text is produced (per-run slice transcription vs.
    /// the proportional distribute fallback below).
    ///
    /// Order matters: smoothing runs BEFORE the phantom fold so a speaker
    /// that smoothing empties below the 6s floor is folded away by the same
    /// pass; run coalescing runs last, on the merged spans.
    static func coalescedRuns(
        segments rawSegments: [TimedSpeakerSegment]
    ) -> [(speakerId: String, start: Double, end: Double)]? {
        let smoothed = smoothIsolatedSegments(rawSegments)
        let folded = foldPhantomSpeakers(smoothed)
        let merged = coalesceSameSpeakerRuns(mergeAdjacent(folded))
        guard !merged.isEmpty else { return nil }

        // Smoothing + folding can collapse a gate-passing result down to a
        // single speaker (e.g. a "secondary" made entirely of isolated
        // low-quality flips). A one-label payload would render a lone
        // "Speaker 1" header and toast "Labeled 1 speakers." — return nil so
        // the caller takes the designed "Single speaker" path instead.
        guard Set(merged.map(\.speakerId)).count > 1 else { return nil }
        return merged
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
