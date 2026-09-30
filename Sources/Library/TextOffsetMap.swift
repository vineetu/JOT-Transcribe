import Foundation

/// Carries UTF-16 offsets in a transcript across one edit of it, so anything
/// anchored into the old text (stored speaker segments, an open edit draft's
/// view of the same words) lands on the same words in the new text.
///
/// Built either from an exact span replacement (a pick, an Add to
/// Vocabulary, a live-ask answer — where the edited span is known and a
/// diff would be ambiguous, e.g. "nathan" → "Ramanathan") or from a diff of
/// the two texts (a hand edit, which can change many places at once).
///
/// Offsets are mapped with a bias that decides who owns text inserted
/// exactly at a boundary: a `.start` boundary takes text inserted right
/// before its first character (typing at the head of a turn), an `.end`
/// boundary takes text inserted right after its last one (typing at the
/// tail). Text that replaces a removed run belongs to the side the run
/// belonged to (the earlier side when the run straddles the boundary).
/// Results always fall on composed-character boundaries of the new text.
struct TextOffsetMap {
    enum Bias { case start, end }

    /// Old UTF-16 index → its new index, or -1 when the edit removed it.
    private let newIndexOfOld: [Int]
    private let oldLength: Int
    private let new: NSString

    /// Exact: `span` (UTF-16, in `old`) was replaced by `replacement`.
    init(old: String, replacing span: NSRange, with replacement: String) {
        let oldLength = (old as NSString).length
        let delta = (replacement as NSString).length - span.length
        var map = [Int](repeating: -1, count: oldLength)
        for i in 0..<oldLength where i < span.location || i >= span.location + span.length {
            map[i] = i < span.location ? i : i + delta
        }
        self.newIndexOfOld = map
        self.oldLength = oldLength
        self.new = (old as NSString).replacingCharacters(in: span, with: replacement) as NSString
    }

    /// Diff-based: whatever changed between `old` and `new`. The common
    /// prefix and suffix are matched directly and only the middle is diffed,
    /// so a small edit in a long transcript stays cheap.
    init(old: String, new: String) {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let oldMiddle = Array(a[prefix..<(a.count - suffix)])
        let newMiddle = Array(b[prefix..<(b.count - suffix)])
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in newMiddle.difference(from: oldMiddle) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var map = [Int](repeating: -1, count: a.count)
        for i in 0..<prefix { map[i] = i }
        // Kept middle characters pair up in order.
        var j = 0
        for i in 0..<oldMiddle.count where !removed.contains(i) {
            while inserted.contains(j) { j += 1 }
            map[prefix + i] = prefix + j
            j += 1
        }
        for k in 0..<suffix { map[a.count - 1 - k] = b.count - 1 - k }
        self.newIndexOfOld = map
        self.oldLength = a.count
        self.new = new as NSString
    }

    /// The new-text offset for old boundary `offset` (0...old length).
    func map(_ offset: Int, _ bias: Bias) -> Int {
        let o = min(max(offset, 0), oldLength)
        // The kept characters on each side of the boundary; the new text
        // between their images is exactly what was inserted in this gap.
        var before = o - 1
        while before >= 0, newIndexOfOld[before] < 0 { before -= 1 }
        var after = o
        while after < oldLength, newIndexOfOld[after] < 0 { after += 1 }
        let gapStart = before >= 0 ? newIndexOfOld[before] + 1 : 0
        let gapEnd = after < oldLength ? newIndexOfOld[after] : new.length
        let removedBefore = o - (before + 1)
        let removedAfter = after - o
        // A start takes the gap's new text only when nothing before it in
        // the gap was removed; an end gives it up only when it sits exactly
        // where a removed run begins (that run belonged to what follows). So a
        // replacement straddling a boundary goes to the earlier side, once.
        let raw: Int
        switch bias {
        case .start: raw = removedBefore == 0 ? gapStart : gapEnd
        case .end: raw = (removedBefore == 0 && removedAfter > 0) ? gapStart : gapEnd
        }
        return snapped(raw, bias)
    }

    private func snapped(_ offset: Int, _ bias: Bias) -> Int {
        guard offset > 0, offset < new.length else { return min(max(offset, 0), new.length) }
        switch bias {
        case .start:
            return new.rangeOfComposedCharacterSequence(at: offset).location
        case .end:
            let r = new.rangeOfComposedCharacterSequence(at: offset - 1)
            return r.location + r.length
        }
    }
}
