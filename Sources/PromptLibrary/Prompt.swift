import Foundation

/// A single reusable prompt — system-prompt body plus presentation metadata.
/// Decoded from `Resources/prompt-library.json` at app launch and merged
/// with the (Phase 2) user-added store at render time.
struct Prompt: Codable, Equatable, Identifiable, Hashable, Sendable {
    enum Tier: Int, Codable, Sendable {
        /// Visible by default in the picker. The 8 essentials.
        case essentials = 1
        /// Reachable via search. Value-add prompts (translate, email, convert).
        case valueAdd = 2
        /// Reachable via search. Long-tail prompts that we ship for completeness.
        case longTail = 3
    }

    let id: String
    let title: String
    let tier: Tier
    /// Display label used as the section header in the picker AND as a
    /// search-weighted field. Free-form string — no enum, no folder
    /// hierarchy (see curation doc §5).
    let category: String
    /// Loose tags used to weight fuzzy match. Not surfaced as a UI
    /// navigation surface.
    let tags: [String]
    /// The LLM system prompt. Sent verbatim as the rewrite system prompt
    /// when the user picks this row.
    let body: String
    /// One-line example of what the user might dictate / select.
    /// Rendered in the preview drawer (⌥⏎). May be nil for prompts
    /// where a sample doesn't add clarity.
    let sampleInput: String?
    /// One-line example of what the LLM would return for `sampleInput`.
    /// Rendered alongside the input in the preview drawer.
    let sampleOutput: String?
    /// If non-nil, the picker shows a small `⌘⏎` hint with this string
    /// as tooltip text — guides the user toward the voice-augment path
    /// when it materially helps (e.g. "Specify the target language").
    let voiceAugmentHint: String?
    /// Provider IDs (matches `LLMProvider.rawValue`) where this prompt
    /// has been verified to produce a reasonable result. Used by the
    /// picker to demote (not hide) entries on providers where the
    /// prompt is untested.
    let providerCompatibility: [String]
}

/// Top-level shape of the bundled prompt library JSON.
struct PromptLibraryFile: Codable, Sendable {
    let version: Int
    let prompts: [Prompt]
}
