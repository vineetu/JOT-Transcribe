import Foundation
import JotVocabCore
import SwiftData

/// **Re-transcribe a saved recording** — the ONE path the Recents list row and
/// the recording detail view share, so both leave identical state:
///   - the new text and raw text land through `RecordingTextMutation`
///     (`.machineText`): auto-title recomputed, AI summary marked stale,
///     search re-indexed, "edited" / "pending" cleared, open views told;
///   - the speaker segments are cleared — they describe the old text
///     (diarization is manual, design D4: the user re-taps "Detect speakers");
///   - the old review records and verdicts are replaced by this pass's gate
///     proposals, with what the old verdicts taught taken back (their
///     mapping contributions reversed, exactly as an Undo would).
@MainActor
enum RecordingRetranscription {

    enum RetranscribeError: LocalizedError {
        case dictationInProgress
        case beingEdited
        var errorDescription: String? {
            switch self {
            case .dictationInProgress: "Finish dictating first, then try again."
            case .beingEdited: "Finish editing this transcript first, then try again."
            }
        }
    }

    static func retranscribe(
        _ recording: Recording,
        using transcriber: any Transcribing,
        context: ModelContext
    ) async throws {
        // Mic → re-transcribe guard (mirrors `FileTranscriptionIngest.enqueue`
        // guard 2): on the multilingual Nemotron ship this shares the live
        // streaming engine with dictation, so starting mid-dictation would
        // collide (`TranscriberError.busy` at best, interleaved decoder state
        // at worst). Callers surface the error in their re-transcribe alert
        // instead of silently dropping the tap. `shared == nil` (ingest not
        // built yet) falls through — the engine-level busy guard still protects.
        guard FileTranscriptionIngest.shared?.recorderIsCurrentlyIdle ?? true else {
            throw RetranscribeError.dictationInProgress
        }
        // An open edit (or a draft kept from a failed save / a quit) would be
        // overwritten by the new text: the user's draft comes first.
        guard !TranscriptEditSessions.shared.isOpen(recording.id) else {
            throw RetranscribeError.beingEdited
        }
        let id = recording.id
        let url = RecordingStore.audioURL(for: recording)
        // Owns the shared provenance slot: this pass's gate proposals are
        // swapped in under the same recording id below.
        let result = try await transcriber.transcribeFile(url, recordsProvenance: true)
        // Deleted while transcribing: nothing to update, and this pass's
        // proposals must not be committed under anything.
        guard RecordingStore.recording(id: id, in: context) != nil else {
            await CorrectionProvenance.shared.clearPending()
            return
        }
        let deltas = await CorrectionProvenance.shared.replaceRecords(transcriptID: id)
        for d in deltas {
            await CorrectionStore.shared.adjust(originalWord: d.originalWord, term: d.term, by: d.delta)
        }
        // Re-fetch after the awaits: the row may have been deleted meanwhile.
        guard let row = RecordingStore.recording(id: id, in: context) else {
            await CorrectionProvenance.shared.discard(transcriptID: id)
            return
        }
        try RecordingTextMutation.apply(
            .machineText(result.text, raw: result.rawText),
            to: row, in: context, timeline: .clear)
    }
}
