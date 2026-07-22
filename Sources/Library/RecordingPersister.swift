import Combine
import Foundation
import JotVocabCore
import SwiftData
import os.log

/// Subscribes to `RecorderController.$lastResult` and writes a `Recording`
/// row into the SwiftData context for each successful pass. Lives on the
/// main actor because the `ModelContext` for the UI is main-actor bound.
///
/// The `audioFileName` is pulled off `RecorderController.lastAudioRecording`
/// — we read the companion publisher's current value at the moment a new
/// `lastResult` arrives, rather than zipping the two streams, because the
/// controller sets `lastAudioRecording` immediately before `lastResult`
/// (same synchronous main-actor step).
@MainActor
final class RecordingPersister {
    private let log = Logger(subsystem: "com.jot.Jot", category: "RecordingPersister")
    private let recorder: RecorderController
    private let context: ModelContext
    /// Phase 3 F4: model id is read off the holder per persist call (not
    /// snapshotted at init), so a swap mid-session stamps subsequent rows
    /// with the new id without rebinding the persister.
    private let holder: TranscriberHolder
    private var cancellable: AnyCancellable?
    /// "Never lose audio" safety net (docs/resilient-transcription/design.md).
    /// Mirrors `cancellable` above but for the failure edge —
    /// `RecorderController.$pendingFailedRecording` fires when a recorder
    /// dictation's transcription throws after the WAV was already
    /// finalized. Kept as a separate subscription (not folded into
    /// `$lastResult`) since it's a wholly separate publisher with its own
    /// payload type and never fires for the same session as `$lastResult`.
    private var pendingCancellable: AnyCancellable?

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
        cancellable = recorder.$lastResult
            .compactMap { $0 }
            .sink { [weak self] result in
                self?.persist(result: result)
            }
        pendingCancellable = recorder.$pendingFailedRecording
            .compactMap { $0 }
            .sink { [weak self] audio in
                self?.persistPending(audio: audio)
            }
    }

    private func persist(result: TranscriptionResult) {
        guard let audio = recorder.lastAudioRecording else {
            log.warning("lastResult fired without a paired lastAudioRecording; skipping persistence")
            Task { await ErrorLog.shared.warn(component: "RecordingPersister", message: "lastResult fired without a paired lastAudioRecording") }
            return
        }

        let transcript = recorder.lastTransformedTranscript ?? result.text
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
            return
        }

        // Slice C linkage (make-or-break): commit the gate's pending vocabulary
        // proposals against the row's stable id, immediately after the save —
        // the transcript text is final by this point (the post-transform sink
        // runs `lastTransformedTranscript` upstream). `commit` is actor-isolated
        // (async); the row id is a `Sendable` UUID captured by value, so firing
        // it in a detached `Task` from this main-actor sink is race-free. The
        // anchor machinery in `CorrectionProvenance` reconciles the gate-time
        // baseline to the saved text at first read — this is what absorbs the
        // post-gate transform chain + any AI rewrite exactly once.
        let recordingID = recording.id
        Task { await CorrectionProvenance.shared.commit(transcriptID: recordingID) }

        // AI-search Stage B: index the new recording for semantic search. The
        // transcript is FINAL at this point (the post-transform sink ran
        // upstream, so `lastTransformedTranscript` is settled). Fire-and-forget,
        // gated on the (default-ON, opt-out) toggle inside `index`; the embed runs on a
        // detached `.utility` task so it never hitches the save path or the UI.
        RecordingIndexer.shared?.index(recordingID: recordingID, text: transcript)

        // Speaker diarization (offline VBx, design D4) is manual + on-demand
        // only — there is deliberately NO automatic post-stop pass here.
        // The user taps "Detect speakers" in the recording detail view
        // (`RecordingDetailView.detectSpeakers()`), which writes
        // `recording.speakerTimeline` after the fact. This mirrors the
        // "attach a timeline after the fact" pattern this hook used to run
        // synchronously, minus the automatic trigger.
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
