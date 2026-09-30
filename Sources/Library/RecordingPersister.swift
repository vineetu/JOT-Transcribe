import Combine
import Foundation
import JotVocabCore
import SwiftData
import os.log

/// Writes the `Recording` row for each finished dictation. Lives on the main
/// actor because the `ModelContext` for the UI is main-actor bound.
///
/// A successful dictation is persisted by `DictationDeliveryBridge` — the ONE
/// `$lastResult` sink — through `persistDictation(...)`, which hands the row
/// back so its id travels with the text to the paste (and to any "Did you
/// mean…?" answer that edits it). This type subscribes itself only to the
/// failure edge, `$pendingFailedRecording`.
@MainActor
final class RecordingPersister {
    private let log = Logger(subsystem: "com.jot.Jot", category: "RecordingPersister")
    private let recorder: RecorderController
    private let context: ModelContext
    /// Phase 3 F4: model id is read off the holder per persist call (not
    /// snapshotted at init), so a swap mid-session stamps subsequent rows
    /// with the new id without rebinding the persister.
    private let holder: TranscriberHolder
    /// "Never lose audio" safety net (docs/resilient-transcription/design.md).
    /// `RecorderController.$pendingFailedRecording` fires when a recorder
    /// dictation's transcription throws after the WAV was already finalized.
    private var pendingCancellable: AnyCancellable?

    /// A freshly saved dictation: its row, and the commit of the gate's
    /// review records under the row's id (a live ask waits for it before it
    /// marks a record answered).
    struct SavedDictation {
        let recording: Recording
        let provenanceCommitted: Task<Void, Never>
    }

    init(
        recorder: RecorderController,
        context: ModelContext,
        transcriberHolder: TranscriberHolder
    ) {
        self.recorder = recorder
        self.context = context
        self.holder = transcriberHolder
    }

    func start() {
        pendingCancellable = recorder.$pendingFailedRecording
            .compactMap { $0 }
            .sink { [weak self] audio in
                self?.persistPending(audio: audio)
            }
    }

    /// Insert the row for a finished dictation. `transcript` is the text the
    /// user is about to get (post-cleanup when AI cleanup ran). Returns nil
    /// when the save failed — the paste still happens, there is just no row.
    func persistDictation(result: TranscriptionResult, transcript: String, audio: AudioRecording) -> SavedDictation? {
        let recording = Recording(
            createdAt: audio.createdAt,
            title: Recording.defaultTitle(from: transcript),
            durationSeconds: audio.duration,
            transcript: transcript,
            rawTranscript: result.rawText,
            audioFileName: audio.fileURL.lastPathComponent,
            modelIdentifier: holder.primaryModelID.rawValue
        )
        context.insert(recording)
        do {
            try context.save()
        } catch {
            log.error("Failed to save Recording: \(String(describing: error))")
            Task { await ErrorLog.shared.error(component: "RecordingPersister", message: "SwiftData save failed", context: ["error": ErrorLog.redactedAppleError(error)]) }
            return nil
        }

        // Slice C linkage (make-or-break): commit the gate's pending vocabulary
        // proposals against the row's stable id, immediately after the save.
        // The anchor machinery in `CorrectionProvenance` reconciles the
        // gate-time baseline to the saved text at first read — this is what
        // absorbs the post-gate transform chain + any AI rewrite exactly once,
        // and any later edit (a live-ask answer included) the same way.
        let recordingID = recording.id
        let committed = Task { await CorrectionProvenance.shared.commit(transcriptID: recordingID) }

        // AI-search Stage B: index the new recording for semantic search.
        // Fire-and-forget, gated on the (default-ON, opt-out) toggle inside
        // `index`; the embed runs on a detached `.utility` task so it never
        // hitches the save path or the UI. A later text change re-indexes via
        // `RecordingTextMutation`.
        RecordingIndexer.shared?.index(recordingID: recordingID, text: transcript)

        // Speaker diarization (Nemotron 3, design D4) is manual + on-demand
        // only — there is deliberately NO automatic post-stop pass here.
        // The user taps "Detect speakers" in the recording detail view
        // (`RecordingDetailView.detectSpeakers()`), which writes
        // `recording.speakerTimeline` after the fact.
        return SavedDictation(recording: recording, provenanceCommitted: committed)
    }

    /// "Never lose audio" safety net (docs/resilient-transcription/design.md).
    /// Inserts a PENDING row (empty transcript, `pendingSince = .now`) for
    /// a recorder dictation whose WAV was finalized on disk but whose
    /// transcription then threw (busy engine, model error, etc.) — see
    /// `RecorderController.publishPendingFailureIfNeeded()`. Deliberately
    /// does nothing else: no `CorrectionProvenance.commit` and no
    /// `RecordingIndexer.index` here, matching the design's "empty +
    /// pending rows have nothing to Transform/index/commit until the user
    /// re-transcribes, which already does all three."
    func persistPending(audio: AudioRecording) {
        let recording = Recording(
            createdAt: audio.createdAt,
            title: Recording.defaultTitle(from: ""),
            durationSeconds: audio.duration,
            transcript: "",
            rawTranscript: "",
            audioFileName: audio.fileURL.lastPathComponent,
            modelIdentifier: holder.primaryModelID.rawValue,
            pendingSince: .now
        )
        context.insert(recording)
        do {
            try context.save()
        } catch {
            log.error("Failed to save pending Recording: \(String(describing: error))")
            Task { await ErrorLog.shared.error(component: "RecordingPersister", message: "Pending SwiftData save failed", context: ["error": ErrorLog.redactedAppleError(error)]) }
        }
    }
}
