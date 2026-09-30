#if DEBUG
import Foundation

/// DEBUG-only runtime tests for `SpeakerTimelineTextEdit` — carrying the stored
/// speaker-timeline segments across an edit of the canonical transcript (the
/// engine behind keeping the plain transcript and the speaker-labeled view in
/// sync). Same `assert()`-in-`#if DEBUG` idiom as `SpeakerTimelineTests`; runs
/// once at startup via `runAll()` and is stripped from release builds.
enum SpeakerTimelineTextEditTests {

    static func runAll() {
        test_rangeHint_replacesInFirstSegment()
        test_rangeHint_replacesInMiddleAndLastSegment()
        test_rangeHint_sameWordTwoSegments_rangeDisambiguates()
        test_rangeHint_newlineJoinPicksPreciseSegment()
        test_rangeHint_sameWordTwoSegments_newlineJoinDisambiguates()
        test_rangeHint_boundarySpanningSelectionGoesToEarlierSegment()
        test_alignmentFailure_leavesSegmentsAlone()
        test_handEdit_followsEachChangeIntoItsSegment()
        test_handEdit_textTypedAtTurnEdgesJoinsThatTurn()
        test_displayRunStoredIndices_groupsAndDropsEmpties()
        test_coalescedBlock_scopesToCorrectConstituentSegment()
        // Review round — skew guard, anchored splice mapper, CJK, edges.
        test_alignment_wordAnchoredSkipsInsideLongerWord()
        test_rangeHint_positionZeroOfFirstSegment()
        test_alignment_withinSegmentDoubleSpaceAborts()
        test_transcriptRange_mapsLocalRangeAcrossRepeatedSegments()
        test_cjk_rangeHintPicksSegment()
    }

    // MARK: - Helpers

    private static func seg(_ label: String, _ text: String,
                           _ start: Double = 0, _ end: Double = 1) -> SpeakerTimelineSegment {
        SpeakerTimelineSegment(speakerLabel: label, startSec: start, endSec: end, text: text)
    }

    /// The span replacement `RecordingTextMutation` makes: `range` in
    /// `reference` becomes `replacement`, segments carried across.
    private static func replacing(
        _ segments: [SpeakerTimelineSegment], range: NSRange, with replacement: String,
        in reference: String
    ) -> [SpeakerTimelineSegment]? {
        let new = (reference as NSString).replacingCharacters(in: range, with: replacement)
        return SpeakerTimelineTextEdit.projected(
            segments, from: reference, to: new,
            map: TextOffsetMap(old: reference, replacing: range, with: replacement))
    }

    /// A whole-text (hand) edit `reference` → `new`, carried by diff.
    private static func editing(
        _ segments: [SpeakerTimelineSegment], from reference: String, to new: String
    ) -> [SpeakerTimelineSegment]? {
        SpeakerTimelineTextEdit.projected(
            segments, from: reference, to: new, map: TextOffsetMap(old: reference, new: new))
    }

    // MARK: - Range-hint (precise) path

    static func test_rangeHint_replacesInFirstSegment() {
        let segments = [seg("S1", "hello vineet how are you"), seg("S2", "i am vineet too")]
        let joined = segments.map(\.text).joined(separator: " ")
        // First "vineet" starts at offset 6 in the joined layout.
        let out = replacing(segments, range: NSRange(location: 6, length: 6), with: "Vineet", in: joined)
        assert(out != nil, "expected a successful edit")
        assert(out?[0].text == "hello Vineet how are you", "first segment should be edited, got \(out?[0].text ?? "nil")")
        assert(out?[1].text == "i am vineet too", "second segment must be untouched")
    }

    static func test_rangeHint_replacesInMiddleAndLastSegment() {
        let segments = [seg("A", "the cat sat"), seg("B", "on the mat"), seg("C", "near the dog")]
        let joined = segments.map(\.text).joined(separator: " ")
        // "mat" is at offset 19 (middle segment).
        let mid = replacing(segments, range: NSRange(location: 19, length: 3), with: "Mat", in: joined)
        assert(mid?[1].text == "on the Mat", "middle segment should be edited, got \(mid?[1].text ?? "nil")")
        assert(mid?[0].text == "the cat sat" && mid?[2].text == "near the dog", "other segments untouched")
        // "dog" is at offset 32 (last segment).
        let last = replacing(segments, range: NSRange(location: 32, length: 3), with: "Dog", in: joined)
        assert(last?[2].text == "near the Dog", "last segment should be edited, got \(last?[2].text ?? "nil")")
        assert(last?[0].text == "the cat sat" && last?[1].text == "on the mat", "other segments untouched")
    }

    static func test_rangeHint_sameWordTwoSegments_rangeDisambiguates() {
        let segments = [seg("A", "call vineet now"), seg("B", "vineet again")]
        let joined = segments.map(\.text).joined(separator: " ")
        // Two "vineet" occurrences: offset 5 (segment A) and offset 16 (segment B).
        let a = replacing(segments, range: NSRange(location: 5, length: 6), with: "Vineet", in: joined)
        assert(a?[0].text == "call Vineet now", "range in A must edit A, got \(a?[0].text ?? "nil")")
        assert(a?[1].text == "vineet again", "B must be untouched when A is selected")

        let b = replacing(segments, range: NSRange(location: 16, length: 6), with: "Vineet", in: joined)
        assert(b?[1].text == "Vineet again", "range in B must edit B, got \(b?[1].text ?? "nil")")
        assert(b?[0].text == "call vineet now", "A must be untouched when B is selected")
    }

    static func test_rangeHint_newlineJoinPicksPreciseSegment() {
        // The common case that USED to fall back: the transcript joins the
        // segment texts with a paragraph break (\n\n), not a single space, so
        // exact-equality would fail — but sequential alignment locates each
        // segment and the range hint picks the precise one.
        let segments = [seg("S1", "hello vineet"), seg("S2", "goodbye vineet")]
        let reference = "hello vineet\n\ngoodbye vineet"
        // Second "vineet" (segment 2) starts at offset 22 in `reference`.
        let out = replacing(segments, range: NSRange(location: 22, length: 6), with: "Vineet", in: reference)
        assert(out?[1].text == "goodbye Vineet", "newline-join hint should edit segment 2, got \(out?[1].text ?? "nil")")
        assert(out?[0].text == "hello vineet", "segment 1 must be untouched (this is the case that used to mis-fall-back)")
    }

    static func test_rangeHint_sameWordTwoSegments_newlineJoinDisambiguates() {
        let segments = [seg("A", "call vineet"), seg("B", "vineet again")]
        let reference = "call vineet\n\nvineet again"
        // "vineet": offset 5 (segment A) and offset 13 (segment B, after \n\n).
        let a = replacing(segments, range: NSRange(location: 5, length: 6), with: "Vineet", in: reference)
        assert(a?[0].text == "call Vineet", "newline-join range in A must edit A, got \(a?[0].text ?? "nil")")
        assert(a?[1].text == "vineet again", "B untouched when A selected")

        let b = replacing(segments, range: NSRange(location: 13, length: 6), with: "Vineet", in: reference)
        assert(b?[1].text == "Vineet again", "newline-join range in B must edit B, got \(b?[1].text ?? "nil")")
        assert(b?[0].text == "call vineet", "A untouched when B selected")
    }

    static func test_alignmentFailure_leavesSegmentsAlone() {
        // The transcript was already hand-edited away from the segments, so
        // they no longer align → nil (the caller keeps them as they are
        // instead of guessing where the edit belongs).
        let segments = [seg("A", "hello vineet"), seg("B", "world vineet")]
        let reference = "hello EDITED and rewrapped\n\nworld vineet"
        let out = replacing(segments, range: NSRange(location: 34, length: 6), with: "Vineet", in: reference)
        assert(out == nil, "diverged segments must not be guessed at")
    }

    static func test_rangeHint_boundarySpanningSelectionGoesToEarlierSegment() {
        let segments = [seg("A", "call vineet now"), seg("B", "vineet again")]
        let joined = segments.map(\.text).joined(separator: " ")
        // "now vineet" (offset 12, length 10) starts in A and crosses into B:
        // the replacement lands once, in A, and B keeps what's left of it.
        let out = replacing(segments, range: NSRange(location: 12, length: 10), with: "X", in: joined)
        assert(out?[0].text == "call vineet X", "straddling replacement joins A, got \(out?[0].text ?? "nil")")
        assert(out?[1].text == "again", "B keeps its unedited remainder, got \(out?[1].text ?? "nil")")
    }

    // MARK: - Whole-text (hand) edits

    static func test_handEdit_followsEachChangeIntoItsSegment() {
        let segments = [seg("A", "we met jamie today"), seg("B", "and jamie said hi")]
        let reference = "we met jamie today\n\nand jamie said hi"
        let out = editing(segments, from: reference, to: "we met Jamy yesterday\n\nand Jamy said hello")
        assert(out?[0].text == "we met Jamy yesterday", "A carries both of its edits, got \(out?[0].text ?? "nil")")
        assert(out?[1].text == "and Jamy said hello", "B carries its edits, got \(out?[1].text ?? "nil")")
        assert(out?.map(\.speakerLabel) == ["A", "B"], "labels never change")
    }

    static func test_handEdit_textTypedAtTurnEdgesJoinsThatTurn() {
        let segments = [seg("A", "first turn"), seg("B", "second turn")]
        let reference = "first turn\n\nsecond turn"
        let appended = editing(segments, from: reference, to: "first turn, really\n\nsecond turn")
        assert(appended?[0].text == "first turn, really", "text typed at A's tail joins A, got \(appended?[0].text ?? "nil")")
        assert(appended?[1].text == "second turn", "B untouched")
        let prefixed = editing(segments, from: reference, to: "first turn\n\nOK, second turn")
        assert(prefixed?[1].text == "OK, second turn", "text typed at B's head joins B, got \(prefixed?[1].text ?? "nil")")
        assert(prefixed?[0].text == "first turn", "A untouched")
        let deleted = editing(segments, from: reference, to: "first\n\nsecond turn")
        assert(deleted?[0].text == "first", "deleted text leaves A, got \(deleted?[0].text ?? "nil")")
    }

    // MARK: - Display-run grouping + block scoping

    static func test_displayRunStoredIndices_groupsAndDropsEmpties() {
        let segments = [
            seg("S1", "one two"),      // 0
            seg("S1", "three four"),   // 1  same label → same block as 0
            seg("S2", "five six"),     // 2
            seg("S1", ""),             // 3  empty → dropped
            seg("S2", "seven"),        // 4  consecutive-with-2 after the empty drop
        ]
        let groups = SpeakerTimelineTextEdit.displayRunStoredIndices(segments)
        assert(groups == [[0, 1], [2, 4]], "grouping should merge same-label + drop empties, got \(groups)")
        // Must parallel coalesceDisplayRuns exactly.
        let blocks = SpeakerTimelineBuilder.coalesceDisplayRuns(segments)
        assert(blocks.count == groups.count, "one group per display block")
        assert(blocks[0].text == "one two three four", "block 0 text, got \(blocks[0].text)")
        assert(blocks[1].text == "five six seven", "block 1 text, got \(blocks[1].text)")
    }

    // MARK: - Review round: skew guard (Fix 2)

    static func test_alignment_wordAnchoredSkipsInsideLongerWord() {
        // Segment "yes" must align to the STANDALONE "yes", not the "yes" inside
        // "yesterday". Fails before word-anchoring (old code took the first
        // substring match at offset 7); passes after.
        let segments = [seg("A", "I said"), seg("B", "yes")]
        let ranges = SpeakerTimelineTextEdit.alignedSegmentRanges(segments, in: "I said yesterday yes")
        assert(ranges?[1] == NSRange(location: 17, length: 3),
               "segment 'yes' must anchor to the standalone occurrence, got \(String(describing: ranges?[1]))")
        // End-to-end: a hint on the standalone "yes" edits segment B.
        let out = replacing(segments, range: NSRange(location: 17, length: 3), with: "YES",
                            in: "I said yesterday yes")
        assert(out?[1].text == "YES", "hint on the real 'yes' should edit B, got \(out?[1].text ?? "nil")")
    }

    // MARK: - Review round: edges (Fix 5c/d)

    static func test_rangeHint_positionZeroOfFirstSegment() {
        let segments = [seg("A", "vineet speaks"), seg("B", "hello")]
        let reference = segments.map(\.text).joined(separator: " ")
        // "vineet" at absolute offset 0 — before-edge boundary is the string start.
        let out = replacing(segments, range: NSRange(location: 0, length: 6), with: "Vineet", in: reference)
        assert(out?[0].text == "Vineet speaks", "position-0 hint should edit segment A, got \(out?[0].text ?? "nil")")
        assert(out?[1].text == "hello", "segment B untouched")
    }

    static func test_alignment_withinSegmentDoubleSpaceAborts() {
        // A double space INSIDE segment A's span (a within-segment re-flow) means
        // "hello world" isn't found verbatim → alignment aborts (all-or-nothing)
        // → the segments are left alone. Documents the accepted limitation.
        let segments = [seg("A", "hello world"), seg("B", "foo bar")]
        let reference = "hello  world foo bar"   // two spaces inside A
        assert(SpeakerTimelineTextEdit.alignedSegmentRanges(segments, in: reference) == nil,
               "within-segment double space must abort alignment")
        let out = replacing(segments, range: NSRange(location: 7, length: 5), with: "World", in: reference)
        assert(out == nil, "alignment abort leaves the segments alone")
    }

    // MARK: - Review round: anchored transcript-range mapper (Fix 5e)

    static func test_transcriptRange_mapsLocalRangeAcrossRepeatedSegments() {
        // Two VERBATIM-identical segments. The mapper must anchor each segment's
        // local range to that segment's OWN occurrence in the transcript — this is
        // the speaker→plain bug fix (same word in two speakers must not collapse
        // onto occurrence 1).
        let segments = [seg("A", "call vineet"), seg("B", "call vineet")]
        let transcript = "call vineet\n\ncall vineet"
        // "vineet" is local range (5,6) within EACH segment.
        let t0 = SpeakerTimelineTextEdit.transcriptRange(
            forSegmentIndex: 0, localRange: NSRange(location: 5, length: 6),
            segments: segments, transcript: transcript)
        assert(t0 == NSRange(location: 5, length: 6), "segment 0 → first occurrence, got \(String(describing: t0))")
        let t1 = SpeakerTimelineTextEdit.transcriptRange(
            forSegmentIndex: 1, localRange: NSRange(location: 5, length: 6),
            segments: segments, transcript: transcript)
        assert(t1 == NSRange(location: 18, length: 6), "segment 1 → SECOND occurrence, got \(String(describing: t1))")
        // Sanity: the mapped range actually covers "vineet" in the transcript.
        assert((transcript as NSString).substring(with: t1!) == "vineet", "mapped range must cover the word")
    }

    // MARK: - Review round: spaceless-script (CJK) support (Fix 3 / 5a)

    static func test_cjk_rangeHintPicksSegment() {
        // Two "ビネット" occurrences across two Japanese segments; the range hint
        // disambiguates even though the text has no spaces.
        let segments = [seg("S1", "私はビネット"), seg("S2", "ビネットです")]
        let reference = "私はビネット\n\nビネットです"
        // First "ビネット" is at UTF-16 offset 2 (after 私は).
        let a = replacing(segments, range: NSRange(location: 2, length: 4), with: "Vineet", in: reference)
        assert(a?[0].text == "私はVineet", "hint in S1 should edit S1, got \(a?[0].text ?? "nil")")
        assert(a?[1].text == "ビネットです", "S2 untouched")
        // Second "ビネット" is at offset 8 (after the \n\n).
        let b = replacing(segments, range: NSRange(location: 8, length: 4), with: "Vineet", in: reference)
        assert(b?[1].text == "Vineetです", "hint in S2 should edit S2, got \(b?[1].text ?? "nil")")
        assert(b?[0].text == "私はビネット", "S1 untouched")
    }

    static func test_coalescedBlock_scopesToCorrectConstituentSegment() {
        let segments = [
            seg("S1", "one two"),      // 0
            seg("S2", "five six"),     // 2-analog constituent 0 of block
            seg("S2", "seven"),        // constituent 1 of block
        ]
        // Simulate the UI's block-scoped call: constituents of the S2 block.
        let blockStored = [segments[1], segments[2]]
        let blockText = SpeakerTimelineBuilder.coalesceDisplayRuns([segments[1], segments[2]])[0].text
        assert(blockText == "five six seven", "block text sanity, got \(blockText)")
        // "seven" at offset 9 in the block → must edit the SECOND constituent only.
        let out = replacing(blockStored, range: NSRange(location: 9, length: 5), with: "Seven", in: blockText)
        assert(out?[0].text == "five six", "first constituent untouched, got \(out?[0].text ?? "nil")")
        assert(out?[1].text == "Seven", "second constituent edited, got \(out?[1].text ?? "nil")")
    }
}
#endif
