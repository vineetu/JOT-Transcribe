import Foundation
import SwiftData

/// Persisted per-prompt usage stats. One row per bundled-or-user prompt
/// the user has touched. Untouched prompts have no row — fetch returns
/// nil, callers treat as zero-state.
///
/// Local-only by design. Never synced, never sent over the network — see
/// `docs/plans/prompt-picker-ux.md` §10 ("Telemetry-free recency").
@Model
final class PromptUsage {
    /// Foreign key into the prompt library. For bundled prompts this is
    /// the JSON `id` (e.g. `"improve-writing"`); for Phase 2 user-added
    /// prompts it is the user prompt's UUID stringified.
    @Attribute(.unique) var promptID: String
    var lastUsedAt: Date?
    var useCount: Int
    var pinned: Bool

    init(promptID: String, lastUsedAt: Date? = nil, useCount: Int = 0, pinned: Bool = false) {
        self.promptID = promptID
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.pinned = pinned
    }
}
