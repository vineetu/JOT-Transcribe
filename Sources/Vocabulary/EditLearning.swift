import Foundation
import JotVocabCore

/// **Learn from transcript edits** (design `docs/vocabulary-learn-from-edits/
/// design.md`). The Mac side of `JotVocabCore.EditLearner`: turns one finished
/// edit session (the transcript when Edit was pressed vs. what was saved) into
/// `Correction`s for `VocabularyLearning.apply`, the one path every correction
/// surface takes (Revision 2).
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
        let terms = VocabularyStore.shared.terms
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
                let common = store.refusesLearning(originalWord: original)
                let open = await openReviewRecords(
                    recordingID: recordingID, currentText: after, original: original, term: term)
                // The user typed the spelling, so its casing wins.
                let receipt = await VocabularyLearning.shared.apply(.correct(
                    heard: original, term: term, heardByModel: heardByModel, userCasing: true))
                await close(open, recordingID: recordingID, verdict: "term",
                            applyLearning: !common, receipt: receipt)
            case .reverse(let original, let term):
                let common = store.refusesLearning(originalWord: original)
                let open = await openReviewRecords(
                    recordingID: recordingID, currentText: after, original: original, term: term)
                let receipt = await VocabularyLearning.shared.apply(.keepOriginal(heard: original, term: term))
                await close(open, recordingID: recordingID, verdict: "original",
                            applyLearning: !common, receipt: receipt)
                // Ask ranking prior (not learning): a rare pair's net drops
                // through a normal revert; a common pair's never goes positive.
                if !common, open.isEmpty {
                    await store.revert(originalWord: original, term: term)
                }
            case .recase(let term):
                await VocabularyLearning.shared.apply(.recase(term))
            }
        }
        await ErrorLog.shared.info(
            component: "VocabularyGate",
            message: "learned from transcript edit",
            context: ["lessons": "\(lessons.count)"])
    }

    /// This recording's still-open review records for `(original → term)`.
    private static func openReviewRecords(
        recordingID: UUID, currentText: String, original: String, term: String
    ) async -> [CorrectionProvenance.Record] {
        let payload = await CorrectionProvenance.shared.reconciledPayload(
            transcriptID: recordingID, currentText: currentText)
        return payload.records.filter {
            payload.verdicts[$0.key] == nil
                && CorrectionKey.normalize($0.originalWord) == original
                && $0.term.lowercased() == term.lowercased()
        }
    }

    /// Close `records` with `verdict`, so the pane can't count the pair a
    /// second time. The provenance deltas reach the store's net (the ask
    /// ranking prior) only when `applyLearning` (rare originals). The first record keeps the lesson's
    /// receipt for the pane's Undo — one lesson, one undo.
    private static func close(
        _ records: [CorrectionProvenance.Record], recordingID: UUID, verdict: String,
        applyLearning: Bool, receipt: VocabularyLearning.Receipt
    ) async {
        for (i, record) in records.enumerated() {
            let deltas = await CorrectionProvenance.shared.setVerdict(
                transcriptID: recordingID, record: record, verdict: verdict, fromEdit: true,
                receipt: i == 0 ? receipt : nil)
            guard applyLearning else { continue }
            for d in deltas {
                await CorrectionStore.shared.adjust(originalWord: d.originalWord, term: d.term, by: d.delta)
            }
        }
    }
}

/// What the Nemotron Multilingual decoder is biased with, derived from the
/// vocabulary list alone (`DecoderVocabulary`, Revision 2 review #1, #9):
/// canonical terms, each at the paired weight when it has an active decoder
/// pair, and the pairs (single-word sounds-likes the user hasn't paused).
enum NemotronBiasVocabulary {

    /// Empty when vocabulary is off. Read from the list itself, not the CTC
    /// holder (which rebuilds asynchronously and is empty until its model is
    /// prepared).
    static func current() async -> DecoderVocabulary {
        let list: [VocabTerm]? = await MainActor.run {
            VocabularyStore.shared.isEnabled ? VocabularyStore.shared.terms : nil
        }
        guard let list, !list.isEmpty else { return DecoderVocabulary() }
        let paused = await CorrectionStore.shared.pausedPairKeys()
        return DecoderVocabulary.derive(from: list, pausedPairKeys: paused)
    }
}
