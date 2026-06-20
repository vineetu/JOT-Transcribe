import SwiftData
import SwiftUI

/// Shared state + actions for the correction-review surface in
/// `RecordingDetailView` (the summary-row + accordion). Owns the per-occurrence
/// text-edit anchoring in ONE place so verdict picks and the displayed rows stay
/// in sync (plan §v2-C/F). The model is created by `RecordingDetailView` and
/// drives `CorrectionReviewSection`.
///
/// **Ported from jot-mobile** (`Jot/App/Vocabulary/CorrectionReviewModel.swift`),
/// MVP adaptations:
///   - `Transcript` → `Recording` (`.text` → `.transcript`, same `.id`).
///   - Dropped the iPhone keyboard-sync lines (`TranscriptHistoryMirror` /
///     `CrossProcessNotification`) — no macOS analogue.
///   - Dropped `marks()` / `flash` / `flashSpan` — the inline `NSTextView`
///     underline marks + flash wash are deferred (review-ux.md §1 "Later").
///     The reconcile / verdict / edit logic is otherwise byte-for-byte the same.
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
        guard let range = resolveSpan(word: word, offset: r.publishedStart, in: text)
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
    /// CURRENT transcript text (hand-edits, keyboard-verdict drains, and this
    /// model's own verdict edits all shift anchors through the same diff).
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
        // kept + term → apply the term here; applied + original → revert here.
        if choice == "term", r.outcome == "kept" {
            await reportSelfEdit(editText(r, find: r.originalWord, replaceWith: r.term), key: r.key)
        } else if choice == "original", r.outcome == "applied" {
            await reportSelfEdit(editText(r, find: r.term, replaceWith: r.originalWord), key: r.key)
        }
        let delta = await CorrectionProvenance.shared.setVerdict(transcriptID: recording.id, record: r, verdict: choice)
        await applyLearning(delta)
        // "Keep original" on a BLOCKED pair contributes 0 to `net` (demote needs an
        // APPLIED revert), so a common-word proposal like "okay"→"Okta" would be
        // re-asked forever no matter how often it's rejected. Count it separately so
        // the keyboard stops re-asking after `keyboardKeepSuppressThreshold` keeps.
        // Keyboard-only suppression (inert on macOS); the transcript pane still
        // surfaces it. Kept for file parity + so a future keyboard never drifts.
        // Guard on a genuine transition INTO "original" so a re-pick of the same
        // verdict can't double-count (the increment is otherwise non-idempotent).
        if choice == "original", r.outcome == "kept", priorVerdict != "original" {
            await CorrectionStore.shared.noteBlockedKeep(originalWord: r.originalWord, term: r.term)
        }
        await reload()
    }

    func undo(_ r: CorrectionProvenance.Record) async {
        await reload()   // actor truth + anchor reconcile before the reverse edit (see pick)
        let r = record(forKey: r.key) ?? r
        let v = payload.verdicts[r.key]
        if v == "term", r.outcome == "kept" {
            await reportSelfEdit(editText(r, find: r.term, replaceWith: r.originalWord), key: r.key)
        } else if v == "original", r.outcome == "applied" {
            await reportSelfEdit(editText(r, find: r.originalWord, replaceWith: r.term), key: r.key)
        }
        let delta = await CorrectionProvenance.shared.clearVerdict(transcriptID: recording.id, record: r)
        await applyLearning(delta)
        // Symmetric with the blocked-keep increment in `pick`: undoing a "keep
        // original" on a blocked pair gives back its `blockedKeeps`, so the keyboard
        // suppression count never drifts above the real number of standing keeps.
        if v == "original", r.outcome == "kept" {
            await CorrectionStore.shared.clearBlockedKeep(originalWord: r.originalWord, term: r.term)
        }
        await reload()
    }

    /// Hand the exact span of one of OUR OWN edits to the provenance actor —
    /// anchors shift by report, never by diff-inference, for self edits (a diff
    /// is ambiguous when replacement and replaced word share a suffix, e.g.
    /// "nathan" → "Ramanathan", and would shift this record's anchor off its
    /// own word, breaking Undo).
    private func reportSelfEdit(_ edit: SelfEdit?, key: String) async {
        guard let edit else { return }
        await CorrectionProvenance.shared.noteSelfEdit(
            transcriptID: recording.id, recordKey: key,
            start: edit.start, oldLength: edit.oldLength,
            newLength: edit.newLength, newText: edit.newText)
    }

    /// Move the mapping's global learning net by the provenance-computed delta.
    private func applyLearning(_ delta: CorrectionProvenance.MappingDelta?) async {
        guard let d = delta else { return }
        await CorrectionStore.shared.adjust(originalWord: d.originalWord, term: d.term, by: d.delta)
    }

    // MARK: - Deterministic per-occurrence text edit (plan §v2-A)

    /// What one verdict edit did to the text, in Character offsets — reported
    /// to the provenance actor so anchors shift exactly (see `reportSelfEdit`).
    struct SelfEdit {
        let start: Int
        let oldLength: Int
        let newLength: Int
        let newText: String
    }

    private func editText(_ r: CorrectionProvenance.Record, find word: String, replaceWith replacement: String) -> SelfEdit? {
        let text = recording.transcript
        // STRICT resolution only — if the word isn't EXACTLY at its reconciled
        // anchor, the user edited it away; record the verdict (learning) but
        // never edit a guessed span. The old nearest-match fallback here is what
        // fired verdict edits on the WRONG occurrence after a hand-edit.
        guard let target = resolveSpan(word: word, offset: r.publishedStart, in: text) else { return nil }
        var newText = text
        newText.replaceSubrange(target, with: replacement)
        guard newText != text else { return nil }
        recording.transcript = newText
        do {
            try modelContext.save()
            return SelfEdit(
                start: text.distance(from: text.startIndex, to: target.lowerBound),
                oldLength: text.distance(from: target.lowerBound, to: target.upperBound),
                newLength: replacement.count,
                newText: newText)
        } catch {
            modelContext.rollback()
            return nil
        }
    }

    /// Whole-word span of `word` starting EXACTLY at `offset` — nil otherwise.
    /// Strict only: `publishedStart` anchors are reconciled to the live text at
    /// every reload, so an exact miss means the span was genuinely edited away.
    /// Fail safe (no edit) rather than guess a repeat of the same word.
    private func resolveSpan(word: String, offset: Int, in text: String) -> Range<String.Index>? {
        let needle = word.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?\"'\u{2019}\u{201D})]}"))
        guard !needle.isEmpty else { return nil }
        return Self.wholeWordRanges(of: needle, in: text)
            .first { text.distance(from: text.startIndex, to: $0.lowerBound) == offset }
    }

    /// Every whole-word, case-insensitive occurrence of `word` in `text`.
    static func wholeWordRanges(of word: String, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var search = text.startIndex
        while let r = text.range(of: word, options: [.caseInsensitive], range: search..<text.endIndex) {
            let before: Character? = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after: Character? = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            if !(before?.isLetter ?? false) && !(after?.isLetter ?? false) { ranges.append(r) }
            search = r.upperBound
            if search == text.endIndex { break }
        }
        return ranges
    }
}
