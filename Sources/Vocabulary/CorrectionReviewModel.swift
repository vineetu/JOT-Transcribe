import JotVocabCore
import SwiftData
import SwiftUI

/// Shared state + actions for the correction-review surface in
/// `RecordingDetailView` (the summary-row + accordion). Verdict picks edit the
/// text through `ReviewRecordEdit` — the same per-occurrence path the live ask
/// uses — so picks, the live ask, and the displayed rows stay in sync (plan
/// §v2-C/F). The model is created by `RecordingDetailView` and drives
/// `CorrectionReviewSection`.
///
/// **Ported from jot-mobile** (`Jot/App/Vocabulary/CorrectionReviewModel.swift`),
/// MVP adaptations:
///   - `Transcript` → `Recording` (`.text` → `.transcript`, same `.id`).
///   - Dropped the iPhone keyboard-sync lines (`TranscriptHistoryMirror` /
///     `CrossProcessNotification`) — no macOS analogue.
///   - Dropped `marks()` / `flash` / `flashSpan` — the inline `NSTextView`
///     underline marks + flash wash are deferred (review-ux.md §1 "Later").
///   - The text edit goes through `RecordingTextMutation` (via
///     `ReviewRecordEdit`), like every other writer of a recording's text.
@MainActor
@Observable
final class CorrectionReviewModel {
    let recording: Recording
    private let modelContext: ModelContext
    var payload = CorrectionProvenance.Payload()
    var accordionExpanded = false

    init(recording: Recording, modelContext: ModelContext) {
        self.recording = recording
        self.modelContext = modelContext
    }

    // MARK: - Derived reads

    var records: [CorrectionProvenance.Record] { payload.records }
    func verdict(of r: CorrectionProvenance.Record) -> String? { payload.verdicts[r.key] }
    func record(forKey key: String) -> CorrectionProvenance.Record? { records.first { $0.key == key } }
    var unresolvedCount: Int { records.filter { payload.verdicts[$0.key] == nil }.count }
    var allReviewed: Bool { !records.isEmpty && unresolvedCount == 0 }

    /// Spoken-context snippet around record `r`'s LIVE span — a few words before
    /// the gated word and a few after — so an accordion row can show WHICH
    /// occurrence it's about (otherwise three "name" rows are indistinguishable).
    /// Returns (before, gated, after) with ellipses; nil if the span can't be
    /// resolved exactly (e.g. the body was hand-edited).
    func context(for r: CorrectionProvenance.Record, window: Int = 28)
        -> (before: String, gated: String, after: String)? {
        let text = recording.transcript
        let word = r.outcome == "applied" ? r.term : r.originalWord
        guard let range = ReviewRecordEdit.anchoredRange(of: word, for: r, in: text)
        else { return nil }
        let beforeStart = text.index(range.lowerBound, offsetBy: -window, limitedBy: text.startIndex) ?? text.startIndex
        let afterEnd = text.index(range.upperBound, offsetBy: window, limitedBy: text.endIndex) ?? text.endIndex
        var before = String(text[beforeStart..<range.lowerBound])
        var after = String(text[range.upperBound..<afterEnd])
        if beforeStart != text.startIndex { before = "\u{2026}" + before }
        if afterEnd != text.endIndex { after += "\u{2026}" }
        return (before, String(text[range]), after)
    }

    // MARK: - Load

    /// Refresh from the actor truth, reconciling every record's anchor to the
    /// CURRENT transcript text (hand-edits, live-ask answers, and this model's
    /// own verdict edits all shift anchors through the same reconcile). The
    /// detail view also calls this whenever `RecordingTextMutation` reports a
    /// change to this recording from anywhere else.
    func reload() async {
        payload = await CorrectionProvenance.shared.reconciledPayload(
            transcriptID: recording.id, currentText: recording.transcript)
    }

    // MARK: - Verdicts

    func pick(_ r: CorrectionProvenance.Record, choice: String) async {
        // Refresh from the actor truth FIRST (reconciles anchors), then re-fetch
        // the record by its stable key — the `r` the view handed us is a SNAPSHOT
        // whose `publishedStart` may have just been shifted by the reconcile.
        await reload()
        let r = record(forKey: r.key) ?? r
        let priorVerdict = payload.verdicts[r.key]   // for the blocked-keep transition guard below
        // Verdicts here are only term / original — see CorrectionReviewSection.
        // kept + term → apply the term here; applied + original → revert here.
        if choice == "term", r.outcome == "kept" {
            await editOccurrence(of: r, find: r.originalWord, replaceWith: r.term)
        } else if choice == "original", r.outcome == "applied" {
            await editOccurrence(of: r, find: r.term, replaceWith: r.originalWord)
        }
        // Learning (Revision 2): picking the term is a correction, keeping the
        // original pauses the pair — one `VocabularyLearning.apply`, the path
        // every surface takes. Once per pair per recording, on a genuine
        // transition (a re-pick, or a sibling occurrence already answered here
        // or by the live pill, has counted it).
        // The receipt is stored under this verdict so Undo reverses exactly it
        // (a switch term → original keeps the term pick's receipt too).
        var receipt: VocabularyLearning.Receipt?
        if priorVerdict != choice,
           !payload.records.contains(where: {
               $0.key != r.key && $0.mappingKey == r.mappingKey && payload.verdicts[$0.key] == choice
           }) {
            if choice == "term" {
                receipt = await VocabularyLearning.shared.apply(
                    .correct(heard: r.originalWord, term: r.term))
            } else if choice == "original" {
                receipt = await VocabularyLearning.shared.apply(
                    .keepOriginal(heard: r.originalWord, term: r.term))
            }
        }
        let delta = await CorrectionProvenance.shared.setVerdict(
            transcriptID: recording.id, record: r, verdict: choice, receipt: receipt)
        await applyLearning(delta)
        // "Keep original" on a BLOCKED pair contributes 0 to `net` (demote needs an
        // APPLIED revert), so a common-word proposal like "okay"→"Okta" would be
        // re-asked forever no matter how often it's rejected. Count it separately:
        // the live ask's suppression gate stops re-asking after
        // `keyboardKeepSuppressThreshold` keeps (the transcript pane still
        // surfaces it). Guard on a genuine transition INTO "original" so a
        // re-pick of the same verdict can't double-count (the increment is
        // otherwise non-idempotent).
        if choice == "original", r.outcome == "kept", priorVerdict != "original" {
            await CorrectionStore.shared.noteBlockedKeep(originalWord: r.originalWord, term: r.term)
        }
        await reload()
    }

    func undo(_ r: CorrectionProvenance.Record) async {
        await reload()   // actor truth + anchor reconcile before the reverse edit (see pick)
        let r = record(forKey: r.key) ?? r
        let v = payload.verdicts[r.key]
        // What this occurrence's verdicts taught (a pick, a live-pill answer,
        // or a transcript edit that closed it), per verdict.
        let receipts = payload.receipts(for: r)
        // An edit-closed verdict's net delta reached the store only for rare
        // originals (a common pair's −1 would lock it).
        let editClosed = payload.isEditClosed(r)
        let common = CorrectionStore.shared.refusesLearning(originalWord: r.originalWord)
        if v == "term", r.outcome == "kept" {
            await editOccurrence(of: r, find: r.term, replaceWith: r.originalWord)
        } else if v == "original", r.outcome == "applied" {
            await editOccurrence(of: r, find: r.originalWord, replaceWith: r.term)
        } else if v == "alt0", let alt = r.alternates?.first {
            // The live ask's wider alternate: its edit is anchored at the record.
            await editOccurrence(of: r, find: alt.term, replaceWith: alt.find)
        }
        let delta = await CorrectionProvenance.shared.clearVerdict(transcriptID: recording.id, record: r)
        if !(editClosed && common) { await applyLearning(delta) }
        // Symmetric with the blocked-keep increment in `pick`: undoing a "keep
        // original" on a blocked pair gives back its `blockedKeeps`, so the
        // suppression count never drifts above the real number of standing keeps.
        if v == "original", r.outcome == "kept" {
            await CorrectionStore.shared.clearBlockedKeep(originalWord: r.originalWord, term: r.term)
        }
        // Reverse each lesson — the current verdict's first (it is the latest) —
        // unless a sibling occurrence of the same pair still holds that verdict:
        // then the lesson still stands, and moves to the sibling for its Undo.
        let ordered = receipts.filter { $0.key == v } + receipts.filter { $0.key != v }
        for (verdict, receipt) in ordered {
            if let sibling = payload.records.first(where: {
                $0.key != r.key && $0.mappingKey == r.mappingKey && payload.verdicts[$0.key] == verdict
            }) {
                await CorrectionProvenance.shared.attachReceipt(
                    receipt, verdict: verdict, transcriptID: recording.id, record: sibling)
            } else {
                await VocabularyLearning.shared.apply(.undo(receipt))
            }
        }
        await reload()
    }

    /// Move the mapping's global learning net by the provenance-computed deltas.
    /// The package's `setVerdict`/`clearVerdict` now return `[MappingDelta]` (an
    /// alt0 verdict reconciles the base pair AND the chosen alternate's mapping),
    /// so apply each rather than a single optional.
    private func applyLearning(_ deltas: [CorrectionProvenance.MappingDelta]) async {
        for d in deltas {
            await CorrectionStore.shared.adjust(originalWord: d.originalWord, term: d.term, by: d.delta)
        }
    }

    // MARK: - Deterministic per-occurrence text edit (plan §v2-A)

    /// Replace `word` at `r`'s anchored span. STRICT resolution only — if the
    /// word isn't EXACTLY at its reconciled anchor, the user edited it away;
    /// the verdict is still recorded (learning) but a guessed span is never
    /// edited (the old nearest-match fallback fired verdict edits on the WRONG
    /// occurrence after a hand-edit).
    private func editOccurrence(of r: CorrectionProvenance.Record, find word: String,
                                replaceWith replacement: String) async {
        let text = recording.transcript
        guard let target = ReviewRecordEdit.anchoredRange(of: word, for: r, in: text) else { return }
        await ReviewRecordEdit.replace(NSRange(target, in: text), with: replacement, answering: r,
                                       in: recording, context: modelContext)
    }
}
