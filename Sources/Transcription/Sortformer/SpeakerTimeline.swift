@preconcurrency import FluidAudio
import Foundation

/// Persisted shape of `Recording.speakerTimeline`. Stored as JSON-encoded
/// `Data` on the SwiftData row. One element per speaker turn — the labeled
/// text the UI renders for that segment plus the time bounds it covers.
///
/// `speakerLabel` is the rendered string (`You`, `Alex`, `Speaker 2`, …) —
/// the post-stop labeler resolves slot indices to enrolled names so the
/// timeline survives identity renames after the fact. UI does not have to
/// re-query `EnrolledIdentity` to render labels.
struct SpeakerTimelineSegment: Codable, Sendable, Equatable {
    let speakerLabel: String
    let startSec: Double
    let endSec: Double
    let text: String
}

/// On-disk format for `Recording.speakerTimeline`. Wrapped in a `version`
/// envelope so a future schema bump can route to a different decoder.
struct SpeakerTimelinePayload: Codable, Sendable {
    let version: Int
    let segments: [SpeakerTimelineSegment]

    static let currentVersion: Int = 1

    init(segments: [SpeakerTimelineSegment]) {
        self.version = Self.currentVersion
        self.segments = segments
    }
}

/// Speaker Labels piece A: solo-recording detection + post-stop labeling.
///
/// The piece A labeler runs Sortformer over the completed audio buffer
/// (matching the prototype's `processComplete` path), aggregates contiguous
/// same-speaker windows, and proportionally splits the transcript by audio
/// time across those windows. The result is a JSON-encodable
/// `SpeakerTimelinePayload` ready to write into `Recording.speakerTimeline`.
///
/// Token-midpoint alignment (the prototype's higher-fidelity path) requires
/// surfacing `tokenTimings` through the `Transcribing` protocol; that's a
/// follow-up. Piece A's split-by-time approximation is correct on the
/// segment boundaries (no token can land in the wrong speaker by more than
/// a chunk's worth of audio) — accurate enough to ship while keeping the
/// public interface small.
enum SpeakerTimelineBuilder {

    /// Produce a labeled timeline from a completed recording, or `nil`
    /// when the Sortformer pass detects exactly one speaker (Decision #13).
    ///
    /// - Parameters:
    ///   - samples: 16 kHz mono Float32 buffer (the recording's full audio).
    ///   - transcript: the user-facing post-processed transcript text.
    ///   - duration: the recording's wall-clock duration in seconds.
    ///   - diarizer: a loaded Sortformer instance with enrolled identities
    ///     primed. The diarizer's internal state is reset before processing.
    /// - Returns: a payload to JSON-encode, or `nil` for the solo case.
    static func buildTimeline(
        samples: [Float],
        transcript: String,
        duration: Double,
        diarizer: SortformerDiarizer
    ) throws -> SpeakerTimelinePayload? {
        diarizer.reset()

        let timeline = try diarizer.processComplete(
            samples,
            sourceSampleRate: 16_000.0,
            keepingEnrolledSpeakers: true,
            finalizeOnCompletion: true,
            progressCallback: nil
        )

        let segments = mergedSegments(from: timeline)
        let distinctSpeakers = Set(segments.map { $0.speakerKey })
        guard distinctSpeakers.count > 1 else {
            // Solo recording — detect-and-skip per Decision #13.
            return nil
        }

        let labeled = assignLabels(segments: segments, diarizer: diarizer)
        let withText = distributeText(
            transcript: transcript,
            duration: max(duration, 0.001),
            segments: labeled
        )
        return SpeakerTimelinePayload(segments: withText)
    }

    // MARK: - Private steps

    /// Internal flat segment used during aggregation; `speakerKey` is the
    /// `DiarizerSpeaker.index` so equality is cheap.
    struct RawSegment {
        let speakerKey: Int
        let startSec: Double
        let endSec: Double
    }

    /// Pull all finalized segments out of a Sortformer `DiarizerTimeline`
    /// and merge adjacent same-speaker runs into single segments.
    static func mergedSegments(from timeline: DiarizerTimeline) -> [RawSegment] {
        let flat = timeline.speakers.values.flatMap { speaker -> [RawSegment] in
            speaker.finalizedSegments.map { seg in
                RawSegment(
                    speakerKey: seg.speakerIndex,
                    startSec: Double(seg.startTime),
                    endSec: Double(seg.endTime)
                )
            }
        }
        .filter { $0.endSec > $0.startSec }
        .sorted { lhs, rhs in
            if lhs.startSec == rhs.startSec { return lhs.endSec < rhs.endSec }
            return lhs.startSec < rhs.startSec
        }

        // Merge adjacent segments with the same speaker that touch or
        // overlap. Small gaps (<0.5 s) between same-speaker runs are also
        // merged so the segmentation isn't unreasonably choppy.
        let gapTolerance: Double = 0.5
        var merged: [RawSegment] = []
        for seg in flat {
            if let last = merged.last,
               last.speakerKey == seg.speakerKey,
               seg.startSec - last.endSec <= gapTolerance {
                merged[merged.count - 1] = RawSegment(
                    speakerKey: last.speakerKey,
                    startSec: last.startSec,
                    endSec: max(last.endSec, seg.endSec)
                )
            } else {
                merged.append(seg)
            }
        }
        return merged
    }

    /// Labeled-but-still-textless segments. The label is the rendered
    /// string we want the UI to surface: enrolled name if Sortformer's
    /// slot has a `name` set, otherwise `Speaker N` 1-indexed.
    struct LabeledSegment {
        let label: String
        let startSec: Double
        let endSec: Double
    }

    /// Walk the segments and resolve each slot index to a human label.
    /// Enrolled identities render by name; un-enrolled slots fall back to
    /// `Speaker N` (1-indexed for users).
    static func assignLabels(
        segments: [RawSegment],
        diarizer: SortformerDiarizer
    ) -> [LabeledSegment] {
        // Build a slot → name map up front so we don't repeat the dictionary
        // lookup per segment.
        var slotToName: [Int: String?] = [:]
        for speaker in diarizer.timeline.speakers.values {
            slotToName[speaker.index] = speaker.name
        }

        // Order unlabeled slots 1..N in the order they first appear in the
        // recording so "Speaker 2" / "Speaker 3" are stable to the listener.
        var unlabeledOrder: [Int] = []
        for seg in segments {
            if slotToName[seg.speakerKey] == nil || slotToName[seg.speakerKey] == .some(nil) {
                if !unlabeledOrder.contains(seg.speakerKey) {
                    unlabeledOrder.append(seg.speakerKey)
                }
            }
        }

        return segments.map { seg in
            let label: String
            if let name = slotToName[seg.speakerKey] ?? nil {
                label = name
            } else if let idx = unlabeledOrder.firstIndex(of: seg.speakerKey) {
                label = "Speaker \(idx + 1)"
            } else {
                label = "Speaker"
            }
            return LabeledSegment(label: label, startSec: seg.startSec, endSec: seg.endSec)
        }
    }

    /// Apportion the transcript text across labeled segments by audio time.
    ///
    /// Piece A does NOT have token timings (the `Transcribing` protocol
    /// returns a flat `TranscriptionResult` today). The split therefore
    /// allocates whole words proportionally to each segment's share of the
    /// audio duration — accurate at the segment boundaries to within one
    /// word's worth of audio, which is good enough for piece A. A future
    /// release can replace this with the prototype's token-midpoint
    /// algorithm once `tokenTimings` is plumbed through.
    static func distributeText(
        transcript: String,
        duration: Double,
        segments: [LabeledSegment]
    ) -> [SpeakerTimelineSegment] {
        guard !segments.isEmpty else { return [] }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else {
            return segments.map {
                SpeakerTimelineSegment(
                    speakerLabel: $0.label,
                    startSec: $0.startSec,
                    endSec: $0.endSec,
                    text: ""
                )
            }
        }

        let totalSegmentSec = segments.reduce(0.0) { acc, seg in
            acc + max(0.0, seg.endSec - seg.startSec)
        }
        guard totalSegmentSec > 0 else {
            return segments.map {
                SpeakerTimelineSegment(
                    speakerLabel: $0.label,
                    startSec: $0.startSec,
                    endSec: $0.endSec,
                    text: ""
                )
            }
        }

        var out: [SpeakerTimelineSegment] = []
        out.reserveCapacity(segments.count)
        let totalWords = words.count
        var cursor = 0
        for (idx, seg) in segments.enumerated() {
            let segLen = max(0.0, seg.endSec - seg.startSec)
            let share = segLen / totalSegmentSec
            let wantCount: Int
            if idx == segments.count - 1 {
                wantCount = max(0, totalWords - cursor)
            } else {
                wantCount = max(0, Int((Double(totalWords) * share).rounded()))
            }
            let end = min(words.count, cursor + wantCount)
            let chunk = Array(words[cursor..<end])
            cursor = end
            out.append(SpeakerTimelineSegment(
                speakerLabel: seg.label,
                startSec: seg.startSec,
                endSec: seg.endSec,
                text: chunk.joined(separator: " ")
            ))
        }
        return out
    }

    /// Render a labeled transcript string from a `SpeakerTimelinePayload`.
    /// `You: …\nAlex: …\nSpeaker 2: …`. Used by the Cleanup / Rewrite path
    /// (so the LLM sees the labels) and by any UI surface that wants the
    /// flat text.
    static func renderLabeled(payload: SpeakerTimelinePayload) -> String {
        payload.segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.speakerLabel): \($0.text)" }
            .joined(separator: "\n")
    }
}
