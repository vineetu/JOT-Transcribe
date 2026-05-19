import Foundation

/// Sub-sequence fuzzy matcher with gap penalty — same family as the
/// VS Code command-palette algorithm called out in
/// `docs/plans/prompt-picker-ux.md` §4.
///
/// The score is a value in [0, 1] (or `nil` when no match). Returns the
/// matched character ranges so the UI can render them with full
/// `.primary` foreground while the rest of the title dims to `.secondary`.
enum FuzzyMatcher {
    struct Match {
        /// 0.0 means "every match character is at the very end of the haystack
        /// with maximum gaps." 1.0 is an exact prefix-anchored match with
        /// zero gaps.
        let score: Double
        /// Indexes (in the haystack) of the characters that contributed to
        /// the match. Used by the UI to highlight matched characters.
        let ranges: [Int]
    }

    /// Returns a match if every character of `query` appears in
    /// `haystack`, in order. Case-insensitive. Returns `nil` if `query`
    /// is empty (let the caller treat empty-query as "show all" rather
    /// than "match nothing").
    static func match(_ query: String, in haystack: String) -> Match? {
        guard !query.isEmpty else { return nil }
        let qChars = Array(query.lowercased())
        let hChars = Array(haystack.lowercased())
        guard !hChars.isEmpty else { return nil }

        var ranges: [Int] = []
        var hIdx = 0
        var lastMatchIdx: Int = -1
        var firstMatchIdx: Int = -1
        var gapPenalty: Double = 0
        var consecutiveBonus: Double = 0
        var atWordStart: Int = 0  // count matches landing at a word-start position

        for q in qChars {
            var matched = false
            while hIdx < hChars.count {
                if hChars[hIdx] == q {
                    ranges.append(hIdx)
                    if firstMatchIdx < 0 { firstMatchIdx = hIdx }
                    let gap = (lastMatchIdx < 0) ? 0 : (hIdx - lastMatchIdx - 1)
                    if gap == 0 && lastMatchIdx >= 0 {
                        consecutiveBonus += 0.05
                    } else {
                        gapPenalty += Double(gap) * 0.01
                    }
                    if hIdx == 0 || !hChars[hIdx - 1].isLetter || hChars[hIdx - 1].isWhitespace {
                        atWordStart += 1
                    }
                    lastMatchIdx = hIdx
                    hIdx += 1
                    matched = true
                    break
                }
                hIdx += 1
            }
            if !matched { return nil }
        }

        // Base: subsequence found. Adjust by:
        //   - prefix bonus (firstMatchIdx == 0)
        //   - word-start bonus (atWordStart / queryLen)
        //   - gap penalty (raw character spread)
        //   - consecutive bonus (adjacent matches)
        let qLen = Double(qChars.count)
        let prefixBonus: Double = firstMatchIdx == 0 ? 0.20 : 0.0
        let wordStartBonus: Double = (Double(atWordStart) / qLen) * 0.15
        let coverage: Double = qLen / Double(hChars.count)
        // Cap consecutive bonus at +0.20 — long exact matches shouldn't
        // dwarf the rest of the score function.
        let cappedConsecutive = min(0.20, consecutiveBonus)

        let raw = 0.40
            + 0.25 * coverage
            + prefixBonus
            + wordStartBonus
            + cappedConsecutive
            - gapPenalty
        let score = max(0.0, min(1.0, raw))
        return Match(score: score, ranges: ranges)
    }

    /// Convenience for the picker's per-row scoring — runs `match`
    /// against title/category/tags/body, weights each, and returns the
    /// best title-range set so the UI can highlight just the title.
    /// Returns `nil` if the row doesn't match the query at all.
    static func score(query: String, prompt: Prompt) -> (score: Double, titleRanges: [Int])? {
        guard !query.isEmpty else { return (0, []) }

        let titleMatch = match(query, in: prompt.title)
        let categoryMatch = match(query, in: prompt.category)
        let tagsBlob = prompt.tags.joined(separator: " ")
        let tagsMatch = match(query, in: tagsBlob)
        let bodyMatch = match(query, in: prompt.body)

        let titleScore = (titleMatch?.score ?? 0) * 1.0
        let categoryScore = (categoryMatch?.score ?? 0) * 0.7
        let tagsScore = (tagsMatch?.score ?? 0) * 0.6
        let bodyScore = (bodyMatch?.score ?? 0) * 0.4

        let combined = max(titleScore, max(categoryScore, max(tagsScore, bodyScore)))
        guard combined > 0 else { return nil }
        return (combined, titleMatch?.ranges ?? [])
    }
}
