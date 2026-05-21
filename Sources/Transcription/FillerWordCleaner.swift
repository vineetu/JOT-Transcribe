import Foundation

/// Post-transcription filler-word stripper. Pure enum with no I/O —
/// safe to call from any batch-transcription path (menu-bar dictation,
/// Rewrite, Setup Wizard mic test, etc.).
///
/// This runs AFTER `ParagraphSegmenter.segment(...)` so the removed
/// tokens never affect pause-measurement decisions — paragraph
/// breaks are already baked in by the time we get here, and the
/// leading-side of the filler regex deliberately consumes only
/// spaces/tabs (NOT newlines) so we cannot collapse a `\n\n`
/// boundary the segmenter inserted.
///
/// Lightweight regex sweep that always runs on every transcript. Only
/// removes the most obvious filler tokens (`um`, `uh`, `er`, `uhm`, `erm`
/// and their elongated variants) — no toggle, no model.
enum FillerWordCleaner {

    /// Regex patterns matched case-insensitively at word boundaries.
    /// Each pattern is wrapped with adjacent-comma + whitespace
    /// consumption when assembled into the final regex.
    static let fillerWords: [String] = [
        "um(m+)?", "uh(h+)?", "er(r+)?", "uhm", "erm"
    ]

    /// Strip filler tokens + adjacent commas + surrounding whitespace,
    /// then run light cleanup: collapse runs of whitespace to one space,
    /// remove orphan " ," / " ." / " ?" / " !", and recapitalize the
    /// first letter of each sentence.
    static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // 1. Filler strip. Leading/trailing context uses `[ \t]` (NOT
        //    `\s`) so we never consume `\n` characters — that would
        //    collapse the `\n\n` paragraph boundaries inserted by
        //    `ParagraphSegmenter`. `\b` enforces word boundaries so
        //    `umbrella`, `umpire`, etc. are preserved.
        //
        //    Replacement is a SINGLE SPACE (not empty) so that the
        //    common mid-sentence case "yeah uh okay" produces
        //    "yeah okay" instead of "yeahokay". Edge cases (filler at
        //    string start/end, adjacent to `\n\n`, before punctuation)
        //    are mopped up by steps 2.5, 3, and 4 below.
        let alternation = fillerWords.joined(separator: "|")
        let pattern = "[ \\t]*,?[ \\t]*\\b(?:\(alternation))\\b[ \\t]*,?[ \\t]*"
        var result = text
        if let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: " "
            )
        }

        // 2. Collapse runs of spaces/tabs to one space. Newlines are
        //    preserved as-is so paragraph breaks (`\n\n`) survive.
        if let collapse = try? NSRegularExpression(pattern: "[ \\t]{2,}") {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = collapse.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: " "
            )
        }

        // 2.5. Trim whitespace introduced adjacent to paragraph breaks
        //      by step 1's single-space replacement. Without this,
        //      "Hello.\n\num World" → "Hello.\n\n World" (leading space
        //      inside the new paragraph). Both directions matter:
        //      "[ \t]+\n\n" catches trailing whitespace before a break;
        //      "\n\n[ \t]+" catches leading whitespace after a break.
        if let trimAfterBreak = try? NSRegularExpression(pattern: "\\n\\n[ \\t]+") {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = trimAfterBreak.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "\n\n"
            )
        }
        if let trimBeforeBreak = try? NSRegularExpression(pattern: "[ \\t]+\\n\\n") {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = trimBeforeBreak.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "\n\n"
            )
        }

        // 3. Remove orphan punctuation left behind when a filler word
        //    was stripped but its surrounding punctuation wasn't —
        //    " ," / " ." / " ?" / " !" all become empty (drop the
        //    space AND the punctuation, since the punctuation no
        //    longer attaches to a real word).
        if let orphan = try? NSRegularExpression(pattern: " [,.?!]") {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = orphan.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: ""
            )
        }

        // 4. Strip dangling leading punctuation/whitespace. After
        //    step 3, `"Um. Uh."` reduces to `"."` — the leading
        //    period is orphaned because nothing precedes it. Trim
        //    any combination of leading `.,?!` + spaces/tabs so an
        //    all-filler input collapses to "".
        while let first = result.first,
              first == "." || first == "," || first == "?" || first == "!"
                || first == " " || first == "\t" {
            result.removeFirst()
        }
        // Also trim trailing whitespace introduced by step 1.
        while let last = result.last, last == " " || last == "\t" {
            result.removeLast()
        }

        // 5. Recapitalize the first letter of each sentence. Guards
        //    against the empty-string case (e.g. all-filler input)
        //    so we never index into an empty result.
        result = recapitalizeSentences(result)

        return result
    }

    // MARK: - Helpers

    /// Uppercase the first alphabetic character of the string and the
    /// first alphabetic character after each sentence-final
    /// punctuation mark (`.`, `!`, `?`) followed by whitespace. No-op
    /// on empty input.
    private static func recapitalizeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var chars = Array(text)
        var capitalizeNext = true
        for i in 0..<chars.count {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                let upper = String(c).uppercased()
                if let firstUpper = upper.first {
                    chars[i] = firstUpper
                }
                capitalizeNext = false
            } else if c == "." || c == "!" || c == "?" {
                capitalizeNext = true
            } else if c.isWhitespace || c.isNewline {
                // whitespace doesn't reset the flag — it just lets
                // capitalizeNext "wait" for the next letter.
                continue
            } else if c.isLetter || c.isNumber {
                capitalizeNext = false
            }
        }
        return String(chars)
    }
}
