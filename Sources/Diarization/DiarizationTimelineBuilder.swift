import FluidAudio
import Foundation

/// Turns a raw `DiarizationResult` (offline VBx) into the persisted
/// `SpeakerTimelinePayload` — the solo-skip gate (D7), phantom-speaker
/// folding, anonymous-speaker labeling, and text distribution (Phase 0's
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

        let folded = foldPhantomSpeakers(result.segments)
        let merged = mergeAdjacent(folded)
        guard !merged.isEmpty else { return nil }

        // First-appearance order drives stable "Speaker 1 / 2 / 3 / …"
        // numbering (see `resolveLabels`).
        var orderedSpeakerIds: [String] = []
        for seg in merged where !orderedSpeakerIds.contains(seg.speakerId) {
            orderedSpeakerIds.append(seg.speakerId)
        }

        let labels = resolveLabels(orderedSpeakerIds: orderedSpeakerIds)

        let labeledSegments = merged.map {
            SpeakerTimelineBuilder.LabeledSegment(
                label: labels[$0.speakerId] ?? $0.speakerId,
                startSec: $0.start,
                endSec: $0.end
            )
        }

        let segments = SpeakerTimelineBuilder.distributeText(
            transcript: transcript,
            duration: max(duration, 0.001),
            segments: labeledSegments
        )
        return SpeakerTimelinePayload(segments: segments)
    }
}
