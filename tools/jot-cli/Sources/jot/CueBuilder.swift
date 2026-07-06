import Foundation

/// Turns raw model output (transcript text, optional per-word timings, optional
/// diarization segments) into the cue lists `WebVTT` renders. Pure, no I/O.
enum CueBuilder {

    // MARK: - Non-diarized, WITH per-word timings (Parakeet)

    /// Target cue length before we prefer to break at a sentence boundary.
    /// Matches the design doc's "~one cue per sentence / ~5-8s window" (§8/§6).
    static let targetCueSeconds: Double = 6.0
    /// Hard cap — never let a cue run longer than this even mid-sentence.
    static let maxCueSeconds: Double = 8.0

    private static let sentenceEnders: Set<Character> = [".", "!", "?"]

    /// Group reassembled words into VTT cues. Breaks preferentially after
    /// sentence-ending punctuation once a cue has accumulated at least
    /// `targetCueSeconds`; force-breaks at `maxCueSeconds` regardless of
    /// punctuation so no single cue runs away on a long run-on sentence.
    static func cues(fromWords words: [WordReassembly.Word]) -> [(start: Double, end: Double, text: String)] {
        guard !words.isEmpty else { return [] }

        var out: [(start: Double, end: Double, text: String)] = []
        var bucket: [WordReassembly.Word] = []

        func flush() {
            guard let first = bucket.first, let last = bucket.last else { return }
            out.append((first.start, last.end, bucket.map(\.text).joined(separator: " ")))
            bucket.removeAll(keepingCapacity: true)
        }

        for word in words {
            bucket.append(word)
            let span = word.end - (bucket.first?.start ?? word.start)
            let endsSentence = sentenceEnders.contains(word.text.last ?? " ")

            if span >= maxCueSeconds || (span >= targetCueSeconds && endsSentence) {
                flush()
            }
        }
        flush()
        return out
    }

    // MARK: - Diarized

    struct MergedSpeakerSegment {
        let speakerId: String
        let start: Double
        let end: Double
    }

    /// Merge adjacent same-speaker segments within `gapTolerance` seconds of
    /// each other. Mirrors the app's `DiarizationTimelineBuilder.mergeAdjacent`
    /// (minus the owner-ID / phantom-folding policy layered on top there —
    /// out of scope for a headless CLI with no "owner" concept; see the CLI
    /// design doc §8 R6 and the task's requested deviation list).
    static func mergeAdjacent(
        _ segments: [(speakerId: String, start: Double, end: Double)],
        gapTolerance: Double = 0.5
    ) -> [MergedSpeakerSegment] {
        let sorted = segments.sorted { $0.start < $1.start }
        var merged: [MergedSpeakerSegment] = []
        for seg in sorted {
            guard seg.end > seg.start else { continue }
            if let last = merged.last, last.speakerId == seg.speakerId, seg.start - last.end <= gapTolerance {
                merged[merged.count - 1] = MergedSpeakerSegment(
                    speakerId: last.speakerId, start: last.start, end: max(last.end, seg.end))
            } else {
                merged.append(MergedSpeakerSegment(speakerId: seg.speakerId, start: seg.start, end: seg.end))
            }
        }
        return merged
    }

    /// "Speaker 1" / "Speaker 2" / … assigned by first-appearance order —
    /// the CLI has no owner-voiceprint concept, so every speaker is anonymous
    /// (unlike the in-app `DiarizationTimelineBuilder.resolveLabels`, which
    /// can label one speaker as the recording's owner).
    static func labels(for segments: [MergedSpeakerSegment]) -> [String: String] {
        var labels: [String: String] = [:]
        var next = 1
        for seg in segments where labels[seg.speakerId] == nil {
            labels[seg.speakerId] = "Speaker \(next)"
            next += 1
        }
        return labels
    }

    /// Best case: Parakeet's per-word timings are available. Assign each
    /// word to the merged segment whose time range contains its start time
    /// (falling back to the nearest segment by boundary distance for a word
    /// that lands in a gap between segments), then join per-segment.
    /// This is a materially more accurate alignment than the app's current
    /// time-proportional fallback (`SpeakerTimelineBuilder.distributeText`)
    /// since it uses real per-word timestamps instead of guessing from
    /// audio-time share — possible precisely because the CLI always runs
    /// ASR before diarization (serialized, never concurrent).
    static func diarizedSegments(
        words: [WordReassembly.Word],
        segments: [MergedSpeakerSegment],
        labels: [String: String]
    ) -> [(speaker: String, start: Double, end: Double, text: String)] {
        guard !segments.isEmpty else { return [] }
        var buckets: [[String]] = Array(repeating: [], count: segments.count)

        for word in words {
            let mid = (word.start + word.end) / 2
            if let idx = segments.firstIndex(where: { mid >= $0.start && mid < $0.end }) {
                buckets[idx].append(word.text)
                continue
            }
            // Gap word — attach to whichever segment boundary is nearest.
            var bestIdx = 0
            var bestDist = Double.greatestFiniteMagnitude
            for (idx, seg) in segments.enumerated() {
                let dist = mid < seg.start ? seg.start - mid : mid - seg.end
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = idx
                }
            }
            buckets[bestIdx].append(word.text)
        }

        return segments.enumerated().map { idx, seg in
            (
                speaker: labels[seg.speakerId] ?? seg.speakerId,
                start: seg.start,
                end: seg.end,
                text: buckets[idx].joined(separator: " ")
            )
        }
    }

    /// Fallback when there are no per-word timings (Nemotron): apportion the
    /// transcript across segments proportionally to each segment's share of
    /// total speech time. Ported from the app's
    /// `SpeakerTimelineBuilder.distributeText`.
    static func distributeText(
        transcript: String,
        segments: [MergedSpeakerSegment],
        labels: [String: String]
    ) -> [(speaker: String, start: Double, end: Double, text: String)] {
        guard !segments.isEmpty else { return [] }
        let words = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else {
            return segments.map { (labels[$0.speakerId] ?? $0.speakerId, $0.start, $0.end, "") }
        }

        let totalSegSec = segments.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        guard totalSegSec > 0 else {
            return segments.map { (labels[$0.speakerId] ?? $0.speakerId, $0.start, $0.end, "") }
        }

        var out: [(speaker: String, start: Double, end: Double, text: String)] = []
        var cursor = 0
        for (idx, seg) in segments.enumerated() {
            let share = max(0, seg.end - seg.start) / totalSegSec
            let wantCount = idx == segments.count - 1
                ? max(0, words.count - cursor)
                : max(0, Int((Double(words.count) * share).rounded()))
            let end = min(words.count, cursor + wantCount)
            let chunk = Array(words[cursor..<end])
            cursor = end
            out.append((labels[seg.speakerId] ?? seg.speakerId, seg.start, seg.end, chunk.joined(separator: " ")))
        }
        return out
    }
}
