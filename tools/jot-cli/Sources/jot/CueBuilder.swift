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

    /// "Speaker 1" / "Speaker 2" / … assigned by first-appearance order —
    /// every speaker is anonymous, same as the app's
    /// `DiarizationTimelineBuilder.resolveLabels`.
    static func labels(for runs: [DiarSegment]) -> [String: String] {
        var labels: [String: String] = [:]
        var next = 1
        for run in runs where labels[run.speakerId] == nil {
            labels[run.speakerId] = "Speaker \(next)"
            next += 1
        }
        return labels
    }

    /// Best case: Parakeet's per-word timings are available. Each word goes
    /// to the speaker run containing its midpoint (the runs from
    /// `DiarizationProjection.speakerRuns` tile the whole file, so every
    /// word lands in one; the nearest-boundary fallback only covers float
    /// edges), then each run is cut into sentence-sized cues with
    /// `cues(fromWords:)` so a long coalesced turn doesn't become one
    /// minutes-long cue. Every word is kept — attribution, not slicing.
    static func diarizedCues(
        words: [WordReassembly.Word],
        runs: [DiarSegment],
        labels: [String: String]
    ) -> [(speaker: String, start: Double, end: Double, text: String)] {
        guard !runs.isEmpty else { return [] }
        var buckets: [[WordReassembly.Word]] = Array(repeating: [], count: runs.count)

        for word in words {
            let mid = (word.start + word.end) / 2
            if let idx = runs.firstIndex(where: { mid >= $0.start && mid < $0.end }) {
                buckets[idx].append(word)
                continue
            }
            var bestIdx = 0
            var bestDist = Double.greatestFiniteMagnitude
            for (idx, run) in runs.enumerated() {
                let dist = mid < run.start ? run.start - mid : mid - run.end
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = idx
                }
            }
            buckets[bestIdx].append(word)
        }

        var out: [(speaker: String, start: Double, end: Double, text: String)] = []
        for (idx, run) in runs.enumerated() {
            let speaker = labels[run.speakerId] ?? run.speakerId
            for cue in cues(fromWords: buckets[idx]) {
                out.append((speaker, cue.start, cue.end, cue.text))
            }
        }
        return out
    }

    /// Fallback when there are no per-word timings (Nemotron): apportion the
    /// transcript across runs proportionally to each run's share of total
    /// time, one cue per run. Ported from the app's
    /// `SpeakerTimelineBuilder.distributeText`.
    static func distributeText(
        transcript: String,
        segments: [DiarSegment],
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
