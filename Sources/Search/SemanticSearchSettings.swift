import Foundation

/// Single source of truth for the semantic-search feature gate.
///
/// Semantic search ships **ON by default** — the toggle is an opt-OUT. On first
/// run it kicks off the (one-time, non-blocking) ~339 MB EmbeddingGemma download
/// and a gentle background backfill of the existing library. Substring search in
/// `RecordingsListView` always works regardless of this flag — semantic recall
/// is purely additive on top of it, and arrives silently once the index fills.
///
/// Stored in `UserDefaults` under `jot.semanticSearch.enabled` so both SwiftUI
/// (`@AppStorage`) and plain Swift (indexer / backfill, which run off the main
/// actor) read the same value.
enum SemanticSearchSettings {
    static let enabledKey = "jot.semanticSearch.enabled"

    /// Default-ON: unset reads as `true`. SwiftUI `@AppStorage` declarations
    /// must mirror this default (`= true`).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}
