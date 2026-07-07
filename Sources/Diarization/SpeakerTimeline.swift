import Foundation

/// Persisted shape of `Recording.speakerTimeline`. Stored as JSON-encoded
/// `Data` on the SwiftData row. One element per speaker turn — the labeled
/// text the UI renders for that segment plus the time bounds it covers.
///
/// `speakerLabel` is the rendered string (`Speaker 1`, `Speaker 2`, …, or a
/// user-chosen rename) resolved by
/// `DiarizationTimelineBuilder` at "Detect speakers" time. A per-recording
/// rename (design D5) rewrites every segment carrying the old label string —
/// there is no global identity store to reconcile.
///
/// Engine-agnostic: this schema, and the pure functions below, survived the
/// Sortformer → offline VBx engine swap (`docs/speaker-diarization/design.md`)
/// untouched. They know nothing about which diarizer produced the segments.
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

/// Pure, engine-agnostic helpers shared by whichever diarizer builds the
/// timeline. `DiarizationTimelineBuilder` (offline VBx, `Sources/Diarization/
/// DiarizationTimelineBuilder.swift`) is the only caller today; these
/// functions take plain `(label, start, end)` triples and a transcript
/// string, so they have no engine coupling at all.
enum SpeakerTimelineBuilder {

    /// Labeled-but-still-textless segment. The label is the rendered string
    /// the UI should show for this turn — already resolved (owner name /
    /// `Speaker N`) by the caller.
    struct LabeledSegment {
        let label: String
        let startSec: Double
        let endSec: Double
    }

    /// Apportion the transcript text across labeled segments by audio time.
    ///
    /// No token timings are consulted here — the split allocates whole words
    /// proportionally to each segment's share of the audio duration —
    /// accurate at the segment boundaries to within one word's worth of
    /// audio, which the design accepts as "correct enough to ship" (see
    /// `docs/speaker-diarization/design.md` § Token→speaker alignment).
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
    /// `User: …\nSpeaker 2: …`. Used by the Cleanup / Rewrite path (so the
    /// LLM sees the labels, via `SpeakerLabelDetector.looksLabeled`) and by
    /// any UI surface that wants the flat text.
    static func renderLabeled(payload: SpeakerTimelinePayload) -> String {
        payload.segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.speakerLabel): \($0.text)" }
            .joined(separator: "\n")
    }
}
