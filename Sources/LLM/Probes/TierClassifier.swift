import Foundation

/// Generic tier-and-generation classifier. The product call (per the
/// design doc): don't hardcode model IDs as "the default to select."
/// Hardcode tier *patterns* (`-mini`, `haiku`, `-flash-lite`) and
/// generation *regexes* (`gpt-(\d+(?:\.\d+)?)`,
/// `claude-\w+-(\d+)-(\d+)`, `gemini-(\d+\.\d+)-`). Discover IDs at
/// runtime by parsing the provider's `/models` response and pick the
/// id that maximises `generation` lexicographically, then prefers the
/// small tier within that generation.
///
/// `latestGenRegex` captures one-to-many numeric groups; the
/// comparator stringifies each group as a zero-padded int and joins
/// with `.`, so `("5", "1")` (gpt-5.1) sorts above `("5",)` (gpt-5)
/// and `("4", "20")` (claude-4-20) sorts above `("3", "5")`.
/// Lexicographic on the zero-padded shape gives the right ordering
/// for all four providers' versioning schemes.
struct TierClassifier: Sendable {
    let provider: LLMProvider
    /// Regex matching the provider's latest-generation prefix. One or
    /// more numeric capture groups. Anchored to start of id. `nil`
    /// for providers without a meaningful version scheme (Ollama).
    let latestGenRegex: NSRegularExpression?
    /// `nil` when the model id doesn't carry a tier hint we recognise.
    let tierFor: @Sendable (String) -> DiscoveredModel.Tier?
    /// Identifies reasoning / "thinking" models we'd like to exclude
    /// from the default-pick candidate pool. Still surfaced in the
    /// full picker list, but never auto-selected.
    let isThinking: @Sendable (String) -> Bool

    /// Walk a probed model list and pick the id that should pre-fill
    /// the combobox. Mirrors the plan's pseudocode verbatim:
    ///
    /// ```
    /// 1. Drop thinking models.
    /// 2. Find the max generation among the remainder. Bail if none
    ///    can be parsed (means we don't recognise this catalog —
    ///    return the first id instead, last-resort).
    /// 3. Restrict to the max generation.
    /// 4. Prefer .small, then .medium, then first id.
    /// ```
    func defaultPick(among probed: [DiscoveredModel]) -> String? {
        let candidates = probed.filter { !$0.isThinking }
        guard !candidates.isEmpty else { return nil }

        guard let regex = latestGenRegex else {
            // No version regex (Ollama) — fall back to the first
            // model. The combobox will display the local catalog
            // verbatim in pulled-order; user picks whatever they want.
            return candidates.first?.id
        }

        // Parse each id's generation key (zero-padded join of capture
        // groups). Drop ids that don't match the regex at all.
        let withKeys = candidates.compactMap { model -> (DiscoveredModel, String)? in
            guard let key = generationKey(for: model.id, regex: regex) else { return nil }
            return (model, key)
        }
        guard let maxKey = withKeys.map({ $0.1 }).max() else {
            // Nothing matched — defensive fallback to the first
            // candidate so the picker isn't blank.
            return candidates.first?.id
        }
        let sameGen = withKeys.filter { $0.1 == maxKey }.map { $0.0 }

        // Within the same generation, prefer small → medium → first.
        if let small = sameGen.first(where: { $0.tier == .small }) {
            return small.id
        }
        if let mid = sameGen.first(where: { $0.tier == .medium }) {
            return mid.id
        }
        return sameGen.first?.id
    }

    /// Compose a sortable key from the regex capture groups. Each
    /// group is zero-padded to width 4 (handles single-digit and
    /// double-digit version numbers uniformly).
    func generationKey(for id: String, regex: NSRegularExpression) -> String? {
        let range = NSRange(id.startIndex..., in: id)
        guard let match = regex.firstMatch(in: id, range: range) else {
            return nil
        }
        guard match.numberOfRanges > 1 else { return nil }
        var parts: [String] = []
        for i in 1..<match.numberOfRanges {
            let groupRange = match.range(at: i)
            guard groupRange.location != NSNotFound,
                  let swiftRange = Range(groupRange, in: id) else {
                continue
            }
            let raw = String(id[swiftRange])
            // Two-segment versions like "1.5" need to compare as
            // ("1", "5") not as a single string "1.5". Split inner
            // periods so the join stays per-component.
            for component in raw.split(separator: ".") {
                if let n = Int(component) {
                    parts.append(String(format: "%04d", n))
                } else {
                    parts.append(component.padding(
                        toLength: 4,
                        withPad: "0",
                        startingAt: 0
                    ))
                }
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ".")
    }
}
