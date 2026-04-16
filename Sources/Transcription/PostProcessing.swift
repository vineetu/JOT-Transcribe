import Foundation

/// Text cleanup applied to every Parakeet transcript before it reaches the
/// clipboard / the user.
///
/// Kept intentionally tiny in v1 — trim, collapse repeated interior
/// whitespace, and drop stray spaces before sentence punctuation. Custom
/// vocabulary find/replace slots in here later (see
/// `docs/plans/swift-rewrite.md` → Future Plans).
public enum PostProcessing {
    public static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return "" }

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
