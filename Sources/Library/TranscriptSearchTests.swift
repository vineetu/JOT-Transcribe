#if DEBUG
import Foundation

/// DEBUG-only runtime tests for `TranscriptSearch` — the pure find-in-transcript
/// logic (match enumeration across blocks + current-index stepping). Same
/// `assert()`-in-`#if DEBUG` idiom as the other in-app harnesses; runs once at
/// startup via `runAll()` and is stripped from release builds.
enum TranscriptSearchTests {

    static func runAll() {
        test_multiBlockOrdering()
        test_multipleMatchesInOneBlockInOrder()
        test_caseInsensitive()
        test_diacriticInsensitive()
        test_cjkContent()
        test_emptyQueryNoMatches()
        test_queryLongerThanTextNoMatches()
        test_stepWraparoundBothDirections()
        test_stepEmptyIsZero()
    }

    static func test_multiBlockOrdering() {
        let blocks = ["foo bar", "bar baz", "nothing here"]
        let m = TranscriptSearch.matches(query: "bar", in: blocks)
        assert(m.count == 2, "expected 2 matches, got \(m.count)")
        assert(m[0] == TranscriptSearch.Match(blockIndex: 0, range: NSRange(location: 4, length: 3)),
               "first match in block 0 at 4, got \(m[0])")
        assert(m[1] == TranscriptSearch.Match(blockIndex: 1, range: NSRange(location: 0, length: 3)),
               "second match in block 1 at 0, got \(m[1])")
    }

    static func test_multipleMatchesInOneBlockInOrder() {
        let m = TranscriptSearch.matches(query: "na", in: ["banana bandana"])
        // "banana" → offsets 2, 4 (overlap-free: match at 2 then resume at 4);
        // "bandana" → offset 12. All in one block, ascending.
        assert(m.map(\.range.location) == [2, 4, 12], "ascending positions, got \(m.map(\.range.location))")
        assert(m.allSatisfy { $0.blockIndex == 0 }, "all in block 0")
    }

    static func test_caseInsensitive() {
        let m = TranscriptSearch.matches(query: "BaR", in: ["the bar is open"])
        assert(m.count == 1 && m[0].range == NSRange(location: 4, length: 3),
               "case-insensitive single match at 4, got \(m)")
    }

    static func test_diacriticInsensitive() {
        // Query without accents must match accented text; the returned range
        // covers the ACTUAL matched substring ("résumé"), length 6 here.
        let m = TranscriptSearch.matches(query: "resume", in: ["My résumé is ready"])
        assert(m.count == 1, "expected 1 diacritic-insensitive match, got \(m.count)")
        assert((("My résumé is ready" as NSString).substring(with: m[0].range)) == "résumé",
               "range should cover 'résumé', got \(("My résumé is ready" as NSString).substring(with: m[0].range))")
        // And the reverse: accented query matches unaccented text.
        let m2 = TranscriptSearch.matches(query: "résumé", in: ["my resume"])
        assert(m2.count == 1, "accented query should match plain text, got \(m2.count)")
    }

    static func test_cjkContent() {
        let m = TranscriptSearch.matches(query: "ビネット", in: ["私はビネットです", "ビネット さん"])
        assert(m.count == 2, "expected 2 CJK matches, got \(m.count)")
        assert(m[0] == TranscriptSearch.Match(blockIndex: 0, range: NSRange(location: 2, length: 4)),
               "first at block 0 offset 2, got \(m[0])")
        assert(m[1].blockIndex == 1 && m[1].range.location == 0, "second at block 1 offset 0, got \(m[1])")
    }

    static func test_emptyQueryNoMatches() {
        assert(TranscriptSearch.matches(query: "", in: ["anything at all"]).isEmpty, "empty query → no matches")
    }

    static func test_queryLongerThanTextNoMatches() {
        assert(TranscriptSearch.matches(query: "supercalifragilistic", in: ["short"]).isEmpty,
               "query longer than text → no matches")
    }

    static func test_stepWraparoundBothDirections() {
        assert(TranscriptSearch.step(current: 0, count: 3, forward: true) == 1, "0→1 fwd")
        assert(TranscriptSearch.step(current: 2, count: 3, forward: true) == 0, "2→0 fwd wrap")
        assert(TranscriptSearch.step(current: 0, count: 3, forward: false) == 2, "0→2 back wrap")
        assert(TranscriptSearch.step(current: 2, count: 3, forward: false) == 1, "2→1 back")
        // A stale index beyond count normalizes.
        assert(TranscriptSearch.step(current: 9, count: 3, forward: true) == 1, "stale index normalizes (9%3=0→1)")
    }

    static func test_stepEmptyIsZero() {
        assert(TranscriptSearch.step(current: 5, count: 0, forward: true) == 0, "no matches → 0")
    }
}
#endif
