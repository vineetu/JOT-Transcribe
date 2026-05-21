import Foundation

/// Single source of truth for the sparkle-icon prefills on the three
/// Basics hero cards (Dictation, Cleanup, Rewrite). Tapping the
/// sparkle on a hero routes to the Ask Jot sidebar entry and prefills
/// the TextField with `FeatureQuestionMap.prefill(for: heroSlug)` —
/// does NOT auto-send (spec §9 rule 5).
///
/// Keys are the hero slugs from `Feature.swift` (`"dictation"`,
/// `"cleanup"`, `"prompts"`). Any other slug returns `nil`; the
/// sparkle affordance only exists on the three heroes so callers
/// shouldn't pass sub-row slugs here.
enum FeatureQuestionMap {
    private static let prefills: [String: String] = [
        "dictation":  "How does Jot's dictation work end-to-end?",
        "cleanup":    "What does Cleanup do, and which provider should I pick?",
        "prompts":    "How do prompts work, and how do I pick or add one?"
    ]

    static func prefill(for heroSlug: String) -> String? {
        prefills[heroSlug]
    }
}
