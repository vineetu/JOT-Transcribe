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
    /// No token timings are consulted here — the split first allocates whole
    /// words proportionally to each segment's share of the audio duration
    /// (the pre-existing coarse estimate), then SNAPS each internal boundary
    /// to the nearest sentence boundary within `maxSnapDistanceWords` words,
    /// so a speaker change never splits a sentence mid-way. A transcript with
    /// no sentence punctuation degrades to the plain proportional split
    /// unchanged (see `docs/speaker-diarization/design.md` § Token→speaker
    /// alignment — boundary refinement sits ON TOP of the same splitter).
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

        let totalWords = words.count

        // Coarse proportional boundaries — byte-for-byte the algorithm that
        // shipped before sentence snapping (per-segment rounded share, last
        // segment takes the remainder), expressed as exclusive end indices.
        var coarse: [Int] = []
        coarse.reserveCapacity(segments.count)
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
            cursor = min(totalWords, cursor + wantCount)
            coarse.append(cursor)
        }

        let boundaries = snapBoundaries(coarse: coarse, words: words)

        var out: [SpeakerTimelineSegment] = []
        out.reserveCapacity(segments.count)
        var start = 0
        for (idx, seg) in segments.enumerated() {
            let end = boundaries[idx]
            out.append(SpeakerTimelineSegment(
                speakerLabel: seg.label,
                startSec: seg.startSec,
                endSec: seg.endSec,
                text: words[start..<end].joined(separator: " ")
            ))
            start = end
        }
        return out
    }

    // MARK: - Sentence-boundary snapping

    /// Snap cap: a boundary may move at most this many words from its
    /// proportional position. Bounds the damage on a transcript whose only
    /// punctuation is far away (and makes a punctuation-free transcript
    /// degrade to the untouched proportional split).
    static let maxSnapDistanceWords = 15

    /// Move each internal coarse boundary to the nearest sentence boundary
    /// (position after a sentence-ending word) within the snap cap. The last
    /// boundary is pinned to `words.count` and candidate bounds are STRICT
    /// on BOTH sides: `prev < candidate < coarse[idx + 1]` — below the
    /// previous CHOSEN boundary protects the segment being snapped, and
    /// below the NEXT COARSE boundary protects every following segment (a
    /// forward snap past it would leave the next boundary nowhere to go).
    /// The actual guarantee: snapping never empties any segment that the
    /// coarse proportional split left nonempty (segments the coarse split
    /// itself left empty — a rounding artifact possible before snapping ever
    /// existed — stay as they were). Nearest wins; on a distance tie the
    /// earlier position wins (keeps the following sentence with the speaker
    /// who audibly starts it).
    static func snapBoundaries(coarse: [Int], words: [String]) -> [Int] {
        let totalWords = words.count
        guard coarse.count > 1 else { return coarse.isEmpty ? [] : [totalWords] }

        var sentenceEnds: Set<Int> = []
        for (i, w) in words.enumerated() {
            let next = i + 1 < words.count ? words[i + 1] : nil
            if isSentenceEnd(w, next: next) {
                sentenceEnds.insert(i + 1)
            }
        }

        var out: [Int] = []
        out.reserveCapacity(coarse.count)
        var prev = 0
        for idx in 0..<(coarse.count - 1) {
            let b = min(max(coarse[idx], prev), totalWords)
            // `coarse.last` is always `totalWords`, so for the boundary just
            // before the last this degenerates to `candidate < totalWords`.
            let upper = coarse[idx + 1]
            var chosen = b
            if !sentenceEnds.isEmpty {
                search: for delta in 0...maxSnapDistanceWords {
                    for candidate in (delta == 0 ? [b] : [b - delta, b + delta]) {
                        if candidate > prev, candidate < upper, sentenceEnds.contains(candidate) {
                            chosen = candidate
                            break search
                        }
                    }
                }
            }
            prev = chosen
            out.append(chosen)
        }
        out.append(totalWords)
        return out
    }

    /// Known abbreviations whose trailing period does NOT end a sentence.
    /// Deliberately small — this mirrors the abbreviation-guard *idea* from
    /// `JotTextPipeline`'s cleanup chain without importing it (design accepts
    /// plain `.!?` as sufficient for v1; this is a cheap upgrade on top).
    /// ("no." is deliberately NOT in this set — "The answer is no." is a
    /// legitimate sentence end, and the numero abbreviation is rare in
    /// dictated speech.)
    static let nonTerminalAbbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "st.",
        "vs.", "etc.", "e.g.", "i.e.", "inc.", "ltd.", "co.", "approx.",
    ]

    /// Whether `word` (a whitespace-split token) ends a sentence. Trailing
    /// closing quotes/brackets are ignored; `. ! ? …` (plus CJK `。！？`)
    /// terminate, with a period additionally guarded against known
    /// abbreviations, single-letter initials (`J.`), dotted acronyms
    /// (`u.s.`), and — given `next` — ordinal-style number+period followed
    /// by a lowercase continuation ("am 3. mai"; a capitalized next word
    /// stays ambiguous with German noun capitalization, which the 15-word
    /// snap cap bounds). Spanish `¿ ¡` open a sentence — the matching `? !`
    /// closers are what this detects.
    static func isSentenceEnd(_ word: String, next: String? = nil) -> Bool {
        var w = Substring(word)
        while let last = w.last, "\"'’”»)]".contains(last) { w.removeLast() }
        guard let last = w.last else { return false }
        if "!?…。！？".contains(last) { return true }
        guard last == "." else { return false }
        var dots = 0
        while w.last == "." {
            w.removeLast()
            dots += 1
        }
        if dots >= 2 { return true } // "word..." — ASCII ellipsis
        guard !w.isEmpty else { return false } // lone "."
        if nonTerminalAbbreviations.contains(w.lowercased() + ".") { return false }
        if w.count == 1, w.first?.isLetter == true { return false } // initial "J."
        if w.contains(".") { return false } // dotted acronym "u.s."
        if w.allSatisfy(\.isNumber), let first = next?.first, first.isLowercase {
            return false // ordinal: "am 3. mai"
        }
        return true
    }

    /// Group consecutive same-label segments into one display block —
    /// render-time belt-and-suspenders over the builder-level run coalescing
    /// (`DiarizationTimelineBuilder.coalesceSameSpeakerRuns`), and the ONLY
    /// coalescing old already-persisted payloads (which still carry the
    /// fine-grained per-turn segments) ever get. Empty-text segments are
    /// dropped — they render as a bare header otherwise. Rename (D5) is
    /// unaffected: it rewrites the stored payload's label strings, and this
    /// groups whatever labels it's given.
    static func coalesceDisplayRuns(_ segments: [SpeakerTimelineSegment]) -> [SpeakerTimelineSegment] {
        var out: [SpeakerTimelineSegment] = []
        out.reserveCapacity(segments.count)
        for seg in segments {
            let trimmedText = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { continue }
            if let last = out.last, last.speakerLabel == seg.speakerLabel {
                out[out.count - 1] = SpeakerTimelineSegment(
                    speakerLabel: last.speakerLabel,
                    startSec: last.startSec,
                    endSec: max(last.endSec, seg.endSec),
                    text: last.text + " " + trimmedText
                )
            } else {
                out.append(SpeakerTimelineSegment(
                    speakerLabel: seg.speakerLabel,
                    startSec: seg.startSec,
                    endSec: seg.endSec,
                    text: trimmedText
                ))
            }
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
