import Foundation

/// Pure, UI-free find-in-transcript logic shared by both detail panes (the plain
/// transcript = a single block; the speaker-labeled view = one block per display
/// segment). Computes every case- and diacritic-insensitive literal-substring
/// match across an ordered list of block texts, plus current-match stepping with
/// wraparound. No AppKit, no SwiftUI — the view layers highlighting + scrolling
/// on top of these results.
enum TranscriptSearch {

    /// One match: which block, and the UTF-16 `NSRange` of the matched text
    /// WITHIN that block (the matched substring's own range — with diacritic
    /// folding it can differ in length from the query, e.g. "resume" → "résumé").
    struct Match: Equatable {
        let blockIndex: Int
        let range: NSRange
    }

    /// Every match of `query` across `blocks`, in reading order (block index,
    /// then position within the block). Case- and diacritic-insensitive literal
    /// substring search — no regex. Empty query, or a query longer than a block,
    /// yields no matches for that block. Overlapping matches are not produced
    /// (search resumes past each hit).
    static func matches(query: String, in blocks: [String]) -> [Match] {
        guard !query.isEmpty else { return [] }
        var out: [Match] = []
        for (blockIndex, text) in blocks.enumerated() {
            let ns = text as NSString
            guard ns.length > 0 else { continue }
            var searchStart = 0
            while searchStart < ns.length {
                let found = ns.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: NSRange(location: searchStart, length: ns.length - searchStart))
                guard found.location != NSNotFound, found.length > 0 else { break }
                out.append(Match(blockIndex: blockIndex, range: found))
                // Advance past this match (min +1 guards against a zero-width
                // pathological result, which the length>0 check already rejects).
                searchStart = found.location + max(1, found.length)
            }
        }
        return out
    }

    /// Step the current-match index with wraparound in either direction. Returns
    /// 0 when there are no matches. `forward` advances (`⌘G`), else retreats
    /// (`⇧⌘G`); both wrap around the ends.
    static func step(current: Int, count: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        let base = ((current % count) + count) % count   // normalize a stale index
        return forward ? (base + 1) % count : (base - 1 + count) % count
    }
}
