import Foundation

/// Text cleanup applied to every Parakeet transcript before it reaches the
/// clipboard / the user.
///
/// Kept intentionally tiny in v1 — trim, collapse repeated interior
/// whitespace, and drop stray spaces before sentence punctuation. Custom
/// vocabulary find/replace slots in here later (see
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
        case .tdt_0_6b_v3:
            return applyEnglish(text)
        case .tdt_0_6b_ja:
            return applyJapanese(text)
        }
    }

    private static func applyEnglish(_ text: String) -> String {
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Collapse runs of internal whitespace (including tabs / newlines the
        // decoder occasionally emits around punctuation) into single spaces.
        working = collapseInternalWhitespace(working)

        // Remove stray spaces that precede sentence punctuation — Parakeet
        // sometimes emits " ." or " ,".
        for punctuation in [",", ".", ";", ":", "!", "?"] {
            working = working.replacingOccurrences(of: " \(punctuation)", with: punctuation)
        }

        return working
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
}
