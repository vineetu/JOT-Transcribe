import Foundation

/// Text cleanup applied to every local transcript before it reaches the
/// clipboard / the user.
///
/// Kept intentionally tiny in v1 — trim, collapse repeated interior
/// whitespace inside each paragraph, preserve paragraph breaks, and drop
/// stray spaces before sentence punctuation. Custom vocabulary find/replace
/// slots in here later (see
/// `docs/plans/swift-rewrite.md` → Future Plans).
///
/// The English branch is the existing rule set. The Japanese branch is wired
/// but currently a passthrough — it will only diverge once we empirically
/// verify the punctuation bytes the shipped Parakeet JA model emits (full-
/// width vs ASCII). See `docs/plans/japanese-support.md` items 6 and 12.
public enum PostProcessing {
    public static func apply(_ text: String, language: ParakeetModelID = .tdt_0_6b_v3) -> String {
        guard !text.isEmpty else { return "" }

        switch language {
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming,
             .nemotron_en:
            return applyEnglish(text)
        case .tdt_0_6b_ja:
            return applyJapanese(text)
        case .nemotron_multilingual, .nemotron_multilingual_latin:
            // These emit clean native punctuation/casing across scripts (CJK,
            // Arabic, Devanagari, …); the English regex chain would mangle
            // non-Latin output. Passthrough.
            return text
        }
    }

    private static func applyEnglish(_ text: String) -> String {
        let working = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // ParagraphSegmenter inserts "\n\n" boundaries before this final pass.
        // Preserve those boundaries while still applying the older whitespace
        // and punctuation cleanup inside each paragraph.
        let paragraphs = working.components(separatedBy: "\n\n")
        return paragraphs
            .map(cleanParagraph)
            .joined(separator: "\n\n")
    }

    private static func applyJapanese(_ text: String) -> String {
        // TODO: empirical punctuation verification per docs/plans/japanese-support.md item 12 — currently passthrough
        return text
    }

    private static func collapseInternalWhitespace(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)

        var lastWasWhitespace = false
        for scalar in input.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasWhitespace {
                    output.append(" ")
                    lastWasWhitespace = true
                }
            } else {
                output.unicodeScalars.append(scalar)
                lastWasWhitespace = false
            }
        }
        return output
    }

    private static func cleanParagraph(_ paragraph: String) -> String {
        var working = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)

        // Collapse runs of internal whitespace (including tabs / single
        // newlines the decoder occasionally emits around punctuation) into
        // single spaces.
        working = collapseInternalWhitespace(working)

        // Remove stray spaces that precede sentence punctuation — Parakeet
        // sometimes emits " ." or " ,".
        for punctuation in [",", ".", ";", ":", "!", "?"] {
            working = working.replacingOccurrences(of: " \(punctuation)", with: punctuation)
        }

        return working
    }
}
