import Foundation
import FluidAudio

/// Post-transcription paragraph segmentation. Pure function with no I/O —
/// safe to call from any batch-transcription path (menu-bar dictation,
/// Rewrite, Setup Wizard mic test, etc.). Streaming is NOT covered;
/// the streaming pipeline never goes through this surface.
///
/// Heuristic (v2):
///   - Primary rule: pause `> 1.4s` between adjacent words AND prev
///     word ends in `.`, `!`, or `?` (after trimming trailing
///     quotes/brackets) → candidate break.
///   - Discourse-marker fast path: pause `> 1.0s` AND prev word is
///     sentence-final (same trim) AND the next word (or "and then"
///     two-word phrase) matches a known discourse marker
///     case-insensitively → candidate break.
///   - Safety caps applied to all candidates in ascending order:
///     (1) no break before word 10 of the transcript;
///     (2) no break within 8 words of the previous accepted break.
///   - Any accidental consecutive `\n\n\n\n` is collapsed to `\n\n`.
///
/// The segmenter still returns the rescored text untouched on
/// degenerate inputs, reassembly drift, or rescore word-count drift
/// beyond tolerance — paragraph segmentation can never regress the
/// user-visible transcription.
enum ParagraphSegmenter {

    /// Pause (seconds) between adjacent words that, combined with a
    /// sentence-final punctuation mark on the prior word, triggers a
    /// paragraph break.
    static let paragraphPauseThreshold: TimeInterval = 1.4

    /// Pause (seconds) for the discourse-marker fast path. Shorter than
    /// the primary threshold because we also require the next word to
    /// be a known marker ("So", "Okay", "However", "and then", …) on
    /// top of the sentence-final prior word.
    static let discourseMarkerPauseThreshold: TimeInterval = 1.0

    /// Hard floor on where the first paragraph break can land. With the
    /// 10-word warmup the segmenter never carves a one-sentence
    /// fragment off the start of a transcript.
    static let minWordsBeforeFirstBreak: Int = 10

    /// Minimum spacing (in raw words) between two accepted paragraph
    /// breaks. Prevents the segmenter from chopping the transcript
    /// into many tiny single-sentence paragraphs.
    static let minWordsBetweenBreaks: Int = 8

    /// Punctuation that, when found at the trailing edge of a word
    /// (after trimming closing quotes/brackets), counts as
    /// sentence-final for paragraph-break purposes.
    private static let sentenceEnders: Set<Character> = [".", "!", "?"]

    /// Discourse markers that, when starting the next utterance after
    /// a sentence-final word and a short pause, indicate a topic shift
    /// strong enough to justify a paragraph break even though the pause
    /// is below the primary threshold. Lowercase, exact strings; the
    /// two-word entry is matched against the next two words joined
    /// with a single space.
    private static let discourseMarkers: [String] = [
        "so", "okay", "alright", "now", "next",
        "however", "anyway", "but", "and then"
    ]

    /// Characters trimmed off the trailing edge of a word before
    /// checking for sentence-final punctuation. Covers ASCII closing
    /// quotes/brackets plus the common curly variants users dictate.
    private static let trailingTrimSet = CharacterSet(charactersIn: "\"')]}»’”")

    /// Token-boundary markers Parakeet BPE tokenizers use to indicate
    /// "this token starts a new word." Tokens NOT prefixed with one of
    /// these are continuations of the previous word.
    private static let wordStartMarkers: [Character] = ["▁", " "]

    /// Reassembled-word view of the FluidAudio token-timing array.
    struct Word: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Top-level entry point. Returns the rescored text untouched on
    /// any degenerate or unsupported input.
    static func segment(
        rescoredText: String,
        tokenTimings: [TokenTiming]
    ) -> String {
        let words = reassembleWords(from: tokenTimings)
        return apply(breaks: words, to: rescoredText)
    }

    /// Visible for testing — converts FluidAudio's BPE token timings
    /// into word-level boundaries. Tokens prefixed with `▁` or a
    /// leading space start a new word; everything else extends the
    /// previous one. First token always starts a word.
    static func reassembleWords(from tokens: [TokenTiming]) -> [Word] {
        guard !tokens.isEmpty else { return [] }

        var words: [Word] = []
        var currentText = ""
        var currentStart: TimeInterval = tokens[0].startTime
        var currentEnd: TimeInterval = tokens[0].endTime

        for (index, token) in tokens.enumerated() {
            let trimmed = stripWordStartMarker(token.token)
            // Skip pad/empty/special tokens entirely — they shouldn't
            // contribute to a word's text but also shouldn't split it.
            guard !trimmed.isEmpty else { continue }

            let isWordStart = index == 0 || isWordStartToken(token.token)

            if isWordStart {
                if !currentText.isEmpty {
                    words.append(
                        Word(text: currentText, start: currentStart, end: currentEnd)
                    )
                }
                currentText = trimmed
                currentStart = token.startTime
                currentEnd = token.endTime
            } else {
                currentText += trimmed
                currentEnd = token.endTime
            }
        }

        if !currentText.isEmpty {
            words.append(
                Word(text: currentText, start: currentStart, end: currentEnd)
            )
        }

        return words
    }

    /// Visible for testing — given the reassembled word boundaries and
    /// the post-rescore text, returns either the segmented text or the
    /// rescored text unchanged. Splits the rescored text on
    /// whitespace and walks the same word-index positions.
    static func apply(breaks words: [Word], to text: String) -> String {
        guard words.count > 1 else { return text }

        // Compute candidate break positions on the raw words first.
        // Two independent triggers — accept the break if EITHER fires.
        var candidates: Set<Int> = []
        for i in 0..<(words.count - 1) {
            let gap = words[i + 1].start - words[i].end
            // Both rules require sentence-final punctuation on the
            // prior word. Trim once.
            let trimmed = words[i].text.trimmingCharacters(in: trailingTrimSet)
            guard let lastChar = trimmed.last,
                  sentenceEnders.contains(lastChar) else { continue }

            let primary = gap > paragraphPauseThreshold
            let discourse = gap > discourseMarkerPauseThreshold
                && nextIsDiscourseMarker(after: i, words: words)

            if primary || discourse {
                candidates.insert(i)
            }
        }

        if candidates.isEmpty { return text }

        // Safety caps: applied in ascending index order so the
        // "8 words since last accepted break" rule is deterministic.
        // (1) reject anything with i < minWordsBeforeFirstBreak - 1
        //     (break-after-word-i sits between words i and i+1; we want
        //     i+1 to be at least word 11, so i >= 9 i.e. >= 10 - 1).
        // (2) reject anything within minWordsBetweenBreaks of the
        //     previous accepted break.
        let sorted = candidates.sorted()
        var breakAfterWordIndex: Set<Int> = []
        var lastAccepted: Int? = nil
        for i in sorted {
            if i < minWordsBeforeFirstBreak - 1 { continue }
            if let last = lastAccepted, i - last < minWordsBetweenBreaks {
                continue
            }
            breakAfterWordIndex.insert(i)
            lastAccepted = i
        }

        if breakAfterWordIndex.isEmpty { return text }

        // Re-split the post-rescore text. omittingEmptySubsequences:true
        // so accidental double spaces don't inflate the token count
        // (which would false-fire the drift guard below).
        let rescoredTokens = text.split(
            whereSeparator: { $0.isWhitespace || $0.isNewline }
        )

        // Word-count drift guard. If the rescorer added or removed
        // words by more than a small tolerance, the word-index
        // positions don't line up and we'd insert breaks in the
        // wrong places. Bail out and return the rescored text
        // unchanged — losing paragraph segmentation on this one
        // transcript is preferable to garbling the text.
        let drift = abs(rescoredTokens.count - words.count)
        let tolerance = max(1, Int(Double(words.count) * 0.05))
        guard drift <= tolerance else { return text }

        var out: [String] = []
        out.reserveCapacity(rescoredTokens.count * 2)
        for (i, t) in rescoredTokens.enumerated() {
            out.append(String(t))
            guard i < rescoredTokens.count - 1 else { continue }
            // Index-safety guard: even when the raw-word array says "break
            // after word i", confirm the rescored token at this position
            // ALSO ends in sentence-final punctuation. If raw and rescored
            // disagree on where the period attaches (BPE tokenizers often
            // emit "." as its own ▁-prefixed word, but rescored whitespace-
            // split packages "." onto the preceding token), the raw word
            // index can map to a rescored mid-sentence position. Without
            // this check the paragraph break lands mid-sentence — exactly
            // the bug users reported. False negatives (missing a break) are
            // invisible; false positives (wrong-place break) are jarring.
            let shouldBreak = breakAfterWordIndex.contains(i) && {
                let trimmed = String(t).trimmingCharacters(in: trailingTrimSet)
                guard let lastChar = trimmed.last else { return false }
                return sentenceEnders.contains(lastChar)
            }()
            out.append(shouldBreak ? "\n\n" : " ")
        }

        var result = out.joined()
        // Collapse any accidental consecutive paragraph breaks.
        while result.contains("\n\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n\n", with: "\n\n")
        }
        return result
    }

    // MARK: - Helpers

    /// Returns true if the word(s) immediately following `index` match a
    /// known discourse marker, case-insensitively, after trimming
    /// trailing punctuation/quotes off the candidate token(s). Handles
    /// both single-word markers ("so", "okay", "however", …) and the
    /// two-word "and then" phrase.
    private static func nextIsDiscourseMarker(after index: Int, words: [Word]) -> Bool {
        let nextIndex = index + 1
        guard nextIndex < words.count else { return false }

        let single = normalizedDiscourseToken(words[nextIndex].text)
        if discourseMarkers.contains(single) { return true }

        // Two-word lookahead for "and then".
        let secondIndex = nextIndex + 1
        if secondIndex < words.count {
            let pair = "\(single) \(normalizedDiscourseToken(words[secondIndex].text))"
            if discourseMarkers.contains(pair) { return true }
        }

        return false
    }

    /// Lowercase + strip trailing punctuation/quotes for discourse-marker
    /// comparison. Punctuation stripped is a superset of `trailingTrimSet`
    /// because markers commonly carry trailing commas ("However,") in
    /// addition to closing quotes.
    private static func normalizedDiscourseToken(_ raw: String) -> String {
        let punct = CharacterSet(charactersIn: ",.!?;:\"')]}»’”")
        return raw.trimmingCharacters(in: punct).lowercased()
    }

    private static func isWordStartToken(_ raw: String) -> Bool {
        guard let first = raw.first else { return false }
        return wordStartMarkers.contains(first)
    }

    private static func stripWordStartMarker(_ raw: String) -> String {
        guard let first = raw.first, wordStartMarkers.contains(first) else {
            return raw
        }
        return String(raw.dropFirst())
    }
}
