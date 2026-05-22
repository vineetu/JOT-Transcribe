import Foundation

/// Pure-value-type filter used by the new Shortcuts pane's search field.
///
/// Lives in its own file so the (~60 LOC) DEBUG tests can exercise it
/// without instantiating any SwiftUI. The filter is intentionally simple:
/// lowercase the query, split on whitespace, require every token to be a
/// substring of the row's pre-built haystack. This matches the Raycast /
/// VS Code behavior where typing "opt /" still hits ⌥/ because both
/// "opt" and "/" exist in the keywords list — but stays well below the
/// complexity of a real fuzzy matcher.
enum ShortcutsSearchFilter {
    /// Returns the subset of `rows` matching `query`. An empty (or
    /// whitespace-only) query returns the rows untouched.
    static func filter(_ rows: [ShortcutsRow], query: String) -> [ShortcutsRow] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return rows }
        return rows.filter { row in
            let haystack = row.searchHaystack
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    /// Normalize a query into a list of lowercased tokens. Stripped of
    /// surrounding / interleaved whitespace. Exposed so tests can pin
    /// the tokenizer behavior independently from the filter.
    static func tokenize(_ query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }
}
