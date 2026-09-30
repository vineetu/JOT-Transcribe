import Foundation
import JotVocabCore
import SwiftData

/// The text edit that answers one gated occurrence — a review pick or Undo in
/// `CorrectionReviewModel`, or a live "Did you mean…?" answer in
/// `DictationDeliveryBridge`. One path, so the pane and the pill always edit
/// the same occurrence the same way: the edit goes through
/// `RecordingTextMutation` (save, speaker segments, search, detail reload)
/// and its exact span is reported to the provenance actor.
@MainActor
enum ReviewRecordEdit {

    /// `word` at `record`'s reconciled anchor in `text` — nil when that
    /// occurrence was edited away (never a guessed repeat of the word).
    static func anchoredRange(of word: String, for record: CorrectionProvenance.Record,
                              in text: String) -> Range<String.Index>? {
        WholeWord.range(of: word, at: record.publishedStart, in: text)
    }

    /// Replace `range` (UTF-16) of the recording's transcript with
    /// `replacement`. When the edit answers `record`, its span is reported to
    /// the provenance actor: anchors shift by report, never by diff inference,
    /// for our own edits (a diff is ambiguous when the replacement shares a
    /// suffix with the replaced word, "nathan" → "Ramanathan", and would shift
    /// the record off its word, breaking Undo). Returns whether the text
    /// changed.
    @discardableResult
    static func replace(
        _ range: NSRange,
        with replacement: String,
        answering record: CorrectionProvenance.Record?,
        in recording: Recording,
        context: ModelContext
    ) async -> Bool {
        let text = recording.transcript
        guard let swiftRange = Range(range, in: text) else { return false }
        let replaced = String(text[swiftRange])
        guard replaced != replacement,
              let change = try? RecordingTextMutation.apply(
                .replace(range, with: replacement, expecting: replaced),
                to: recording, in: context)
        else { return false }
        if let record {
            await CorrectionProvenance.shared.noteSelfEdit(
                transcriptID: change.recordingID, recordKey: record.key,
                start: text.distance(from: text.startIndex, to: swiftRange.lowerBound),
                oldLength: replaced.count, newLength: replacement.count,
                newText: change.newText)
        }
        return true
    }
}
