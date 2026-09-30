import Foundation

/// Whole-word, case-insensitive matching over a transcript — the ONE matcher
/// the live ask, the correction review, and the Add-to-Vocabulary fallback
/// share, so they can never disagree about which occurrence a word is. A
/// match is whole-word only when the characters on either side are not
/// letters ("Lisa" never matches inside "Lisbon").
enum WholeWord {

    /// Every whole-word occurrence of `word` in `text`, in document order.
    static func ranges(of word: String, in text: String) -> [Range<String.Index>] {
        guard !word.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var search = text.startIndex
        while search < text.endIndex,
              let r = text.range(of: word, options: [.caseInsensitive], range: search..<text.endIndex) {
            let before: Character? = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after: Character? = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            if !(before?.isLetter ?? false) && !(after?.isLetter ?? false) { ranges.append(r) }
            search = r.upperBound
        }
        return ranges
    }

    /// The first whole-word occurrence of `word` in `text`.
    static func firstRange(of word: String, in text: String) -> Range<String.Index>? {
        ranges(of: word, in: text).first
    }

    /// The whole-word occurrence of `word` that starts exactly at Character
    /// `offset` — nil when the word is not there any more. Strict on purpose:
    /// a caller holding an anchor must never edit a guessed repeat of the word.
    static func range(of word: String, at offset: Int, in text: String) -> Range<String.Index>? {
        let needle = word.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?\"'\u{2019}\u{201D})]}"))
        return ranges(of: needle, in: text)
            .first { text.distance(from: text.startIndex, to: $0.lowerBound) == offset }
    }

    /// Trimmed, ellipsized text on each side of `range` — the ask pill's "the
    /// word in its sentence" line. Each side is capped at `maxContextChars`.
    static func context(around range: Range<String.Index>, in text: String,
                        maxContextChars: Int = 24) -> (before: String, after: String) {
        var before = String(text[text.startIndex..<range.lowerBound])
        var after = String(text[range.upperBound..<text.endIndex])
        if before.count > maxContextChars { before = "…" + before.suffix(maxContextChars) }
        if after.count > maxContextChars { after = after.prefix(maxContextChars) + "…" }
        return (before, after)
    }
}
