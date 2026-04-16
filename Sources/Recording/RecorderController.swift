import Combine
import Foundation
import os.log

/// Top-level state machine for "press hotkey, speak, get transcript".
///
/// Lives on the main actor because its `@Published state` drives UI
/// directly. The heavy lifting (audio tap, Parakeet inference) happens
/// inside the `AudioCapture` and `Transcriber` actors; this class owns the
/// orchestration and the user-visible state only.
///
/// Phase 2 scope: `toggle()` and `cancel()` are callable from the debug
/// smoke harness. Phase 3 wires a real hotkey onto these.
@MainActor
final class RecorderController: ObservableObject {
    enum State: Equatable, Sendable {
        case idle
        case recording(startedAt: Date)
        case transcribing
        case transforming
        case error(String)
    }

    @Published private(set) var state: State = .idle {
        didSet { scheduleAutoRecoveryIfNeeded() }
    }
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastTransformedTranscript: String?
    @Published private(set) var lastResult: TranscriptionResult?

    /// The `AudioRecording` that produced `lastResult`, if any. Library's
    /// persister pairs this with `lastResult` to write a SwiftData row +
    /// reference the WAV on disk. Published so a Combine subscriber sees the
    /// pair land atomically — we set this immediately before `lastResult`.
    @Published private(set) var lastAudioRecording: AudioRecording?

    private let log = Logger(subsystem: "com.jot.Jot", category: "Recorder")
    private var autoRecoveryTask: Task<Void, Never>?
    private var transformTask: Task<Void, Never>?
    private var pendingTransform: (recording: AudioRecording, result: TranscriptionResult, rawText: String)?

    private let capture: AudioCapture
    /// Exposed so the Library's Re-transcribe action can run against the
    /// same in-memory Parakeet instance the live-recording path uses —
    /// avoids re-loading the model for a one-off rerun.
    let transcriber: Transcriber
    private let permissions: PermissionsService

    init(
        capture: AudioCapture = AudioCapture(),
        transcriber: Transcriber = Transcriber(),
        permissions: PermissionsService? = nil
    ) {
        self.capture = capture
        self.transcriber = transcriber
        // Why: `PermissionsService.shared` is main-actor-isolated, so it
        // can't be evaluated in a nonisolated default-argument context. The
        // init itself is `@MainActor`, so resolving it here is fine.
        self.permissions = permissions ?? PermissionsService.shared
    }

    /// Toggle between idle and recording. If recording, `stop + transcribe`.
    /// If idle, `start`. Errors surface on `state = .error(...)` rather than
    /// throwing — the caller is the UI, not a retry loop.
    func toggle() async {
        switch state {
        case .idle, .error:
            await startRecording()
        case .recording:
            await stopAndTranscribe()
        case .transcribing, .transforming:
            log.info("toggle() ignored — transcription/transform in progress")
        }
    }

    /// Reset state to `.idle` if currently in `.error`. Called by hotkey
    /// handlers so the user can retry immediately without waiting for the
    /// auto-recovery timer.
    func clearError() {
        if case .error = state { state = .idle }
    }

    /// Drop a recording in progress without transcribing. If the controller
    /// is already idle or transcribing, this is a no-op.
    func cancel() async {
        switch state {
        case .recording:
            await capture.cancel()
            state = .idle
        case .transforming:
            transformTask?.cancel()
            transformTask = nil
            if let pending = pendingTransform {
                lastTransformedTranscript = nil
                lastTranscript = pending.rawText
                lastAudioRecording = pending.recording
                lastResult = pending.result
                pendingTransform = nil
            }
            state = .idle
        case .idle, .transcribing, .error:
            break
        }
    }

    // MARK: - Internals

    private func scheduleAutoRecoveryIfNeeded() {
        autoRecoveryTask?.cancel()
        autoRecoveryTask = nil
        guard case .error = state else { return }
        autoRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, case .error = self.state else { return }
            self.state = .idle
        }
    }

    private func startRecording() async {
        permissions.refreshAll()
        guard permissions.statuses[.microphone] == .granted else {
            state = .error("Microphone permission is required.")
            return
        }

        do {
            try await capture.start()
            state = .recording(startedAt: Date())
        } catch {
            log.error("AudioCapture.start failed: \(String(describing: error))")
            state = .error("Could not start recording: \(error.localizedDescription)")
        }
    }

    private func stopAndTranscribe() async {
        state = .transcribing
        let recording: AudioRecording
        do {
            recording = try await capture.stop()
        } catch {
            log.error("AudioCapture.stop failed: \(String(describing: error))")
            state = .error("Recording stop failed: \(error.localizedDescription)")
            return
        }

        do {
            try await transcriber.ensureLoaded()
            let result = try await transcriber.transcribe(recording.samples)
            let rawText = result.text

            let llmConfig = LLMConfiguration.shared
            if llmConfig.transformEnabled && llmConfig.llmVerified {
                pendingTransform = (recording: recording, result: result, rawText: rawText)
                state = .transforming
                let client = LLMClient()
                transformTask = Task { [weak self] in
                    guard let self else { return }
                    defer { self.pendingTransform = nil }
                    do {
                        let transformed = try await client.transform(transcript: rawText)
                        guard !Task.isCancelled else { return }
                        self.lastTransformedTranscript = transformed
                        self.lastTranscript = transformed
                        self.lastAudioRecording = recording
                        self.lastResult = result
                        self.state = .idle
                    } catch {
                        guard !Task.isCancelled else { return }
                        self.log.warning("Transform failed, falling back to raw: \(String(describing: error))")
                        self.lastTransformedTranscript = nil
                        self.lastTranscript = rawText
                        self.lastAudioRecording = recording
                        self.lastResult = result
                        self.state = .idle
                    }
                }
            } else {
                lastTransformedTranscript = nil
                lastTranscript = rawText
                lastAudioRecording = recording
                lastResult = result
                state = .idle
            }
        } catch TranscriberError.modelMissing {
            state = .error("Parakeet model is not downloaded yet.")
        } catch TranscriberError.audioTooShort {
            state = .error("Recording was too short.")
        } catch TranscriberError.busy {
            state = .error("Another transcription is already running.")
        } catch {
            log.error("Transcription failed: \(String(describing: error))")
            state = .error("Transcription failed: \(error.localizedDescription)")
        }
    }
}
