import XCTest
@testable import Jot

/// Unit tests for the post-transcription number normalizer. Pure
/// helper — no I/O, no model load.
final class NumberNormalizerTests: XCTestCase {

    // MARK: - Always-on rules (positive cases)

    func testCardinalGteTenConverts() {
        XCTAssertEqual(NumberNormalizer.normalize("fifteen pages"), "15 pages")
    }

    func testPercentConverts() {
        XCTAssertEqual(NumberNormalizer.normalize("twenty-five percent"), "25%")
    }

    func testMoneyDollarsConverts() {
        XCTAssertEqual(NumberNormalizer.normalize("fifty dollars"), "$50")
    }

    func testMoneyWithThousandsCommaConverts() {
        XCTAssertEqual(
            NumberNormalizer.normalize("twenty-five thousand dollars"),
            "$25,000"
        )
    }

    func testCompoundTimePM() {
        XCTAssertEqual(NumberNormalizer.normalize("five thirty PM"), "5:30 PM")
    }

    func testSubTenTimeAt() {
        XCTAssertEqual(NumberNormalizer.normalize("at four"), "at 4")
    }

    func testSubTenTimeAtWithMinutes() {
        XCTAssertEqual(NumberNormalizer.normalize("at four thirty"), "at 4:30")
    }

    func testSubTenTimeBy() {
        XCTAssertEqual(NumberNormalizer.normalize("by five"), "by 5")
    }

    func testYearNineteenNinetyEight() {
        XCTAssertEqual(NumberNormalizer.normalize("in nineteen ninety-eight"), "in 1998")
    }

    func testYearTwentyTwentySix() {
        XCTAssertEqual(NumberNormalizer.normalize("in twenty twenty-six"), "in 2026")
    }

    func testYearTwoThousandTwentySix() {
        XCTAssertEqual(NumberNormalizer.normalize("in two thousand twenty-six"), "in 2026")
    }

    func testAddressOhDigitSequence() {
        XCTAssertEqual(
            NumberNormalizer.normalize("apartment four oh seven"),
            "apartment 407"
        )
    }

    func testAddressCompoundCardinal() {
        XCTAssertEqual(
            NumberNormalizer.normalize("apartment two hundred and three"),
            "apartment 203"
        )
    }

    func testCardinalCompoundConverts() {
        XCTAssertEqual(
            NumberNormalizer.normalize("two hundred and thirty units"),
            "230 units"
        )
    }

    // MARK: - Idiom exception

    func testIdiomAThousandTimesUnchanged() {
        XCTAssertEqual(NumberNormalizer.normalize("a thousand times"), "a thousand times")
    }

    func testIdiomAMillionTimesUnchanged() {
        XCTAssertEqual(NumberNormalizer.normalize("a million times"), "a million times")
    }

    func testIdiomAHundredDraftsUnchanged() {
        XCTAssertEqual(NumberNormalizer.normalize("a hundred drafts"), "a hundred drafts")
    }

    func testIdiomOneHundredPercentOverrides() {
        XCTAssertEqual(NumberNormalizer.normalize("one hundred percent"), "100%")
    }

    func testIdiomAThousandDollarsOverrides() {
        XCTAssertEqual(NumberNormalizer.normalize("a thousand dollars"), "$1,000")
    }

    // MARK: - Article drop on compound cardinal emission (Gap 1)

    func testArticleDropAThousandAndTwenty() {
        XCTAssertEqual(
            NumberNormalizer.normalize("a thousand and twenty things"),
            "1,020 things"
        )
    }

    func testArticleDropOneHundredAndFifty() {
        XCTAssertEqual(
            NumberNormalizer.normalize("one hundred and fifty users"),
            "150 users"
        )
    }

    func testArticleDropAMillionAndOne() {
        // Updated for the top-priority million/billion/trillion
        // pass-through rule: any sequence containing "million" stays as
        // words, so the article is NOT dropped and no digits are emitted.
        XCTAssertEqual(
            NumberNormalizer.normalize("a million and one ways"),
            "a million and one ways"
        )
    }

    // MARK: - Million / billion / trillion pass-through

    func testMillionStandalonePassthrough() throws {
        XCTAssertEqual(NumberNormalizer.normalize("300 million"), "300 million")
    }

    func testTwoMillionUsersPassthrough() throws {
        XCTAssertEqual(NumberNormalizer.normalize("two million users"), "two million users")
    }

    func testTwentyFiveMillionDollarsPassthrough() throws {
        XCTAssertEqual(
            NumberNormalizer.normalize("twenty-five million dollars"),
            "twenty-five million dollars"
        )
    }

    func testFifteenMillionPassthrough() throws {
        XCTAssertEqual(NumberNormalizer.normalize("fifteen million"), "fifteen million")
    }

    func testTwoBillionPassthrough() throws {
        XCTAssertEqual(NumberNormalizer.normalize("two billion"), "two billion")
    }

    func testBareMillionPassthrough() throws {
        XCTAssertEqual(NumberNormalizer.normalize("million"), "million")
    }

    func testTrillionPassthrough() throws {
        XCTAssertEqual(
            NumberNormalizer.normalize("three trillion stars"),
            "three trillion stars"
        )
    }

    func testOneBillionDollarsPassthrough() throws {
        XCTAssertEqual(
            NumberNormalizer.normalize("one billion dollars"),
            "one billion dollars"
        )
    }

    // MARK: - Tens-ordinal combiner (Gap 2)

    func testTensOrdinalSplitTwentyThird() {
        XCTAssertEqual(
            NumberNormalizer.normalize("twenty third street"),
            "23rd street"
        )
    }

    func testTensOrdinalHyphenTwentyFirst() {
        XCTAssertEqual(
            NumberNormalizer.normalize("twenty-first floor"),
            "21st floor"
        )
    }

    func testTensOrdinalSplitThirtySecond() {
        XCTAssertEqual(
            NumberNormalizer.normalize("thirty second avenue"),
            "32nd avenue"
        )
    }

    func testTensOrdinalSplitNinetyNinth() {
        XCTAssertEqual(
            NumberNormalizer.normalize("ninety ninth percentile"),
            "99th percentile"
        )
    }

    func testTensOrdinalStandaloneTwentieth() {
        XCTAssertEqual(
            NumberNormalizer.normalize("twentieth century"),
            "20th century"
        )
    }

    func testTensOrdinalStandaloneThirtieth() {
        XCTAssertEqual(
            NumberNormalizer.normalize("thirtieth birthday"),
            "30th birthday"
        )
    }

    // MARK: - Skip / preserve rules

    func testOrdinalStaysAsWord() {
        // Tens+ones ordinal compounds NOW convert ("twenty-first" →
        // "21st"). Bare ones-ordinals like "first", "second", "third"
        // are still preserved (see testOnlyOrdinalsUnchanged).
        XCTAssertEqual(
            NumberNormalizer.normalize("twenty-first street"),
            "21st street"
        )
    }

    func testSubTenWithoutOverrideStays() {
        XCTAssertEqual(
            NumberNormalizer.normalize("my son turned eight"),
            "my son turned eight"
        )
    }

    func testAlmostTwelveConverts() {
        XCTAssertEqual(NumberNormalizer.normalize("almost twelve"), "almost 12")
    }

    func testSentenceInitialConverts() {
        XCTAssertEqual(
            NumberNormalizer.normalize("Twenty five new sign-ups today"),
            "25 new sign-ups today"
        )
    }

    func testBareCardinalGteTenConverts() {
        XCTAssertEqual(NumberNormalizer.normalize("I made twenty-five"), "I made 25")
    }

    func testPhoneShapeUnchanged() {
        let input = "eight hundred five five five one two three four"
        XCTAssertEqual(NumberNormalizer.normalize(input), input)
    }

    func testTenYearsConverts() {
        XCTAssertEqual(
            NumberNormalizer.normalize("Looking back over the past ten years"),
            "Looking back over the past 10 years"
        )
    }

    func testMixedStyleAccepted() {
        XCTAssertEqual(
            NumberNormalizer.normalize("I read fifteen pages and reviewed three pull requests"),
            "I read 15 pages and reviewed three pull requests"
        )
    }

    // MARK: - Paragraph + punctuation preservation

    func testParagraphBreakPreserved() {
        XCTAssertEqual(
            NumberNormalizer.normalize("abc.\n\nfifteen things"),
            "abc.\n\n15 things"
        )
    }

    func testPunctuationPreserved() {
        XCTAssertEqual(
            NumberNormalizer.normalize("fifteen, twenty, twenty-five"),
            "15, 20, 25"
        )
    }

    func testCentsRuleAppliesToSubTen() {
        XCTAssertEqual(NumberNormalizer.normalize("I have eight cents"), "I have 8¢")
    }

    // MARK: - Negative tests (no-numbers / no-convertible-content)

    func testEmptyInputUnchanged() {
        XCTAssertEqual(NumberNormalizer.normalize(""), "")
    }

    func testNoNumbersUnchanged() {
        let input = "The quick brown fox jumps over the lazy dog."
        XCTAssertEqual(NumberNormalizer.normalize(input), input)
    }

    func testOnlyOrdinalsUnchanged() {
        let input = "First and second and third."
        XCTAssertEqual(NumberNormalizer.normalize(input), input)
    }

    func testOnlySubTenCardinalsUnchanged() {
        let input = "I have two cats and three dogs."
        XCTAssertEqual(NumberNormalizer.normalize(input), input)
    }
}
