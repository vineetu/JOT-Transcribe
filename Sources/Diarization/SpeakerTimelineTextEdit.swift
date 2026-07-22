import Foundation

/// Pure, UI-free propagation of a single vocab replacement into the STORED
/// speaker-timeline segments, so a "Add to Vocabulary…" replace made in one
/// view (the canonical plain transcript, or a speaker block) stays consistent
/// with the other. No SwiftData, no AppKit — fed the decoded payload segments
/// and the edit, returns updated segments (or `nil` when the edit can't be
/// cleanly localized to exactly ONE stored segment).
///
/// The canonical plain-transcript splice (`RecordingDetailView.applyVocabReplacement`)
/// is RANGE-based and single-occurrence: it replaces the exact selected UTF-16
/// `NSRange` with the term. This helper mirrors that where it can (the range-hint
/// path) and otherwise degrades to a word-boundary-safe first-occurrence search
/// — never a "replace all", never a cross-segment edit.
enum SpeakerTimelineTextEdit {

    /// Where a reference-range maps to: which segment (index into the array it was
    /// located against) and the local UTF-16 range within that segment's `text`.
    /// Shared so BOTH directions (timeline edit + anchored transcript edit) splice
    /// the SAME instance.
    struct SegmentHit: Equatable {
        let segmentIndex: Int
        let localRange: NSRange
    }

    /// Apply a single-occurrence replacement to the ONE stored segment that
    /// contains the user's selection. `segments` is the array to edit — either
    /// the full stored payload (plain-view → timeline) or a single display
    /// block's constituent stored segments (speaker-view → timeline). Returns a
    /// same-shaped array with exactly one segment's `text` changed, or `nil`
    /// when the edit can't be localized (selection straddles a segment boundary,
    /// or — in the fallback — the phrase isn't found).
    ///
    /// Strategy, in order:
    ///  1. **Range-hint (precise), via sequential alignment.** When `range` is
    ///     non-nil, locate each segment's `text` inside `referenceText` IN ORDER
    ///     (segment `i` searched from the end of segment `i-1`'s match; the
    ///     separators between matches can be anything — single spaces, the `\n\n`
    ///     ParagraphSegmenter inserts, etc.). Matches are word-anchored so a short
    ///     segment ("yes") can't align inside a longer word ("yesterday"). Any
    ///     unedited diarized transcript aligns, because it was BUILT by joining
    ///     these very texts. Alignment is ALL-OR-NOTHING: if any segment fails to
    ///     match in order it aborts to the fallback (never a partial/wrong map).
    ///     On success the `range` is AUTHORITATIVE — it lands inside exactly one
    ///     segment (edit it) or straddles a boundary / falls in a separator
    ///     (⇒ `nil`, no fuzzy fallback). This disambiguates the same word in two
    ///     segments.
    ///  2. **Fallback (word-boundary search).** When there is no `range`, or
    ///     sequential alignment fails (the user hand-edited the transcript so it
    ///     no longer contains the segment texts), replace the FIRST whole-word
    ///     occurrence of `selectedText` in the FIRST segment that contains it. No
    ///     containing segment ⇒ `nil` (views may stay diverged in that
    ///     already-diverged case — acceptable per design).
    static func applyingReplacement(
        to segments: [SpeakerTimelineSegment],
        selectedText: String,
        replacement: String,
        range: NSRange? = nil,
        referenceText: String? = nil
    ) -> [SpeakerTimelineSegment]? {
        guard !segments.isEmpty else { return nil }

        // Path 1 — precise range hint via sequential alignment. When alignment
        // SUCCEEDS the range is authoritative: a straddle/miss returns nil with NO
        // fuzzy fallback (that would mis-replace elsewhere). Only a FAILED
        // alignment (diverged reference) falls through to the search.
        if let range, let referenceText,
           let segmentRanges = alignedSegmentRanges(segments, in: referenceText) {
            guard let hit = locateHit(range, segmentRanges: segmentRanges) else { return nil }
            return spliced(segments, at: hit, replacement: replacement)
        }

        // Path 2 — word-boundary first-occurrence search.
        guard !selectedText.isEmpty else { return nil }
        for (i, seg) in segments.enumerated() {
            if let newText = replacingFirstWholeWord(selectedText, with: replacement, in: seg.text) {
                var updated = segments
                updated[i] = seg.withText(newText)
                return updated
            }
        }
        return nil
    }

    /// Locate the single segment + local range a `range` in `referenceText` maps
    /// to, via sequential alignment. `nil` when alignment fails OR the range
    /// straddles a boundary / misses. Exposed so the speaker-view path can find
    /// the exact stored segment + local offset it edited, then anchor the SAME
    /// instance in the canonical transcript (via `transcriptRange`).
    static func locate(
        range: NSRange, in segments: [SpeakerTimelineSegment], referenceText: String
    ) -> SegmentHit? {
        guard let segmentRanges = alignedSegmentRanges(segments, in: referenceText) else { return nil }
        return locateHit(range, segmentRanges: segmentRanges)
    }

    /// The `NSRange` in `transcript` covering `localRange` within stored segment
    /// `index`, via sequential alignment of ALL `segments` against `transcript`.
    /// `nil` if alignment fails, the segment is empty, or the local range overruns
    /// the segment. Lets a speaker-block edit anchor the exact same instance in
    /// the canonical transcript instead of guessing the first whole-word match.
    static func transcriptRange(
        forSegmentIndex index: Int, localRange: NSRange,
        segments: [SpeakerTimelineSegment], transcript: String
    ) -> NSRange? {
        guard index >= 0, index < segments.count,
              localRange.location >= 0, localRange.length > 0 else { return nil }
        guard let ranges = alignedSegmentRanges(segments, in: transcript) else { return nil }
        let segRange = ranges[index]
        guard segRange.length > 0,
              localRange.location + localRange.length <= segRange.length else { return nil }
        return NSRange(location: segRange.location + localRange.location, length: localRange.length)
    }

    /// Locate each segment's `text` in `referenceText` in document order —
    /// segment `i` searched from the end of segment `i-1`'s match, so the
    /// separators between matches (spaces, `\n\n`, anything the post-gate
    /// transform chain inserted BETWEEN turns) are ignored. Each match is
    /// WORD-ANCHORED (outer edges on a word boundary) so a short segment can't
    /// coincidentally align inside a longer word — the search keeps scanning past
    /// an inside-a-word hit. Returns the per-segment `NSRange`s in `referenceText`
    /// coordinates, or `nil` if ANY segment fails to match in order (all-or-
    /// nothing — a partial map is never returned, so a within-segment re-flow
    /// safely aborts to the fuzzy fallback). Empty-text segments occupy a zero-
    /// length range at the cursor and never own a (length > 0) hit.
    static func alignedSegmentRanges(
        _ segments: [SpeakerTimelineSegment],
        in referenceText: String
    ) -> [NSRange]? {
        let refNS = referenceText as NSString
        var ranges: [NSRange] = []
        ranges.reserveCapacity(segments.count)
        var cursor = 0
        for seg in segments {
            let segNS = seg.text as NSString
            if segNS.length == 0 {
                ranges.append(NSRange(location: cursor, length: 0))
                continue
            }
            var searchFrom = cursor
            var matched: NSRange?
            while searchFrom <= refNS.length {
                let found = refNS.range(
                    of: seg.text, options: [],
                    range: NSRange(location: searchFrom, length: refNS.length - searchFrom))
                guard found.location != NSNotFound else { break }
                if isWordAnchored(found, in: refNS) {
                    matched = found
                    break
                }
                // Coincidental match inside a larger word — keep scanning.
                searchFrom = found.location + 1
            }
            guard let m = matched else { return nil }
            ranges.append(m)
            cursor = m.location + m.length
        }
        return ranges
    }

    /// Replace the FIRST whole-word occurrence of `find` with `replacement` in
    /// `text` (single occurrence, case-sensitive, word-boundary-safe on both
    /// outer edges so "Ann" never matches inside "Announcement"). Returns the new
    /// string, or `nil` if `find` never occurs on a word boundary. Shared by the
    /// segment fallback above and the canonical-transcript splice on the
    /// speaker-view path when transcript alignment fails.
    static func replacingFirstWholeWord(_ find: String, with replacement: String, in text: String) -> String? {
        guard !find.isEmpty else { return nil }
        let ns = text as NSString
        let findLen = (find as NSString).length
        guard findLen > 0, ns.length >= findLen else { return nil }

        var searchStart = 0
        while searchStart <= ns.length - findLen {
            let found = ns.range(
                of: find, options: [],
                range: NSRange(location: searchStart, length: ns.length - searchStart))
            guard found.location != NSNotFound else { return nil }
            if isWordAnchored(found, in: ns) {
                return ns.replacingCharacters(in: found, with: replacement)
            }
            searchStart = found.location + 1
        }
        return nil
    }

    /// The stored-segment indices that make up each coalesced DISPLAY block, in
    /// the SAME grouping `SpeakerTimelineBuilder.coalesceDisplayRuns` uses
    /// (consecutive same-label segments, empty-text ones dropped). So
    /// `coalesceDisplayRuns(segments)[i]` is exactly the block built from
    /// `displayRunStoredIndices(segments)[i]`. Lets a speaker-block edit map back
    /// to the precise stored segment(s) to mutate.
    static func displayRunStoredIndices(_ segments: [SpeakerTimelineSegment]) -> [[Int]] {
        var out: [[Int]] = []
        for (i, seg) in segments.enumerated() {
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let lastGroup = out.last, let lastIndex = lastGroup.last,
               segments[lastIndex].speakerLabel == seg.speakerLabel {
                out[out.count - 1].append(i)
            } else {
                out.append([i])
            }
        }
        return out
    }

    // MARK: - Internals

    /// Find the one segment whose aligned range fully contains `range` and return
    /// the hit (segment index + local range). `nil` when the range straddles a
    /// boundary, lands in a separator, or is out of range.
    private static func locateHit(_ range: NSRange, segmentRanges: [NSRange]) -> SegmentHit? {
        guard range.location >= 0, range.length > 0 else { return nil }
        for (i, segRange) in segmentRanges.enumerated() where segRange.length > 0 {
            let segStart = segRange.location
            let segEnd = segRange.location + segRange.length
            // Fully inside this segment (equality at both ends allowed).
            if range.location >= segStart, range.location + range.length <= segEnd {
                return SegmentHit(
                    segmentIndex: i,
                    localRange: NSRange(location: range.location - segStart, length: range.length))
            }
            // Starts inside this segment but extends past its end ⇒ straddles a
            // boundary; no single stored segment owns it.
            if range.location >= segStart, range.location < segEnd {
                return nil
            }
        }
        return nil
    }

    /// Apply a located hit: splice `replacement` over `localRange` in the hit
    /// segment's text.
    private static func spliced(
        _ segments: [SpeakerTimelineSegment], at hit: SegmentHit, replacement: String
    ) -> [SpeakerTimelineSegment] {
        var updated = segments
        let segNS = segments[hit.segmentIndex].text as NSString
        updated[hit.segmentIndex] = segments[hit.segmentIndex]
            .withText(segNS.replacingCharacters(in: hit.localRange, with: replacement))
        return updated
    }

    /// Whether `range`'s outer edges sit on word boundaries in `ns` (adjacent
    /// char is a non-word char or the string boundary).
    private static func isWordAnchored(_ range: NSRange, in ns: NSString) -> Bool {
        let beforeIsBoundary = range.location == 0
            || !isWordCharacter(ns.character(at: range.location - 1))
        let afterIndex = range.location + range.length
        let afterIsBoundary = afterIndex >= ns.length
            || !isWordCharacter(ns.character(at: afterIndex))
        return beforeIsBoundary && afterIsBoundary
    }

    /// Whether a UTF-16 code unit is part of a word (letter or number) for the
    /// word-boundary test — anything else (space, punctuation, quotes) is a
    /// boundary. Spaceless scripts (Han, Hiragana, Katakana, Hangul, Thai) are
    /// treated as NON-word so each ideograph counts as a boundary: without this,
    /// a term flanked by ideographs (Japanese/Chinese) would have no boundary on
    /// either side and never match, silently one-siding the sync. (Latin-in-CJK
    /// like "Jot" between ideographs then matches, which is correct.)
    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        if isSpacelessScript(scalar) { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// Scripts written without spaces between words, where a per-character
    /// boundary is the correct model for whole-"word" matching.
    private static func isSpacelessScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana + Katakana
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xAC00...0xD7AF,   // Hangul Syllables
             0x1100...0x11FF,   // Hangul Jamo
             0x0E00...0x0E7F:   // Thai
            return true
        default:
            return false
        }
    }
}

private extension SpeakerTimelineSegment {
    /// Copy carrying a new `text`, preserving label + time bounds.
    func withText(_ newText: String) -> SpeakerTimelineSegment {
        SpeakerTimelineSegment(
            speakerLabel: speakerLabel, startSec: startSec, endSec: endSec, text: newText)
    }
}
