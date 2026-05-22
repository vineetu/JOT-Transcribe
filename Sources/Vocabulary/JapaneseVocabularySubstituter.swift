import Foundation

/// Alias-based vocabulary substitution for Japanese transcripts.
///
/// FluidAudio shipped `TdtJaManager` and `CtcJaManager` as independent
/// transcribers and did not wire them for vocabulary boosting. Two
/// upstream gaps block the English-style acoustic CTC path on JA today:
///
/// 1. **No `CtcJaKeywordSpotter`.** `CtcKeywordSpotter` is constructed
///    with `CtcModels` (EN-only — its variant enum only enumerates
///    `.ctc110m` and `.ctc06b`). There is no JA-accepting constructor
///    or sibling type.
/// 2. **No token timings from `TdtJaManager.transcribe`.** It returns a
///    plain `String`, not `ASRResult`. Even if we solved (1) we'd have
///    no timings to align rescorings back to the transcript.
///
/// Until either FluidAudio change lands, JA vocab works at the **text
/// layer**: after JA transcription finishes, scan the transcript for any
/// vocab term's aliases and substitute the canonical form. The user is
/// responsible for writing the aliases — typically the writing systems
/// they want substituted away (hiragana / katakana / romaji variants
/// they want collapsed to a single canonical kanji rendering).
///
/// Example `~/Library/Application Support/Jot/Vocabulary/vocabulary.txt`
/// entry for a JA user who prefers kanji:
///
/// ```
/// 東京: とうきょう, トウキョウ, tokyo
/// ```
///
/// On a JA recording that the model transcribes as `…とうきょうに行きます…`,
/// the substituter rewrites it to `…東京に行きます…`.
///
/// Limitations vs real CTC rescoring (call out in copy / Help):
/// - **No acoustic grounding.** If the model emits a phonetic variant
///   the user didn't list as an alias, no boost happens.
/// - **Substring-level substitution.** The user is responsible for not
///   writing aliases that false-match against unrelated text.
/// - **No timing alignment** — substitutions land wherever the alias
///   appears in the transcript, with longest aliases applied first to
///   avoid prefix collisions (an alias `東京駅` wins over `東京`).
///
/// Pure value-type API — no actor isolation, no FluidAudio dependency.
enum JapaneseVocabularySubstituter {

    /// Run alias substitution against a JA transcript.
    /// - Parameters:
    ///   - transcript: raw text from `TdtJaManager.transcribe(...)`,
    ///     already cleaned by upstream stages.
    ///   - terms: enabled vocab term list, typically a snapshot of
    ///     `VocabularyStore.shared.terms` read on the MainActor.
    /// - Returns: substituted transcript. When no aliases apply the
    ///   input is returned unchanged (modulo NFC normalization, which
    ///   is a no-op for already-normalized JA text).
    static func substitute(transcript: String, terms: [VocabTerm]) -> String {
        guard !terms.isEmpty else { return transcript }

        // Normalize both sides to NFC so combining-mark mismatches don't
        // silently skip substitutions (Japanese diacritics — the
        // precomposed `が` vs decomposed `か` + combining-voiced-mark
        // form — are the practical case).
        let normalizedInput = transcript.precomposedStringWithCanonicalMapping

        struct Substitution {
            let alias: String
            let canonical: String
        }

        // Flatten (term, alias) pairs once. Longest alias first so a
        // longer match wins over a shorter prefix collision in the
        // same transcript.
        var subs: [Substitution] = []
        for term in terms {
            let canonical = term.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
            guard !canonical.isEmpty else { continue }
            for raw in term.aliases {
                let alias = raw
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .precomposedStringWithCanonicalMapping
                guard !alias.isEmpty, alias != canonical else { continue }
                subs.append(.init(alias: alias, canonical: canonical))
            }
        }
        guard !subs.isEmpty else { return normalizedInput }
        subs.sort { $0.alias.count > $1.alias.count }

        var output = normalizedInput
        for sub in subs {
            output = output.replacingOccurrences(of: sub.alias, with: sub.canonical)
        }
        return output
    }
}
