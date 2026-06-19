import XCTest
@testable import Jot

/// Japanese live-preview wiring tests
/// (`docs/batch-pseudo-streaming/japanese-preview.md`).
///
/// Covers the two pure, deterministic pieces of the JA-preview change:
/// 1. `LanguageChoice.isSpaceless` — `true` only for CJK / space-free scripts
///    (Japanese today), `false` for every Latin / Cyrillic / Greek language.
/// 2. `PreviewScheduler.join(_:_:spaceless:)` — the preview-only string
///    assembly that glues the committed tail to the volatile tail WITHOUT a
///    separator when the language is spaceless, so the JA pill preview shows no
///    spurious inter-word gaps at window boundaries.
///
/// The factory routing (JA → `DualPipelineTranscriber(batch:batchPreview:)`)
/// is compile-verified (`JotComposition.transcriberFactory`) and exercised at
/// runtime by the user's real-audio testing; it is not unit-tested here because
/// the production factory closure is private to `JotComposition.build`.
final class JapanesePreviewTests: XCTestCase {

    // MARK: - LanguageChoice.isSpaceless

    func testJapaneseIsSpaceless() {
        XCTAssertTrue(LanguageChoice.japanese.isSpaceless)
    }

    func testEnglishIsNotSpaceless() {
        XCTAssertFalse(LanguageChoice.english.isSpaceless)
    }

    /// Exhaustive: Japanese is the ONLY spaceless language today; every other
    /// surfaced language (Latin, Cyrillic, Greek) is space-delimited. Iterating
    /// `allCases` means a future spaceless language (Chinese / Korean) added
    /// without updating this expectation would surface here.
    func testOnlyJapaneseIsSpaceless() {
        for choice in LanguageChoice.allCases {
            if choice == .japanese {
                XCTAssertTrue(choice.isSpaceless, "\(choice) should be spaceless")
            } else {
                XCTAssertFalse(choice.isSpaceless, "\(choice) should not be spaceless")
            }
        }
    }

    // MARK: - PreviewScheduler.join spaceless behavior

    func testJoinSpacelessConcatenatesWithoutSeparator() {
        // Japanese: no inter-word space at the window boundary.
        let joined = PreviewScheduler.join("今日は", "いい天気", spaceless: true)
        XCTAssertEqual(joined, "今日はいい天気")
    }

    func testJoinSpacedInsertsSingleSeparator() {
        let joined = PreviewScheduler.join("hello", "world", spaceless: false)
        XCTAssertEqual(joined, "hello world")
    }

    func testJoinSpacelessTrimsWhitespaceFromBothSides() {
        // Stray whitespace from a tick's text must not survive into the
        // spaceless join (else the gap-removal is defeated).
        let joined = PreviewScheduler.join("  今日は  ", "  いい天気 ", spaceless: true)
        XCTAssertEqual(joined, "今日はいい天気")
    }

    func testJoinEmptyLeftReturnsRightOnly() {
        XCTAssertEqual(PreviewScheduler.join("", "いい天気", spaceless: true), "いい天気")
        XCTAssertEqual(PreviewScheduler.join("", "world", spaceless: false), "world")
    }

    func testJoinEmptyRightReturnsLeftOnly() {
        XCTAssertEqual(PreviewScheduler.join("今日は", "", spaceless: true), "今日は")
        XCTAssertEqual(PreviewScheduler.join("hello", "", spaceless: false), "hello")
    }
}
