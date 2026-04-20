import Foundation

/// Router that sorts a user's spoken articulate (custom) instruction into one of
/// four branches so `LLMClient.articulate(…)` can pick a specialized system
/// prompt.
///
/// Deliberately regex-based and deterministic — no network, no LLM,
/// zero tokens. The prototype at
/// `docs/research/rewrite-classifier-prototype.md` scored 73/74 (98.6%)
/// on a 74-row realistic instruction corpus. The single miss was a
/// genuinely mixed-intent phrase where humans disagree on the ground
/// truth ("bullet points in Spanish") — not a defect of this design.
///
/// The classifier is a **hint**, not a gate. The user's spoken
/// instruction is always embedded verbatim in the LLM prompt; the
/// branch selection only chooses which short tendency block to append
/// to the shared invariants. If the instruction's branch is misread,
/// the prompt still honors the literal instruction.
enum ArticulateBranch: String, Sendable {
    case voicePreserving
    case structural
    case translation
    case code
}

enum ArticulateInstructionClassifier {
    static func classify(_ instruction: String) -> ArticulateBranch {
        let s = instruction
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Order matters: mixed "bullet points in Spanish" collapses to
        // translation per the prototype's mixed-intent rule (language is
        // the harder invariant to preserve across a rewrite than bullets).
        if matches(s, translationPatterns) { return .translation }
        if matches(s, codePatterns) { return .code }
        if matches(s, structuralPatterns) { return .structural }
        return .voicePreserving
    }

    // MARK: - Rules (V3, post-prototype)

    /// Covers explicit verbs, bare language names, and the
    /// "<tail>, in German" comma form flagged by the codex review.
    private static let translationPatterns: [String] = [
        #"\btranslate(d|s|r|rs)?\b"#,
        #"\b(in|to|into)\s+(spanish|french|german|japanese|italian|portuguese|chinese|korean|dutch|russian|arabic|hindi|urdu|bengali|tamil|telugu|turkish|polish|swedish|norwegian|danish|finnish|greek|hebrew|thai|vietnamese|indonesian)\b"#,
        #"(^|[\s,])(spanish|french|german|japanese|italian|portuguese|chinese|korean|dutch|russian|arabic|hindi|urdu|bengali|tamil|telugu|turkish|polish|swedish|norwegian|danish|finnish|greek|hebrew|thai|vietnamese|indonesian)(\s|$|\.)"#,
        #"\bauf\s+deutsch\b"#,
        #"\ben\s+espa(ñ|n)ol\b"#,
        #"\ben\s+fran(ç|c)ais\b"#,
        #"\bsay\s+(this|that|it)\s+in\b"#,
    ]

    /// Rewrites that target code's syntactic / semantic identity rather
    /// than natural-language tone. "Fix this function" / "add comments" /
    /// "convert to async" live here. We intentionally do NOT include
    /// every language name — common ones only, because "Python" in free
    /// prose rarely means "translate this to Python."
    private static let codePatterns: [String] = [
        #"\badd\s+(code\s+)?comments?\b"#,
        #"\bcomment\s+(this|the)\s+code\b"#,
        #"\bconvert\s+to\s+(async|await|promises?|callbacks?|arrow\s+functions?)\b"#,
        #"\brewrite\s+(in|as|using)\s+(typescript|javascript|swift|python|rust|go|java|kotlin|c\+\+|c#|ruby)\b"#,
        #"\bfix\s+(the\s+)?(syntax|compile\s+errors?|type\s+errors?|lint)\b"#,
        #"\bexplain\s+(the\s+)?code\s+(in|as)\s+(a\s+)?comments?\b"#,
        #"\brefactor\s+(this|the)\s+(function|method|class|code)\b"#,
        #"\buse\s+(async|await|promises|arrow\s+functions|generics|protocols)\b"#,
    ]

    /// Shape transforms — from prose to lists/tables/paragraphs, or
    /// explicit length/structure shifts that defeat "match length
    /// roughly" tendency. Includes list-verbs per codex review.
    private static let structuralPatterns: [String] = [
        #"\b(bullet|bulleted|bullets?)\s+(point|list|form)"#,
        #"\b(bullet\s*point|bullet\s+list|bulleted\s+list)\b"#,
        #"\b(make|turn|convert|reshape|format|reformat|rewrite)\s+(this|that|it)?\s*(into|as|to)\s+(a\s+)?(list|bullets?|bullet\s+points?|table|numbered\s+list|steps?|paragraphs?)\b"#,
        #"\b(as|into|to)\s+(a\s+)?(numbered\s+list|bulleted\s+list|bullet\s+list|bullet\s+points|bullets|table|steps?)\b"#,
        #"\blist\s+(out|the\s+)?(key\s+)?(points?|ideas?|items?|steps?)\b"#,
        #"\benumerate\b"#,
        #"\b(break|split)\s+(this|that|it)?\s*(into|up|down)\s+(paragraphs?|steps?|sections?|bullets?)\b"#,
        #"\bmake\s+(this|that|it)?\s*(a\s+)?(list|table|bulleted|numbered)\b"#,
        #"\b(expand|elaborate|flesh\s+out)\s+(this|on|that)?\b"#,
        #"\b(tldr|tl;dr|summary|summarize|summari[sz]e)\b"#,
        #"\bshorter\b|\btighter\b|\bcondense\b|\bcompress\b"#,
        #"\b(make\s+(this|it)\s+)?(way\s+)?longer\b"#,
    ]

    // MARK: - Matcher

    private static func matches(_ s: String, _ patterns: [String]) -> Bool {
        for p in patterns {
            if s.range(of: p, options: [.regularExpression]) != nil {
                return true
            }
        }
        return false
    }
}
