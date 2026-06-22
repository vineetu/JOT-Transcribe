import Foundation

/// Length-adaptive transcript chunker for semantic-search ingestion. Pure,
/// synchronous, deterministic — no SwiftData, no ML model, no app state, no
/// `Date()`/random. One whole-transcript string in, an ordered list of
/// `ChunkDraft`s out.
///
/// Ported essentially verbatim from jot-mobile
/// (`jot-mobile/Jot/App/Embeddings/TranscriptChunker.swift`); the only change
/// is dropping the iOS-only `#if JOT_APP_HOST` guard.
///
/// ## Why chunk at all
///
/// Embedding a whole transcript into one vector is a blurry average — a specific
/// idea inside a long recording is washed out, and the embedder truncates long
/// input so the tail is never seen at all. Splitting into ~targetTokens windows
/// gives the dense retrieval channel something granular to match, and the
/// `charStart`/`charEnd` offsets let a future citation deep-link back to the
/// exact span in the source text.
///
/// ## Token heuristic (no tokenizer dependency)
///
/// We never load a real tokenizer here — this file stays a pure function. We
/// approximate **~4 characters ≈ 1 token** (English-ish prose, the GPT-family
/// rule of thumb), so `targetTokens * 4` is the target chunk size in characters.
/// The estimate only needs to be good enough to keep chunks inside the embedder's
/// real token window; the embedder re-tokenizes for real downstream.
///
/// ## Offset contract
///
/// `charStart`/`charEnd` are **Character** offsets (grapheme positions, via
/// `String.Index` distances), *not* UTF-16 / byte offsets, so emoji and combining
/// marks count as one. `String(Array(text)[charStart..<charEnd])` reproduces the
/// *untrimmed* span; the chunk's own `text` is that span with leading/trailing
/// whitespace trimmed, while the offsets are tightened to point at the trimmed
/// span. Windows together cover the whole source — no content is dropped — and no
/// empty chunk is ever emitted.
enum TranscriptChunker {
    struct ChunkDraft: Equatable {
        let chunkIndex: Int   // 0-based position within the transcript
        let text: String      // the chunk's own text
        let charStart: Int    // Character offset from the source string start (source[start..<end] reproduces text)
        let charEnd: Int
    }

    /// Length-adaptive. Short transcripts → a single chunk. Long ones → ~targetTokens
    /// windows with ~overlapRatio overlap, split on sentence boundaries where present,
    /// falling back to a fixed character window when the text has no sentence punctuation.
    static func chunk(_ text: String, targetTokens: Int = 256, overlapRatio: Double = 0.15) -> [ChunkDraft] {
        // Work in a Character array: all offsets in the public contract are
        // grapheme positions, and indexing an array is O(1) vs String.Index walks.
        let chars = Array(text)
        let total = chars.count
        if total == 0 { return [] }

        // ~4 chars ≈ 1 token (see file banner). targetChars is the window size.
        let targetChars = max(1, targetTokens * 4)

        // Common path: the whole note fits in one window. Trim and return a
        // single chunk, or [] if the text is all whitespace.
        if total <= targetChars {
            if let draft = makeDraft(chars, start: 0, end: total, index: 0) {
                return [draft]
            }
            return []
        }

        // Long text. Prefer sentence-aware packing; fall back to fixed windows
        // when there are effectively no sentence boundaries to pack on.
        let sentences = splitSentences(chars)
        if sentences.count <= 1 {
            return fixedWindowChunks(chars, targetChars: targetChars, overlapRatio: overlapRatio)
        }
        return sentenceWindowChunks(
            chars,
            sentences: sentences,
            targetChars: targetChars,
            overlapRatio: overlapRatio
        )
    }

    // MARK: - Sentence splitting

    /// A sentence span as half-open Character offsets `[start, end)` into the
    /// source array. The terminating `.`/`!`/`?` (and any run of them) stays
    /// attached to the sentence; trailing whitespace up to the next sentence is
    /// folded in too so the spans tile the whole text with no gaps.
    private struct SentenceSpan { let start: Int; let end: Int }

    private static func splitSentences(_ chars: [Character]) -> [SentenceSpan] {
        var spans: [SentenceSpan] = []
        var start = 0
        var i = 0
        let n = chars.count
        while i < n {
            let c = chars[i]
            if c == "." || c == "!" || c == "?" {
                // Absorb a run of terminators ("?!", "...") into one boundary.
                var j = i + 1
                while j < n, chars[j] == "." || chars[j] == "!" || chars[j] == "?" {
                    j += 1
                }
                // Absorb trailing whitespace so spans leave no gap between them.
                while j < n, chars[j].isWhitespace {
                    j += 1
                }
                spans.append(SentenceSpan(start: start, end: j))
                start = j
                i = j
            } else {
                i += 1
            }
        }
        // Trailing text with no terminator is a final sentence.
        if start < n {
            spans.append(SentenceSpan(start: start, end: n))
        }
        return spans
    }

    // MARK: - Sentence-window packing

    private static func sentenceWindowChunks(
        _ chars: [Character],
        sentences: [SentenceSpan],
        targetChars: Int,
        overlapRatio: Double
    ) -> [ChunkDraft] {
        var drafts: [ChunkDraft] = []
        var sentenceIdx = 0
        let count = sentences.count
        let clampedRatio = min(max(overlapRatio, 0), 0.9)

        while sentenceIdx < count {
            // Greedily pack sentences into a window up to ~targetChars. Always
            // take at least one sentence so we make forward progress even if a
            // single sentence is itself longer than the target.
            let windowStartSentence = sentenceIdx
            var lastSentence = sentenceIdx
            var windowChars = sentences[sentenceIdx].end - sentences[sentenceIdx].start
            var probe = sentenceIdx + 1
            while probe < count {
                let next = sentences[probe]
                let addition = next.end - next.start
                if windowChars + addition > targetChars { break }
                windowChars += addition
                lastSentence = probe
                probe += 1
            }

            let spanStart = sentences[windowStartSentence].start
            let spanEnd = sentences[lastSentence].end
            if let draft = makeDraft(chars, start: spanStart, end: spanEnd, index: drafts.count) {
                drafts.append(draft)
            }

            // If we consumed to the end, we're done.
            if lastSentence >= count - 1 { break }

            // Compute the next window's start: step back over trailing sentences
            // of this window until we've covered ~overlapRatio of the window's
            // characters, so adjacent chunks share context.
            let overlapTargetChars = Int(Double(windowChars) * clampedRatio)
            var nextStart = lastSentence + 1
            if overlapTargetChars > 0 && lastSentence > windowStartSentence {
                var accumulated = 0
                var k = lastSentence
                while k > windowStartSentence {
                    let len = sentences[k].end - sentences[k].start
                    // Always re-include at least the last sentence (k ==
                    // lastSentence) so a non-zero overlapRatio yields real
                    // overlap even when one sentence already exceeds the budget;
                    // otherwise stop once the budget is met.
                    if k < lastSentence && accumulated + len > overlapTargetChars { break }
                    accumulated += len
                    k -= 1
                }
                // Start the next window at the first overlapped sentence (k+1),
                // but never before the start of the window we just emitted + 1
                // so we always advance.
                nextStart = max(k + 1, windowStartSentence + 1)
            }
            sentenceIdx = nextStart
        }
        return drafts
    }

    // MARK: - Fixed-window fallback

    private static func fixedWindowChunks(
        _ chars: [Character],
        targetChars: Int,
        overlapRatio: Double
    ) -> [ChunkDraft] {
        var drafts: [ChunkDraft] = []
        let n = chars.count
        let clampedRatio = min(max(overlapRatio, 0), 0.9)
        // Step forward by (window - overlap), at least 1 char to guarantee progress.
        let overlapChars = Int(Double(targetChars) * clampedRatio)
        let step = max(1, targetChars - overlapChars)

        var start = 0
        while start < n {
            let end = min(start + targetChars, n)
            if let draft = makeDraft(chars, start: start, end: end, index: drafts.count) {
                drafts.append(draft)
            }
            if end >= n { break }
            start += step
        }
        return drafts
    }

    // MARK: - Draft construction (trim + tighten offsets)

    /// Build a `ChunkDraft` for the half-open span `[start, end)`, trimming
    /// leading/trailing whitespace and tightening the offsets to the trimmed
    /// span. Returns `nil` if the span is empty or all-whitespace (never emit an
    /// empty chunk).
    private static func makeDraft(_ chars: [Character], start: Int, end: Int, index: Int) -> ChunkDraft? {
        var lo = start
        var hi = end
        while lo < hi, chars[lo].isWhitespace { lo += 1 }
        while hi > lo, chars[hi - 1].isWhitespace { hi -= 1 }
        if lo >= hi { return nil }
        let text = String(chars[lo..<hi])
        return ChunkDraft(chunkIndex: index, text: text, charStart: lo, charEnd: hi)
    }
}
