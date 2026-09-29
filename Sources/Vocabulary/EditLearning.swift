import Foundation
import JotVocabCore

/// **Learn from transcript edits** (design `docs/vocabulary-learn-from-edits/
/// design.md`). The Mac side of `JotVocabCore.EditLearner`: turns one finished
/// edit session (the transcript when Edit was pressed vs. what was saved) into
/// vocabulary adds and correction-store counts.
///
/// `RecordingDetailView.finishEdit` is the only caller. It captures every
/// string up front, so a sidebar navigation that rebinds the view to another
/// recording can't feed this the wrong text.
@MainActor
enum EditLearning {

    static func learn(recordingID: UUID, before: String, after: String, raw: String) async {
        guard before != after else { return }
        // No everyday-word list for the active language ⇒ no D8 brake, so
        // nothing is learned — the same rule the model-free corrector follows.
        guard MacVocabCore.hasActiveCommonWords else { return }
        let store = CorrectionStore.shared
        let vocabulary = VocabularyStore.shared
        let terms = vocabulary.terms
        // The diff is pure and can be long (a meeting): off the main actor.
        let lessons = await Task.detached(priority: .utility) {
            EditLearner.learn(
                before: before, after: after, raw: raw, vocabulary: terms,
                isCommonWord: { MacVocabCore.isCommonOriginal($0) })
        }.value
        guard !lessons.isEmpty else { return }

        for lesson in lessons {
            switch lesson {
            case .substitute(let original, let term, let heardByModel):
                await store.recordEdit(
                    originalWord: original, term: term, direction: .toward, heardByModel: heardByModel)
                let common = store.refusesLearning(originalWord: original)
                // Same add as the "Add to Vocabulary" button (D3). A common
                // original is NOT stored as an alias: an alias "cloud" would make
                // the CTC gate hold pastes and ask on every genuine "cloud", and
                // aliases never reach the decoder's bias anyway.
                if common {
                    vocabulary.addTerm(term)
                } else {
                    vocabulary.addMapping(heard: original, term: term)
                }
                // The user's casing wins over an existing term's ("claude").
                vocabulary.recase(term)
                await store.recase(term: term)
                // Rare original: today's text rule (arms at net ≥ 1) through a
                // normal confirm — unless an open review record for this pair
                // just carried that count.
                let closed = await closeReviewRecords(
                    recordingID: recordingID, currentText: after,
                    original: original, term: term, verdict: "term", applyLearning: !common)
                if !common, !closed {
                    await store.confirm(originalWord: original, term: term)
                }
            case .reverse(let original, let term):
                await store.recordEdit(originalWord: original, term: term, direction: .away)
                let common = store.refusesLearning(originalWord: original)
                // A rare pair disarms through a normal revert. A common pair
                // never goes through revert (net −1 would lock it — the edit
                // counters carry its signal).
                let closed = await closeReviewRecords(
                    recordingID: recordingID, currentText: after,
                    original: original, term: term, verdict: "original", applyLearning: !common)
                if !common, !closed {
                    await store.revert(originalWord: original, term: term)
                }
            case .recase(let term):
                vocabulary.recase(term)
                await store.recase(term: term)
            }
        }
        await ErrorLog.shared.info(
            component: "VocabularyGate",
            message: "learned from transcript edit",
            context: ["lessons": "\(lessons.count)"])
    }

    /// Close this recording's still-open review records for `(original →
    /// term)` with `verdict`, so the pane can't count the pair a second time.
    /// The provenance deltas reach the store's net only when `applyLearning`
    /// (rare originals). Returns whether any record was closed.
    private static func closeReviewRecords(
        recordingID: UUID, currentText: String,
        original: String, term: String, verdict: String, applyLearning: Bool
    ) async -> Bool {
        let provenance = CorrectionProvenance.shared
        let payload = await provenance.reconciledPayload(transcriptID: recordingID, currentText: currentText)
        let open = payload.records.filter {
            payload.verdicts[$0.key] == nil
                && CorrectionKey.normalize($0.originalWord) == original
                && $0.term.lowercased() == term.lowercased()
        }
        for record in open {
            let deltas = await provenance.setVerdict(
                transcriptID: recordingID, record: record, verdict: verdict, fromEdit: true)
            guard applyLearning else { continue }
            for d in deltas {
                await CorrectionStore.shared.adjust(originalWord: d.originalWord, term: d.term, by: d.delta)
            }
        }
        return !open.isEmpty
    }
}

/// What the Nemotron Multilingual decoder is biased with: canonical terms at
/// their learned weight, and the learned `(original → term)` pairs.
enum NemotronBiasVocabulary {

    /// Canonical terms only (never aliases — the decoder boosts an alias as
    /// itself), each at the base weight or, once the user has corrected toward
    /// it, the learned strength (≤ `CorrectionStore.learnedBiasStrength`).
    /// Empty when vocabulary boosting is off or not yet prepared.
    static func terms() async -> [NemotronBiasTerm] {
        let canonical = await VocabularyRescorerHolder.shared.canonicalTerms
        guard !canonical.isEmpty else { return [] }
        let learned = await CorrectionStore.shared.learnedStrengths()
        return canonical.map {
            NemotronBiasTerm(
                text: $0,
                weight: learned[$0.lowercased()] ?? NemotronMultilingualStreamingTranscriber.vocabularyBiasWeight)
        }
    }

    /// Active learned pairs whose term is in the live vocabulary — so turning
    /// boosting off, or deleting the term, drops its pairs too.
    static func learnedPairs() async -> [CorrectionStore.LearnedPair] {
        let canonical = Set(await VocabularyRescorerHolder.shared.canonicalTerms.map { $0.lowercased() })
        guard !canonical.isEmpty else { return [] }
        return await CorrectionStore.shared.learnedPairs().filter { canonical.contains($0.term.lowercased()) }
    }
}
