import FluidAudio
import Foundation
import os.log

/// **v1a — the gate.** A safety filter over FluidAudio's proposed vocabulary
/// replacements so a custom term can *never silently overwrite a word the
/// transcriber already got right.*
///
/// FluidAudio's rescorer (CTC word-spotting, NeMo arXiv:2406.07096) proposes
/// "replace word X with term Y when Y's acoustic score beats X". That swap has
/// no brake — it fires even on a 0.998-confidence correct word (the shipped
/// over-correction bug: adding "Jamy" turned every "name" into "Jamy"). This
/// gate adds the brake:
///   1. **Plausibility** — the heard word must be an acoustic cousin of the
///      term/alias (edit-distance bound). Kills "Vikram"→"Sriram"-class garbage.
///   2. **Confidence ceiling** — never auto-correct a word the TDT transcriber
///      was very sure about (the 0.998 protector).
///   3. **Common-word guard** — never overwrite an everyday word (frequency set)
///      unless the override is earned. The frequency set is **per-language**
///      (`CommonWords(forLanguage:)`); a language whose list is missing simply
///      skips this one guard (confidence + plausibility + earned-override still
///      protect) — the gate never blocks itself.
///   4. **Earned override** — a shaky word, or a term that wins by a large
///      margin, may still be corrected.
/// Multi-word phrase *terms* ("Claude Code") are precise and self-gating → allowed
/// (but only after plausibility).
///
/// Per-occurrence: TDT gives a separate confidence for each word occurrence
/// (no FluidAudio fork needed).
///
/// **Ported faithfully from jot-mobile** (`Jot/App/Vocabulary/VocabularyGate.swift`).
/// macOS deviations (design §6 / V4): the in-loop `DiagnosticsLog.record(...)`
/// call is dropped — `DiagnosticsLog` is iPhone-only and the gate must stay PURE
/// synchronous value logic. The `VocabularyRescorerHolder` logs each verdict to
/// the macOS `ErrorLog` from its async context instead. `CommonWords` is now
/// language-parameterized.
///
/// NOTE: thresholds below are START values. A wider on-device calibration is a
/// pre-enable task; keep the master vocabulary toggle off until calibrated.
enum VocabularyGate {

    private static let log = Logger(
        subsystem: "com.jot.Jot",
        category: "VocabularyGate"
    )

    /// A word above this TDT confidence is never auto-corrected unless the term
    /// wins by a large margin. The 0.998-"name" protector.
    static let confidenceCeiling: Float = 0.95
    /// Below this confidence a word is "unsure" enough to be override-eligible.
    static let lowConfidence: Float = 0.85
    /// Boosted CTC margin (`replacementScore − originalScore`; includes the
    /// engine's cbw≈3.0) above which a correction counts as "earned" even
    /// against a confident or common word.
    static let earnedMargin: Float = 4.0

    /// One proposal the CTC spotter surfaced, with the gate's verdict — kept so
    /// the review surface can persist it per-transcript and let the owner
    /// adjudicate each **occurrence** later.
    struct Proposal: Sendable, Equatable {
        let originalWord: String     // what TDT wrote (e.g. "Jamie")
        let term: String             // the vocab term (e.g. "Jamy")
        let decision: String         // "APPLY" | "BLOCK" | "OVERRIDE"
        let outcome: String          // "applied" (text became `term`) | "kept" (text left `original`)
        let confidence: Float
        let margin: Float
        let unsure: Bool             // gate confidence near the decision boundary
        // Slice D (ask-before-paste, §9 Option B): this proposal is a candidate
        // for the live "Did you mean X?" pill. ADDITIVE metadata only — it never
        // changes the apply/block decision above. True for exactly the two
        // intent-matched cases:
        //   (i)  a single-word term APPLIED to a non-common original the model
        //        wasn't confident about (the silent-OOV "did you mean Vikram?"),
        //        excluding obviously-confident exact matches and already-armed
        //        learned overrides (those auto-apply silently, no ask).
        //   (ii) a common-word near-miss BLOCKED by the common-word brake that is
        //        otherwise plausible (the "did you mean Lisa?" case).
        let askCandidate: Bool
        let occurrenceIndex: Int     // DISPLAY-ONLY FIFO arrival index — NOT an identity key
        // STABLE identity: char offset of the matched span in the ORIGINAL
        // (pre-rescore) transcript. Immutable provenance → safe as a verdict key.
        let originalStart: Int
        let originalLength: Int
        // Char span in the GATE-OUTPUT text. Becomes the provenance record's
        // LIVE anchor — kept valid across every later text change by
        // CorrectionProvenance's reconcile; resolution is strict (exact offset
        // or fail-safe), never proximity-guessed.
        let publishedStart: Int
        let publishedLength: Int
    }

    struct Result {
        let text: String
        let applied: Int
        let blocked: [String]        // originalWords that were protected
        let proposals: [Proposal]    // every decision, for per-transcript review (v1b)
    }

    /// Apply the gate to the rescorer output. Returns the gated transcript:
    /// each proposed replacement is re-checked and either kept or reverted to
    /// the original word. Reconstructs from `originalTranscript` (the un-boosted
    /// TDT text) so a blocked replacement cleanly leaves the original word.
    ///
    /// Replacements are resolved to their position in the transcript and applied
    /// in **positional order** — `output.replacements` is NOT left-to-right
    /// (the rescorer sorts by span length / similarity), so a forward-only pass
    /// would silently drop edits.
    ///
    /// - Parameter commonWords: the resolved-language common-word set. Pass
    ///   `CommonWords(forLanguage:)` for the active language. A missing-list
    ///   (empty) set degrades step (4) to a no-op for that language — the gate
    ///   still runs every other guard. Non-English just passes `.empty` (or an
    ///   eventual per-language list) and never crashes.
    static func apply(
        originalTranscript: String,
        output: VocabularyRescorer.RescoreOutput,
        tokenTimings: [TokenTiming],
        commonWords: CommonWords,
        overrides: [CorrectionStore.OverrideEntry] = [],
        termAliases: [String: [String]] = [:]
    ) -> Result {
        guard output.wasModified, !output.replacements.isEmpty else {
            return Result(text: output.text, applied: 0, blocked: [], proposals: [])
        }
        let wordConfidence = perWordMinConfidence(tokenTimings)

        // Resolve each replacement to a transcript range + its gate decision.
        // `occurrenceIndex` (FIFO arrival) is display-only; the STABLE identity is
        // `originalStart` (the span's char offset in the original text), computed
        // here while we still hold the authoritative range. Proposals are emitted
        // ONLY for spans that survive the positional overlap guard below, so the
        // provenance never contains a phantom record for a span that isn't in the
        // published text.
        struct Item {
            let r: VocabularyRescorer.RescoringResult
            let d: (pass: Bool, confidence: Float, margin: Float, label: String, unsure: Bool, askCandidate: Bool)
            let range: Range<String.Index>
            let originalStart: Int
            let originalLength: Int
            let occurrenceIndex: Int
            let publishedText: String   // what occupies this span in the output (term if pass, else original)
        }
        var occurrence: [String: Int] = [:]
        var items: [Item] = []

        for r in output.replacements where r.shouldReplace {
            let key = r.originalWord.lowercased()
            let n = occurrence[key, default: 0]
            guard let range = nthWholeWordRange(of: r.originalWord, in: originalTranscript, occurrence: n) else {
                continue
            }
            occurrence[key] = n + 1
            let d = decide(
                r, wordConfidence: wordConfidence, commonWords: commonWords, overrides: overrides,
                aliases: termAliases[(r.replacementWord ?? "").lowercased()] ?? [])
            log.info(
                "gate \(r.originalWord, privacy: .public)→\(r.replacementWord ?? "—", privacy: .public): conf=\(d.confidence, format: .fixed(precision: 3)) margin=\(d.margin, format: .fixed(precision: 2)) \(d.label, privacy: .public)"
            )
            items.append(
                Item(
                    r: r,
                    d: d,
                    range: range,
                    originalStart: originalTranscript.distance(from: originalTranscript.startIndex, to: range.lowerBound),
                    originalLength: originalTranscript.distance(from: range.lowerBound, to: range.upperBound),
                    occurrenceIndex: n,
                    publishedText: d.pass ? (r.replacementWord ?? r.originalWord) : String(originalTranscript[range])
                )
            )
        }

        items.sort { $0.range.lowerBound < $1.range.lowerBound }

        var result = ""
        var cursor = originalTranscript.startIndex
        var applied = 0
        var blocked: [String] = []
        var proposals: [Proposal] = []
        for item in items {
            guard item.range.lowerBound >= cursor else { continue }  // overlap guard — skip (no proposal)
            result += originalTranscript[cursor..<item.range.lowerBound]
            let publishedStart = result.count
            result += item.publishedText
            proposals.append(
                Proposal(
                    originalWord: item.r.originalWord,
                    term: item.r.replacementWord ?? item.r.originalWord,
                    decision: item.d.label,
                    outcome: item.d.pass ? "applied" : "kept",
                    confidence: item.d.confidence,
                    margin: item.d.margin,
                    unsure: item.d.unsure,
                    askCandidate: item.d.askCandidate,
                    occurrenceIndex: item.occurrenceIndex,
                    originalStart: item.originalStart,
                    originalLength: item.originalLength,
                    publishedStart: publishedStart,
                    publishedLength: item.publishedText.count
                )
            )
            if item.d.pass { applied += 1 } else { blocked.append(String(originalTranscript[item.range])) }
            cursor = item.range.upperBound
        }
        result += originalTranscript[cursor...]
        return Result(text: result, applied: applied, blocked: blocked, proposals: proposals)
    }

    // MARK: - Gate decision

    /// Returns (pass, confidence, margin, label, unsure, askCandidate). `label`
    /// is APPLY / BLOCK / OVERRIDE so the caller can log + persist the verdict.
    /// `unsure` is true when the gate's confidence sits near the decision
    /// boundary. `askCandidate` (Slice D, §9 Option B) flags the two
    /// intent-matched cases the live "Did you mean X?" pill should surface —
    /// computed at each terminal return, additive only.
    private static func decide(
        _ r: VocabularyRescorer.RescoringResult,
        wordConfidence: [String: Float],
        commonWords: CommonWords,
        overrides: [CorrectionStore.OverrideEntry],
        aliases: [String]
    ) -> (pass: Bool, confidence: Float, margin: Float, label: String, unsure: Bool, askCandidate: Bool) {
        let margin = (r.replacementScore ?? r.originalScore) - r.originalScore
        let base = normalize(r.originalWord)
        let term = r.replacementWord ?? ""
        let baseWords = base.split(separator: " ").map(String.init)
        let measured = baseWords.compactMap { wordConfidence[$0] }.min()
        let confidence = measured ?? lowConfidence
        let isCommon = baseWords.contains { commonWords.isCommon($0) }
        // Genuine acoustic uncertainty: a MEASURED confidence between "shaky" and
        // "sure". Unknown confidence (tokens missed the confidence map — common
        // for the OOV names this feature targets) is NOT unsure, so it doesn't
        // over-prioritise the keyboard asks. (NOT raw block-margin either — a
        // confident word blocked by a big margin is the gate working.)
        let unsure = measured.map { $0 >= lowConfidence && $0 < confidenceCeiling } ?? false

        // (0) USER-CONFIRMED OVERRIDE (top of the gate). A confirmed mapping
        //     fires on the spotter's proposal alone — bypassing the guards — for
        //     this exact (originalWord → term) pair only. **A common-word original
        //     is NEVER auto-applied**: silently rewriting an everyday word
        //     everywhere is the headline over-correction bug, and per-occurrence
        //     review can't undo a paste that already left the device. For common
        //     originals the gate keeps proposing-and-asking; only the UI
        //     pre-highlights the learned term. Auto-apply is reserved for
        //     rare/OOV originals (net ≥ 1) and multi-word terms (self-gating below).
        if let ov = overrides.first(where: { $0.originalWord == base && $0.term == term }) {
            // DEMOTED: the owner reverted this mapping → stop auto-applying it.
            // Works for common AND rare originals, so a wrong auto-correction the
            // owner undid stays undone.
            if ov.net <= -1 {
                return (false, confidence, margin, "BLOCK", unsure, false)
            }
            // CONFIRMED: auto-apply — rare/OOV originals only (common words never
            // auto-apply). An already-armed learned override auto-applies
            // silently — never an ask candidate (§9: "never ask pairs already
            // armed").
            if !isCommon, ov.net >= 1 {
                return (true, confidence, margin, "OVERRIDE", unsure, false)
            }
        }

        // (1) PLAUSIBILITY — the heard word must be an acoustically plausible
        //     cousin of the term (or of ANY of its aliases — an alias is the user
        //     TELLING us the pair is plausible). The CTC matcher fuzzy-matches
        //     with a low similarity floor and concatenates neighbouring words, so
        //     it can propose "Vikram"→"Sriram" or "Ramanathan"→"Ramaa" — half the
        //     letters different. No acoustic margin makes those right. Spaces are
        //     ignored in the measure so a merged ASR word ("ramanathan") scores
        //     fairly against a multi-word term ("Ramaa Nathan"). Sits after (0)
        //     so an owner-confirmed mapping (net ≥ 1) is never second-guessed,
        //     and BEFORE the multi-word fast-path so it closes that bypass too.
        if !plausible(original: base, term: term, aliases: aliases) {
            // Implausible garbage ("Vikram"→"Sriram") — never an ask candidate.
            return (false, confidence, margin, "BLOCK", unsure, false)
        }

        // (2) A multi-word vocabulary TERM is precise and self-gating. Applied
        //     silently (not single-word) → not an ask candidate per §9 (i),
        //     which scopes the silent-OOV ask to single-word terms.
        if term.contains(" ") {
            return (true, confidence, margin, "APPLY", unsure, false)
        }
        // (3) Never overwrite a very confident word unless the term wins big.
        //     A confident word blocked by a small margin is the gate working as
        //     intended (the "0.998 name" protector) — not an ask candidate.
        if confidence >= confidenceCeiling && margin <= earnedMargin {
            return (false, confidence, margin, "BLOCK", unsure, false)
        }
        // (4) Everyday word → NEVER silently rewrite. A common word is always
        //     proposed-and-asked per occurrence; the only paths that auto-apply
        //     are the rare/OOV override (step 0) and multi-word terms (step 2),
        //     both above. This is the headline "every name becomes Jamy"
        //     protection — a common original is surfaced for review, never
        //     swapped. (For a language whose common-word list is missing,
        //     `commonWords.isCommon` is always false, so this guard is a no-op.)
        if isCommon {
            // §9 Option B (ii): a common-word near-miss BLOCKED by this brake but
            // otherwise plausible (we passed the plausibility guard above) and a
            // single-word term — the "did you mean Lisa?" case. We surface the
            // ask so the user can choose the term this time (a confirm learns it,
            // though the gate still won't auto-apply a common original — see
            // CorrectionStore). Multi-word terms already returned at step (2).
            return (false, confidence, margin, "BLOCK", unsure, true)
        }
        // (5) OOV-ish word (a likely name/jargon mis-hear) → allow.
        //     §9 Option B (i): single-word term APPLIED to a non-common original
        //     the model wasn't confident about. We reach here only when the
        //     confidence ceiling (3) did NOT block, i.e. confidence is below the
        //     ceiling (or the measured confidence is unknown — typical for the
        //     OOV names this targets, where `confidence == lowConfidence`). That
        //     is exactly the silent-OOV "did you mean Vikram?" ask.
        return (true, confidence, margin, "APPLY", unsure, true)
    }

    // MARK: - Plausibility (guard 1)

    /// Max normalized edit distance (Levenshtein over letter-skeletons, divided
    /// by the longer skeleton) for the heard word to count as an acoustic cousin
    /// of the term. Measured on real pairs: shriram→sriram 0.14, cloud→claude
    /// 0.33, jamie→jamy 0.40 (all pass); vikram→sriram 0.50, ramanathan→ramaa
    /// 0.50, name→jamy 0.50 (all block).
    static let plausibilityCeiling: Double = 0.45

    private static func plausible(original: String, term: String, aliases: [String]) -> Bool {
        let heard = skeleton(original)
        guard !heard.isEmpty else { return true }
        for candidate in [term] + aliases {
            let c = skeleton(candidate)
            guard !c.isEmpty else { continue }
            let ratio = Double(levenshtein(heard, c)) / Double(max(heard.count, c.count))
            if ratio <= plausibilityCeiling { return true }
        }
        return false
    }

    /// Lowercased alphanumerics only — spaces and punctuation dropped so a
    /// merged ASR word ("ramanathan") measures fairly against a multi-word
    /// term ("Ramaa Nathan" → "ramaanathan").
    private static func skeleton(_ s: String) -> [Character] {
        s.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init)
    }

    /// Plain two-row Levenshtein. Inputs are short (words/short phrases), so
    /// O(a·b) is trivially cheap even on the transcription hot path.
    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // MARK: - Helpers

    private static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:\"'()"))
    }

    /// Per-word minimum *content-token* confidence, keyed by lowercased word.
    /// A new word begins at a token with a leading space / `▁` boundary; the
    /// minimum is taken over alphabetic (content) tokens only — punctuation and
    /// casing tokens would otherwise produce false low-confidence flags. When a
    /// word repeats, the lowest occurrence's confidence is kept (conservative).
    private static func perWordMinConfidence(_ timings: [TokenTiming]) -> [String: Float] {
        var out: [String: Float] = [:]
        var word = ""
        var minConf: Float = 1.0

        func flush() {
            let key = normalize(word)
            if !key.isEmpty {
                out[key] = min(out[key] ?? 1.0, minConf)
            }
            word = ""
            minConf = 1.0
        }

        for t in timings {
            let startsWord = t.token.hasPrefix(" ") || t.token.hasPrefix("\u{2581}")
            let piece = t.token
                .replacingOccurrences(of: "\u{2581}", with: "")
                .trimmingCharacters(in: .whitespaces)
            if startsWord { flush() }
            word += piece
            if piece.rangeOfCharacter(from: .letters) != nil {
                minConf = min(minConf, t.confidence)
            }
        }
        flush()
        return out
    }

    /// The `occurrence`-th (0-based) whole-word range of `word` in `text`.
    private static func nthWholeWordRange(
        of word: String,
        in text: String,
        occurrence n: Int
    ) -> Range<String.Index>? {
        var search = text.startIndex
        var count = 0
        while let r = wholeWordRange(of: word, in: text, from: search) {
            if count == n { return r }
            count += 1
            search = r.upperBound
        }
        return nil
    }

    /// Whole-word range of `word` in `text` at/after `from` (so "name" does not
    /// match inside "rename"). `word` may itself be a multi-word phrase.
    private static func wholeWordRange(
        of word: String,
        in text: String,
        from: String.Index
    ) -> Range<String.Index>? {
        var search = from
        while let r = text.range(of: word, options: [.caseInsensitive], range: search..<text.endIndex) {
            let before: Character? = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after: Character? = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            let okBefore = !(before?.isLetter ?? false)
            let okAfter = !(after?.isLetter ?? false)
            if okBefore && okAfter { return r }
            search = r.upperBound
        }
        return nil
    }
}
