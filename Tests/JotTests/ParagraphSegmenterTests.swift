import XCTest
import FluidAudio
@testable import Jot

/// Unit tests for the post-transcription paragraph segmenter. Tests
/// exercise the pure helper functions directly (no FluidAudio model
/// load, no I/O).
final class ParagraphSegmenterTests: XCTestCase {

    // MARK: - apply(breaks:to:) — the four cases from the spec

    /// (a) Sentence-final punctuation + pause > threshold → insert
    /// `\n\n` between the two words. Padded with 9 filler words so the
    /// v2 "no break before word 10" cap doesn't suppress this case.
    func testPeriodLongPauseBreaks() {
        let filler = (0..<9).map { i in
            ParagraphSegmenter.Word(text: "w\(i)", start: Double(i) * 0.1, end: Double(i) * 0.1 + 0.05)
        }
        let words = filler + [
            ParagraphSegmenter.Word(text: "Hello.", start: 0.95, end: 1.0),
            ParagraphSegmenter.Word(text: "World.", start: 2.6, end: 3.0)
        ]
        let prefix = (0..<9).map { "w\($0)" }.joined(separator: " ")
        let out = ParagraphSegmenter.apply(breaks: words, to: "\(prefix) Hello. World.")
        XCTAssertEqual(out, "\(prefix) Hello.\n\nWorld.")
    }

    /// (b) Sentence-final punctuation but pause below threshold →
    /// no break, joined with a single space.
    func testPeriodShortPauseNoBreak() {
        let words = [
            ParagraphSegmenter.Word(text: "Hello.", start: 0.0, end: 0.5),
            ParagraphSegmenter.Word(text: "World.", start: 1.0, end: 1.5)
        ]
        let out = ParagraphSegmenter.apply(breaks: words, to: "Hello. World.")
        XCTAssertEqual(out, "Hello. World.")
    }

    /// (c) Long pause but no sentence-final punctuation on the prior
    /// word → no break.
    func testLongPauseNoPunctNoBreak() {
        let words = [
            ParagraphSegmenter.Word(text: "hello", start: 0.0, end: 0.5),
            ParagraphSegmenter.Word(text: "world", start: 2.5, end: 3.0)
        ]
        let out = ParagraphSegmenter.apply(breaks: words, to: "hello world")
        XCTAssertEqual(out, "hello world")
    }

    /// (d) Sentence-final punctuation followed by a closing quote +
    /// long pause → break still fires (trailing-quote trim is
    /// applied before the sentence-ender check). Padded with 9 filler
    /// words to clear the v2 "no break before word 10" cap.
    func testQuotePeriodLongPauseBreaks() {
        let filler = (0..<9).map { i in
            ParagraphSegmenter.Word(text: "w\(i)", start: Double(i) * 0.1, end: Double(i) * 0.1 + 0.05)
        }
        let words = filler + [
            ParagraphSegmenter.Word(text: "said.\"", start: 0.95, end: 1.0),
            ParagraphSegmenter.Word(text: "Then", start: 2.6, end: 3.0)
        ]
        let prefix = (0..<9).map { "w\($0)" }.joined(separator: " ")
        let out = ParagraphSegmenter.apply(breaks: words, to: "\(prefix) said.\" Then")
        XCTAssertEqual(out, "\(prefix) said.\"\n\nThen")
    }

    // MARK: - safety guards

    /// Empty word array → input text returned untouched (segmenter is
    /// a no-op rather than crashing on degenerate input).
    func testEmptyWordsReturnsTextUnchanged() {
        let out = ParagraphSegmenter.apply(breaks: [], to: "anything")
        XCTAssertEqual(out, "anything")
    }

    /// Single-word transcript → no possible break, returned unchanged.
    func testSingleWordReturnsTextUnchanged() {
        let words = [ParagraphSegmenter.Word(text: "Hi.", start: 0.0, end: 0.5)]
        let out = ParagraphSegmenter.apply(breaks: words, to: "Hi.")
        XCTAssertEqual(out, "Hi.")
    }

    /// Rescore drifted word count beyond tolerance → fall through and
    /// return the rescored text unchanged (better to lose paragraphs
    /// on one transcript than to insert breaks at the wrong word
    /// boundaries).
    func testWordCountDriftBeyondToleranceReturnsTextUnchanged() {
        // Raw words say there should be a break after word 0.
        let words = [
            ParagraphSegmenter.Word(text: "First.", start: 0.0, end: 0.5),
            ParagraphSegmenter.Word(text: "Second.", start: 2.5, end: 3.0)
        ]
        // Rescored text has 8 tokens vs the 2 raw words — far beyond
        // the 5% tolerance (or the 1-word minimum).
        let rescored = "this rescored text has many many more words now"
        let out = ParagraphSegmenter.apply(breaks: words, to: rescored)
        XCTAssertEqual(out, rescored)
    }

    /// Raw words and rescored tokens differ in where punctuation attaches:
    /// raw treats `.` as a standalone word (Parakeet BPE convention), so the
    /// break-after-period index maps to a mid-sentence position in the
    /// rescored array where `.` is glued to the preceding word. The index-
    /// safety guard must drop the break when the rescored token at that
    /// position doesn't actually end in sentence-final punctuation.
    func testMidSentenceBreakDroppedWhenRescoredDisagrees() {
        // Raw words: ["Hello", ".", "How", "are", "you", "?"] (6 words,
        // 4 alpha + 2 standalone punct). Pause >1.6s sits between the
        // period and "How" — the raw rule says "break after index 1".
        let words = [
            ParagraphSegmenter.Word(text: "Hello", start: 0.0, end: 0.4),
            ParagraphSegmenter.Word(text: ".",     start: 0.4, end: 0.5),
            ParagraphSegmenter.Word(text: "How",   start: 2.5, end: 2.7),
            ParagraphSegmenter.Word(text: "are",   start: 2.7, end: 2.9),
            ParagraphSegmenter.Word(text: "you",   start: 2.9, end: 3.2),
            ParagraphSegmenter.Word(text: "?",     start: 3.2, end: 3.3)
        ]
        // Rescored splits to: ["Hello.", "How", "are", "you?"] — 4 tokens.
        // Drift |6-4|=2, tolerance = max(1, 6*0.05) = 1 → would normally
        // bail. Bump words count to 20+ alpha to push tolerance over 2,
        // so we exercise the rescored-token verification path.
        let alpha = (0..<20).map { i in
            ParagraphSegmenter.Word(text: "x\(i)", start: 4.0 + 0.1*Double(i), end: 4.1 + 0.1*Double(i))
        }
        let allWords = words + alpha
        let rescored = "Hello. How are you? " + (0..<20).map { "x\($0)" }.joined(separator: " ")
        let out = ParagraphSegmenter.apply(breaks: allWords, to: rescored)
        // breakAfterWordIndex = {1} (after the standalone "."). In the
        // rescored array, index 1 = "How" (no period). The guard must
        // drop this break — output should match input exactly (no \n\n).
        XCTAssertFalse(out.contains("\n\n"), "Mid-sentence break leaked through index misalignment")
        XCTAssertEqual(out, rescored)
    }

    // MARK: - reassembleWords

    /// Three BPE tokens reassemble into two words at the `▁` boundary
    /// marker. First word's timings span tokens 0..1; second word
    /// starts at token 2.
    func testReassembleWordsBoundaryMarker() {
        let tokens = [
            TokenTiming(token: "▁Hel", tokenId: 1, startTime: 0.0, endTime: 0.2, confidence: 1.0),
            TokenTiming(token: "lo.", tokenId: 2, startTime: 0.2, endTime: 0.5, confidence: 1.0),
            TokenTiming(token: "▁World.", tokenId: 3, startTime: 2.5, endTime: 3.0, confidence: 1.0)
        ]
        let words = ParagraphSegmenter.reassembleWords(from: tokens)
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].text, "Hello.")
        XCTAssertEqual(words[0].start, 0.0)
        XCTAssertEqual(words[0].end, 0.5)
        XCTAssertEqual(words[1].text, "World.")
        XCTAssertEqual(words[1].start, 2.5)
        XCTAssertEqual(words[1].end, 3.0)
    }

    /// Empty token array → empty word array.
    func testReassembleEmptyTokens() {
        let out = ParagraphSegmenter.reassembleWords(from: [])
        XCTAssertEqual(out, [])
    }

    // MARK: - v2 discourse-marker fast path

    /// Helper — builds 10 filler words (indices 0..9) with tiny gaps,
    /// then a sentence-final word at index 10 ending at `t`, then the
    /// `next` word(s) starting after a `gap` second pause.
    private func discourseFixture(
        terminal: String = "There.",
        nextWords: [String],
        gap: TimeInterval
    ) -> (words: [ParagraphSegmenter.Word], text: String) {
        // 10 filler words at indices 0..9. The terminal sentence-final
        // word lands at index 10 so the break candidate would be
        // "after index 10" — i.e. i = 10, which clears cap (1)
        // (i >= 9). i+1 = 11 is the first marker word.
        var words: [ParagraphSegmenter.Word] = []
        for i in 0..<10 {
            words.append(ParagraphSegmenter.Word(
                text: "w\(i)",
                start: Double(i) * 0.1,
                end: Double(i) * 0.1 + 0.05
            ))
        }
        let terminalEnd = 1.05
        words.append(ParagraphSegmenter.Word(text: terminal, start: 1.0, end: terminalEnd))
        var t = terminalEnd + gap
        for w in nextWords {
            words.append(ParagraphSegmenter.Word(text: w, start: t, end: t + 0.1))
            t += 0.2
        }
        let prefix = (0..<10).map { "w\($0)" }.joined(separator: " ")
        let text = "\(prefix) \(terminal) " + nextWords.joined(separator: " ")
        return (words, text)
    }

    /// 1. Sentence-final + 1.1s pause + "So" → break (discourse fast path).
    func testDiscourseMarkerSoBreaks() {
        let (words, text) = discourseFixture(nextWords: ["So", "yeah."], gap: 1.1)
        let out = ParagraphSegmenter.apply(breaks: words, to: text)
        XCTAssertTrue(out.contains("There.\n\nSo"), "Expected break before 'So', got: \(out)")
    }

    /// 2. "However," with trailing comma → marker match still fires.
    func testDiscourseMarkerHoweverWithCommaBreaks() {
        let (words, text) = discourseFixture(nextWords: ["However,", "wait."], gap: 1.1)
        let out = ParagraphSegmenter.apply(breaks: words, to: text)
        XCTAssertTrue(out.contains("There.\n\nHowever,"), "Expected break before 'However,', got: \(out)")
    }

    /// 3. "and then" two-word marker → break.
    func testDiscourseMarkerAndThenBreaks() {
        let (words, text) = discourseFixture(nextWords: ["and", "then", "we"], gap: 1.1)
        let out = ParagraphSegmenter.apply(breaks: words, to: text)
        XCTAssertTrue(out.contains("There.\n\nand"), "Expected break before 'and then', got: \(out)")
    }

    /// 4. "OKAY" and "Now" — case-insensitive matching.
    func testDiscourseMarkerCaseInsensitive() {
        let (words, text) = discourseFixture(nextWords: ["OKAY", "go."], gap: 1.1)
        let out = ParagraphSegmenter.apply(breaks: words, to: text)
        XCTAssertTrue(out.contains("There.\n\nOKAY"), "Expected break before 'OKAY', got: \(out)")
    }

    /// 5. 1.1s pause + sentence-final + "the" (NOT a marker) → no break.
    /// Pause is below the 1.4s primary threshold so primary rule
    /// shouldn't fire; discourse fast path shouldn't fire either.
    func testNoDiscourseMarkerNoFastPath() {
        let (words, text) = discourseFixture(nextWords: ["the", "rest."], gap: 1.1)
        let out = ParagraphSegmenter.apply(breaks: words, to: text)
        XCTAssertFalse(out.contains("\n\n"), "Unexpected break in: \(out)")
        XCTAssertEqual(out, text)
    }

    // MARK: - v2 safety caps

    /// 6. Long sentence-final pause at word index 3 → cap (1) suppresses.
    func testBreakSuppressedBeforeWord10() {
        let words = [
            ParagraphSegmenter.Word(text: "One", start: 0.0, end: 0.1),
            ParagraphSegmenter.Word(text: "two", start: 0.2, end: 0.3),
            ParagraphSegmenter.Word(text: "three", start: 0.4, end: 0.5),
            ParagraphSegmenter.Word(text: "four.", start: 0.6, end: 0.7),
            // Pause >1.4s after "four." would normally fire primary.
            ParagraphSegmenter.Word(text: "Five", start: 2.5, end: 2.6),
            ParagraphSegmenter.Word(text: "six.", start: 2.7, end: 2.8)
        ]
        let text = "One two three four. Five six."
        let out = ParagraphSegmenter.apply(breaks: words, to: text)
        XCTAssertFalse(out.contains("\n\n"), "Cap (1) should suppress break before word 10, got: \(out)")
        XCTAssertEqual(out, text)
    }

    /// 7. Three primary-rule candidates: first at i=10, second at i=14
    /// (within 8 of first → rejected), third at i=22 (12 from i=10 →
    /// accepted). Expect exactly two breaks: after i=10 and after i=22.
    func testTwoCloseBreaksThirdSuppressed() {
        // 30-word transcript. Sentence-final words at indices 10, 14, 22.
        // 1.6s pause AFTER each of those words.
        var words: [ParagraphSegmenter.Word] = []
        var t: TimeInterval = 0.0
        let breakIndices: Set<Int> = [10, 14, 22]
        for i in 0..<30 {
            let text: String
            if breakIndices.contains(i) {
                text = "w\(i)."
            } else {
                text = "w\(i)"
            }
            let end = t + 0.1
            words.append(ParagraphSegmenter.Word(text: text, start: t, end: end))
            // Next word starts after a long pause if this one is a
            // sentence-final break index, else immediately after.
            if breakIndices.contains(i) {
                t = end + 1.6
            } else {
                t = end + 0.1
            }
        }
        let text = words.map { $0.text }.joined(separator: " ")
        let out = ParagraphSegmenter.apply(breaks: words, to: text)
        // Expect breaks after w10 (i=10 accepted), suppress after w14
        // (14-10=4 < 8), accept after w22 (22-10=12 >= 8).
        XCTAssertTrue(out.contains("w10.\n\nw11"), "Expected break after w10., got: \(out)")
        XCTAssertFalse(out.contains("w14.\n\nw15"), "Cap (2) should suppress break after w14., got: \(out)")
        XCTAssertTrue(out.contains("w22.\n\nw23"), "Expected break after w22., got: \(out)")
        // Sanity: exactly two paragraph breaks.
        XCTAssertEqual(out.components(separatedBy: "\n\n").count - 1, 2)
    }

    /// 8. Primary rule still fires at >1.4s + sentence-final, when the
    /// break index clears the safety caps. (Padded so i=9 is the
    /// sentence-final word — break after i=9 → i+1=10 is the 11th
    /// word, cap (1) allows it.)
    func testExistingPrimaryRuleStillWorks() {
        let filler = (0..<9).map { i in
            ParagraphSegmenter.Word(text: "w\(i)", start: Double(i) * 0.1, end: Double(i) * 0.1 + 0.05)
        }
        let words = filler + [
            ParagraphSegmenter.Word(text: "Hello.", start: 0.95, end: 1.0),
            ParagraphSegmenter.Word(text: "World.", start: 2.6, end: 3.0)
        ]
        let prefix = (0..<9).map { "w\($0)" }.joined(separator: " ")
        let out = ParagraphSegmenter.apply(breaks: words, to: "\(prefix) Hello. World.")
        XCTAssertEqual(out, "\(prefix) Hello.\n\nWorld.")
    }
}
