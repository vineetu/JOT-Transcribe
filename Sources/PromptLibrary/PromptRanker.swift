import Foundation

/// Orchestrates the prompt list shown in the picker. Takes the user's
/// query (may be empty), the operand (transcript / selection / nothing),
/// the active LLM provider, and the prompt+usage corpus, and returns:
///   - sections (Recent / Pinned / Essentials / by category) for the
///     no-query default view, OR
///   - a single ranked list for the query view.
///
/// All ranking is deterministic and pure — no side effects, no I/O.
/// The picker calls into this on every keystroke.
struct PromptRanker {
    struct Row: Identifiable, Equatable {
        let prompt: Prompt
        /// Composite rank for sort. Higher = nearer the top.
        let score: Double
        /// Title indexes to highlight on this row.
        let titleHighlightIndexes: [Int]

        var id: String { prompt.id }
    }

    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        let rows: [Row]
    }

    /// Heuristic classification of the operand (the text the picked
    /// prompt will run on). Drives the context-aware rank boosts in
    /// `boostFromContext(...)`. None of these are deterministic — a
    /// false positive means the wrong row gets nudged up by a small
    /// amount, never that a row gets hidden.
    enum OperandShape {
        case unknown
        case empty
        case code
        case email
        case meetingNotes
        case nonEnglish
        case veryShort   // <80 chars
        case veryLong    // >2000 chars
        case hasChecklist
    }

    // MARK: - Public entry points

    /// Default view (no query). Returns sections in fixed order:
    /// Recent → Pinned → Essentials. Tier 2/3 prompts are reachable
    /// only via search; they don't appear here.
    @MainActor
    static func defaultSections(
        store: PromptStore,
        operand: String?,
        activeProvider: String?
    ) -> [Section] {
        let shape = classify(operand: operand)
        var sections: [Section] = []

        // Recent (max 3, last 7 days).
        let recent = store.recentPrompts()
        if !recent.isEmpty {
            sections.append(Section(
                id: "recent",
                title: "Recent",
                rows: recent.map { Row(prompt: $0, score: 0, titleHighlightIndexes: []) }
            ))
        }

        // Pinned (any).
        let pinned = store.pinnedPrompts()
        if !pinned.isEmpty {
            sections.append(Section(
                id: "pinned",
                title: "Pinned",
                rows: pinned.map { Row(prompt: $0, score: 0, titleHighlightIndexes: []) }
            ))
        }

        // Essentials (Tier 1, with context-aware ordering when the
        // operand strongly suggests one).
        let essentials = store.essentialPrompts()
        let essentialsRows: [Row] = essentials.map { p in
            let base = providerCompatibilityScore(prompt: p, activeProvider: activeProvider)
            let ctx = boostFromContext(prompt: p, shape: shape)
            return Row(prompt: p, score: base + ctx, titleHighlightIndexes: [])
        }
        let sortedEssentials: [Row]
        if shape == .empty || shape == .unknown {
            // Preserve declared JSON order when there's no signal to
            // reweight on — that order is hand-tuned in curation.
            sortedEssentials = essentialsRows
        } else {
            sortedEssentials = essentialsRows.sorted { $0.score > $1.score }
        }
        sections.append(Section(
            id: "essentials",
            title: "Essentials",
            rows: sortedEssentials
        ))

        return sections
    }

    /// Search view (non-empty query). Returns a single flat ranked
    /// list across ALL tiers. Rows below `scoreThreshold` are dropped.
    @MainActor
    static func search(
        query: String,
        store: PromptStore,
        operand: String?,
        activeProvider: String?
    ) -> [Row] {
        guard !query.isEmpty else { return [] }
        let shape = classify(operand: operand)
        var rows: [Row] = []
        for prompt in store.allPrompts {
            guard let (matchScore, titleRanges) = FuzzyMatcher.score(query: query, prompt: prompt) else { continue }
            let pinnedBonus: Double = store.isPinned(prompt.id) ? 0.20 : 0.0
            let recencyBonus = recencyBoost(lastUsedAt: store.lastUsedAt(prompt.id))
            let frequencyBonus = frequencyBoost(useCount: store.useCount(prompt.id))
            let providerScore = providerCompatibilityScore(prompt: prompt, activeProvider: activeProvider)
            let contextScore = boostFromContext(prompt: prompt, shape: shape)
            let total = matchScore + pinnedBonus + recencyBonus + frequencyBonus + providerScore + contextScore
            // Same threshold as VS Code's palette — tuned by feel
            // (anything below this is usually a long-string body
            // coincidence, not a meaningful title match).
            if total >= 0.15 {
                rows.append(Row(
                    prompt: prompt,
                    score: total,
                    titleHighlightIndexes: titleRanges
                ))
            }
        }
        rows.sort { $0.score > $1.score }
        return rows
    }

    // MARK: - Context classifier

    /// Cheap heuristics over the operand text. Reads at most the first
    /// 2000 characters — the picker can run this on every keystroke,
    /// so cheap matters more than thorough.
    static func classify(operand: String?) -> OperandShape {
        guard let operand else { return .empty }
        let trimmed = operand.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }

        let head = String(trimmed.prefix(2000))
        let lines = head.split(separator: "\n", omittingEmptySubsequences: false)

        // Code? Backticks OR indent ratio OR syntax markers.
        if head.contains("```") { return .code }
        let indented = lines.filter { line in
            guard let first = line.first else { return false }
            return first == " " || first == "\t"
        }.count
        if lines.count >= 3, Double(indented) / Double(lines.count) >= 0.30 {
            return .code
        }
        if head.range(of: #"\bfunc\s|\bdef\s|\bimport\s|=>|<\w+>"#, options: .regularExpression) != nil {
            return .code
        }

        // Email? Greeting + sign-off pattern.
        let lowered = head.lowercased()
        let greetings = ["hi ", "hello ", "hey ", "dear "]
        let signoffs = ["best,", "thanks,", "regards,", "cheers,", "sincerely,"]
        let hasGreeting = greetings.contains { lowered.hasPrefix($0) || lowered.contains("\n\($0)") }
        let tail = String(head.suffix(200)).lowercased()
        let hasSignoff = signoffs.contains { tail.contains($0) }
        if hasGreeting && hasSignoff { return .email }

        // Meeting notes? Timestamps + name-colon prefixes + action keywords.
        let hasTimestamps = head.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil
        let nameColon = lines.prefix(40).filter { line in
            line.range(of: #"^[A-Z][a-zA-Z .'-]+:\s"#, options: .regularExpression) != nil
        }.count
        let actionKeywords = ["action item", "decision", "agreed", "next steps", "we agreed", "owner:"]
        let hasActionKw = actionKeywords.contains { lowered.contains($0) }
        if (hasTimestamps && nameColon >= 3) || (nameColon >= 3 && hasActionKw) {
            return .meetingNotes
        }

        // Checklist already present?
        let checkboxLines = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ]") }.count
        if checkboxLines >= 2 { return .hasChecklist }

        // Length-derived signals (lowest priority — only if no stronger
        // signal fired above).
        if trimmed.count < 80 { return .veryShort }
        if trimmed.count > 2000 { return .veryLong }

        // Non-English first 200 chars — a coarse Unicode-block sniff.
        let firstChunk = String(head.prefix(200))
        let nonLatin = firstChunk.unicodeScalars.filter { scalar in
            !scalar.properties.isWhitespace && scalar.value > 0x024F  // Latin Extended-B end
        }.count
        let letterCount = firstChunk.unicodeScalars.filter { $0.properties.generalCategory == .lowercaseLetter || $0.properties.generalCategory == .uppercaseLetter || $0.properties.generalCategory == .otherLetter }.count
        if letterCount > 0, Double(nonLatin) / Double(letterCount) >= 0.40 {
            return .nonEnglish
        }

        return .unknown
    }

    // MARK: - Boosts

    /// Per-prompt rank adjustment derived from operand shape. Returns
    /// 0 for prompts that don't match the inferred shape. Capped per
    /// shape so a single boost can't push a long-tail prompt past a
    /// clearly-better match.
    static func boostFromContext(prompt: Prompt, shape: OperandShape) -> Double {
        switch shape {
        case .empty, .unknown: return 0
        case .code:
            return prompt.id == "add-comments-to-code" ? 0.25 : 0
        case .email:
            switch prompt.id {
            case "respond-to-email": return 0.30
            case "bluf-email": return 0.20
            case "polite-decline": return 0.15
            default: return 0
            }
        case .meetingNotes:
            switch prompt.id {
            case "meeting-minutes-to-actions": return 0.35
            case "extract-key-points": return 0.15
            case "convert-to-action-items": return 0.10
            default: return 0
            }
        case .veryShort:
            switch prompt.id {
            case "summarize", "extract-key-points": return -0.20
            case "tighten-and-clarify", "make-formal", "make-casual": return 0.10
            default: return 0
            }
        case .veryLong:
            switch prompt.id {
            case "summarize", "extract-key-points", "convert-to-outline": return 0.15
            case "make-longer": return -0.15
            default: return 0
            }
        case .nonEnglish:
            switch prompt.id {
            case "translate": return 0.25
            // Tone rewrites are still useful cross-language but a touch
            // less reliable; demote modestly so translate wins ties.
            case "make-formal", "make-casual", "friendly-tone", "confident-tone":
                return -0.10
            default: return 0
            }
        case .hasChecklist:
            switch prompt.id {
            case "convert-to-action-items": return 0.20
            case "status-update-email": return 0.10
            default: return 0
            }
        }
    }

    /// Provider compatibility: 0 if the prompt has been verified on the
    /// active provider, small negative otherwise (demote, don't hide).
    /// Returns 0 when the provider isn't known so harness tests stay
    /// rank-stable.
    static func providerCompatibilityScore(prompt: Prompt, activeProvider: String?) -> Double {
        guard let active = activeProvider else { return 0 }
        return prompt.providerCompatibility.contains(active) ? 0 : -0.10
    }

    /// Decays from +0.15 at "just used" to 0 at +30 days. Linear.
    static func recencyBoost(lastUsedAt: Date?) -> Double {
        guard let lastUsedAt else { return 0 }
        let age = Date().timeIntervalSince(lastUsedAt)
        guard age >= 0 else { return 0.15 }
        let thirtyDays: TimeInterval = 30 * 24 * 60 * 60
        let normalized = max(0, 1 - age / thirtyDays)
        return normalized * 0.15
    }

    /// Log-scaled. Caps at +0.10 around ~150 uses; 1 use = ~+0.014.
    static func frequencyBoost(useCount: Int) -> Double {
        guard useCount > 0 else { return 0 }
        return min(0.10, log(Double(useCount) + 1) / 50.0)
    }
}
