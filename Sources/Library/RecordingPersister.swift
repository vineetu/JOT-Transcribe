import Combine
import Foundation
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
    /// Speaker Labels piece A: when the model is loaded, the persister runs
    /// a post-stop Sortformer pass on the recorded audio buffer to attach a
    /// labeled timeline to the new `Recording` row. `nil` when Speaker
    /// Labels is not built into this graph (test harnesses) — the persist
    /// path still writes a plain transcript.
    private let sortformerHolder: SortformerHolder?
    private var cancellable: AnyCancellable?

    init(
        recorder: RecorderController,
        context: ModelContext,
        transcriberHolder: TranscriberHolder,
        sortformerHolder: SortformerHolder? = nil
    ) {
        self.recorder = recorder
        self.context = context
        self.holder = transcriberHolder
        self.sortformerHolder = sortformerHolder
    }

    func start() {
        cancellable = recorder.$lastResult
            .compactMap { $0 }
            .sink { [weak self] result in
                self?.persist(result: result)
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

        // Speaker Labels piece A: kick off a best-effort post-stop
        // diarization pass. Gated on:
        //   • `state == .loaded` (model warm in memory)
        //   • `currentDiarizer() != nil` (non-nil handle)
        //   • `jot.speakerLabels.enabled == true` (master toggle ON)
        // The master-toggle check is defense-in-depth against a race
        // where the user toggled OFF mid-download but the warmup task
        // still completed and set state to `.loaded` — without the
        // explicit master read here, those recordings would still get
        // diarized + stamped with a `speakerTimeline` against the
        // user's OFF intent. Failures are silent: the recording stays
        // as a plain transcript, indistinguishable from a pre-feature
        // recording.
        let _stateDesc: String = sortformerHolder.map { "\($0.state)" } ?? "no-holder"
        let _diarDesc: String = sortformerHolder?.currentDiarizer() == nil ? "nil" : "present"
        SortformerDiag.log("RecordingPersister.persist state=\(_stateDesc) diarizer=\(_diarDesc) duration=\(audio.duration)s samples=\(audio.samples.count)")
        let speakerLabelsMasterOn = UserDefaults.standard.object(forKey: "jot.speakerLabels.enabled") as? Bool ?? true
        if Features.speakerLabels,
           speakerLabelsMasterOn,
           let sortformerHolder, sortformerHolder.state == .loaded,
           let diarizer = sortformerHolder.currentDiarizer() {
            let samples = audio.samples
            let duration = audio.duration
            let modelContext = self.context
            let recordingID = recording.id
            let logRef = self.log
            Task { @MainActor in
                do {
                    guard let payload = try SpeakerTimelineBuilder.buildTimeline(
                        samples: samples,
                        transcript: transcript,
                        duration: duration,
                        diarizer: diarizer
                    ) else {
                        return // solo recording — detect-and-skip
                    }
                    let data = try JSONEncoder().encode(payload)
                    let descriptor = FetchDescriptor<Recording>(
                        predicate: #Predicate { $0.id == recordingID }
                    )
                    if let row = try modelContext.fetch(descriptor).first {
                        row.speakerTimeline = data
                        try modelContext.save()
                    }
                } catch {
                    logRef.error("Speaker timeline build failed: \(String(describing: error))")
                }
            }
        }
    }
}
