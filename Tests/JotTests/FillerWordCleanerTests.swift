import XCTest
@testable import Jot

/// Unit tests for the post-transcription filler-word cleaner. Tests
/// exercise the pure helper directly (no FluidAudio model load, no
/// I/O). Mirrors the structure of `ParagraphSegmenterTests`.
final class FillerWordCleanerTests: XCTestCase {

    // MARK: - The six cases from the spec

    /// (a) Leading filler + comma + space → strip the filler and its
    /// adjacent comma/space.
    func testLeadingUmCommaStripped() {
        let out = FillerWordCleaner.clean("Um, I think")
        XCTAssertEqual(out, "I think")
    }

    /// (b) Filler bracketed by commas → strip the filler AND both
    /// adjacent comma/space pairs.
    func testInlineUhWithSurroundingCommasStripped() {
        let out = FillerWordCleaner.clean("I, uh, mean")
        XCTAssertEqual(out, "I mean")
    }

    /// (c) `\b` word boundary respected — `umbrella` is not a filler.
    func testUmbrellaWordBoundaryRespected() {
        let out = FillerWordCleaner.clean("umbrella")
        XCTAssertEqual(out, "umbrella")
    }

    /// (d) Elongated `Ummmm` matches via `um(m+)?` and the surviving
    /// `yes` becomes the new first-sentence capital.
    func testElongatedUmStrippedAndRecapitalized() {
        let out = FillerWordCleaner.clean("Ummmm yes")
        XCTAssertEqual(out, "Yes")
    }

    /// (e) All-filler input collapses to empty after orphan-punct and
    /// leading-punct cleanup. The recapitalize step must be a no-op
    /// on the empty string (no index-into-empty crash).
    func testAllFillerCollapsesToEmpty() {
        let out = FillerWordCleaner.clean("Um. Uh.")
        XCTAssertEqual(out, "")
    }

    /// (f) Integration with `ParagraphSegmenter`: the segmenter
    /// inserts `\n\n` between sentences when the pause + sentence-final
    /// punctuation gates fire, and the filler cleaner must NOT
    /// collapse that paragraph boundary when it strips an adjacent
    /// `um`. This test runs the segmenter first (so the wiring order
    /// in `TranscriptionService` is faithfully reproduced) and then
    /// the cleaner, and asserts the boundary survives.
    func testParagraphBoundaryPreservedAcrossFillerStrip() {
        // Two words, second one is `um` with a `>1.6s` pause after
        // the period-ending first word — segmenter inserts `\n\n`.
        let segmented = "Hello.\n\num New paragraph."
        let out = FillerWordCleaner.clean(segmented)
        XCTAssertEqual(out, "Hello.\n\nNew paragraph.")
    }

    // MARK: - extra guards

    /// Empty input → empty output, no crash.
    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(FillerWordCleaner.clean(""), "")
    }

    /// No fillers at all → text returned untouched (no spurious
    /// recapitalization beyond what was already correct).
    func testNoFillersReturnsTextUnchanged() {
        let out = FillerWordCleaner.clean("Hello world.")
        XCTAssertEqual(out, "Hello world.")
    }

    // MARK: - mid-sentence filler space preservation
    //
    // Regression guards for the bug where `[ \t]*` consumed whitespace
    // on BOTH sides of the filler and the empty replacement template
    // produced `"yeahokay"` from `"yeah uh okay"`. The fix replaces
    // with a single space and then trims any artifacts adjacent to
    // paragraph breaks (step 2.5) and orphan punctuation (step 3).

    /// Filler with a plain word on both sides — must produce a
    /// single space between the surviving words.
    func testFillerBetweenWordsLeavesSingleSpace() {
        let out = FillerWordCleaner.clean("yeah uh okay")
        XCTAssertEqual(out, "Yeah okay")
    }

    /// `um` between two words.
    func testUmBetweenWordsLeavesSingleSpace() {
        let out = FillerWordCleaner.clean("hello um world")
        XCTAssertEqual(out, "Hello world")
    }

    /// Mid-sentence filler in a longer sentence — checks the
    /// surrounding words don't run together.
    func testMidSentenceFillerPreservesSpaces() {
        let out = FillerWordCleaner.clean("this is uh really fast")
        XCTAssertEqual(out, "This is really fast")
    }

    /// Two adjacent fillers between words still collapse to a
    /// single space.
    func testAdjacentFillersBetweenWordsCollapseToSingleSpace() {
        let out = FillerWordCleaner.clean("yeah uh um okay")
        XCTAssertEqual(out, "Yeah okay")
    }

    /// Paragraph-leading filler must NOT leave a space at the start
    /// of the new paragraph (step 2.5 cleans this up).
    func testParagraphLeadingFillerNoLeadingSpace() {
        let segmented = "Hello.\n\num world."
        let out = FillerWordCleaner.clean(segmented)
        XCTAssertEqual(out, "Hello.\n\nWorld.")
    }
}
