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
    private let modelIdentifier: String
    private var cancellable: AnyCancellable?

    init(
        recorder: RecorderController,
        context: ModelContext,
        modelIdentifier: String = ParakeetModelID.tdt_0_6b_v3.rawValue
    ) {
        self.recorder = recorder
        self.context = context
        self.modelIdentifier = modelIdentifier
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
            modelIdentifier: modelIdentifier
        )
        context.insert(recording)
        do {
            try context.save()
        } catch {
            log.error("Failed to save Recording: \(String(describing: error))")
        }
    }
}
