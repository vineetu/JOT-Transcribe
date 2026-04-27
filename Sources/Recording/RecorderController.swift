import Combine
import Foundation
import os.log

/// Top-level state machine for "press hotkey, speak, get transcript".
///
/// Lives on the main actor because its `@Published state` drives UI
/// directly. The heavy lifting (audio tap, Parakeet inference) now lives in
/// `VoiceInputPipeline`; this class owns the dictation flow task, user-visible
/// state, and Transform tail only.
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
    private var activeFlowTask: Task<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var pipelineToken: VoiceInputPipeline.Token?

    private let pipeline: VoiceInputPipeline
    private let urlSession: URLSession
    private let appleIntelligence: any AppleIntelligenceClienting
    private let logSink: any LogSink
    /// Phase 3 #29: per-graph LLMConfiguration replaces
    /// `LLMConfiguration.shared` reads. Used to gate the cleanup
    /// (Transform) tail on the user's configured provider.
    private let llmConfiguration: LLMConfiguration

    init(
        pipeline: VoiceInputPipeline,
        urlSession: URLSession,
        appleIntelligence: any AppleIntelligenceClienting,
        logSink: any LogSink = ErrorLog.shared,
        llmConfiguration: LLMConfiguration
    ) {
        self.pipeline = pipeline
        self.urlSession = urlSession
        self.appleIntelligence = appleIntelligence
        self.logSink = logSink
        self.llmConfiguration = llmConfiguration
    }

    /// Toggle between idle and recording. If recording, signal the parked flow
    /// task to stop and transcribe. Errors surface on `state = .error(...)`
    /// rather than throwing — the caller is the UI, not a retry loop.
    func toggle() async {
        log.info("toggle() called; current state=\(String(describing: self.state))")
        switch state {
        case .idle, .error:
            activeFlowTask = Task { @MainActor [weak self] in
                await self?.runFlow()
            }
        case .recording:
            resumeStopContinuation()
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

    /// Drop a recording in progress or cancel Transform. The flow task is
    /// always cancelled first; pipeline teardown only happens if this
    /// controller still owns a valid pipeline token.
    func cancel() async {
        activeFlowTask?.cancel()
        activeFlowTask = nil

        takeStopContinuation()?.resume(throwing: CancellationError())

        let token = pipelineToken
        pipelineToken = nil

        switch state {
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
        case .recording, .transcribing:
            state = .idle
            if let token {
                await pipeline.cancel(token: token)
            }
        case .idle, .error:
            break
        }
    }

    // MARK: - Internals

    /// Called on the successful-delivery site in `runFlow()` — i.e. a
    /// non-empty transcript has been handed off to the clipboard / paste path
    /// and state is about to flip back to `.idle`. Increments the
    /// donation-reminder counter used by `DonationLogic`.
    ///
    /// Deliberately **not** called on the error, cancel, or
    /// `VoiceInputPipeline.PipelineError.audioTooShort` paths — those don't
    /// hand text to the user, so counting them would inflate the milestone and
    /// ask after a failure.
    private func noteSuccessfulDelivery(text: String) {
        guard !text.isEmpty else { return }
        DonationStore.shared.incrementRecordingCount()
    }

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

    private func runFlow() async {
        defer {
            activeFlowTask = nil
            pipelineToken = nil
            stopContinuation = nil
        }

        // Defense-in-depth pre-warm. If the user downloads Parakeet after
        // launch, AppDelegate's one-shot pre-warm may have run before the
        // model existed. Fire-and-forget so a hung native load path cannot
        // block recording start.
        let pipeline = self.pipeline
        Task.detached(priority: .userInitiated) { [pipeline] in
            try? await pipeline.ensureTranscriberLoaded()
        }

        do {
            let token = try await pipeline.startRecording(owner: .recorder)
            pipelineToken = token

            guard pipeline.stillActive(token) else { return }
            state = .recording(startedAt: Date())

            try await waitForStopSignal()

            guard pipeline.stillActive(token) else { return }
            state = .transcribing

            let (rawText, recording) = try await pipeline.stopAndTranscribe(token)
            if pipelineToken == token {
                pipelineToken = nil
            }

            guard pipeline.stillActive(token) else { return }

            let llmConfig = llmConfiguration
            let result = TranscriptionResult(
                text: rawText,
                rawText: rawText,
                duration: recording.duration,
                processingTime: 0,
                confidence: 0
            )

            if llmConfig.transformEnabled && llmConfig.isMinimallyConfigured {
                pendingTransform = (recording: recording, result: result, rawText: rawText)
                guard pipeline.stillActive(token) else { return }
                state = .transforming
                let client = LLMClient(
                    session: urlSession,
                    appleClient: appleIntelligence,
                    logSink: logSink,
                    llmConfiguration: llmConfiguration
                )
                transformTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer {
                        self.pendingTransform = nil
                        self.transformTask = nil
                    }
                    do {
                        let transformed = try await client.transform(transcript: rawText)
                        guard !Task.isCancelled else { return }
                        self.lastTransformedTranscript = transformed
                        self.lastTranscript = transformed
                        self.lastAudioRecording = recording
                        self.lastResult = result
                        self.noteSuccessfulDelivery(text: transformed)
                        self.state = .idle
                    } catch {
                        guard !Task.isCancelled else { return }
                        self.log.warning("Transform failed, falling back to raw: \(String(describing: error))")
                        let logSink = self.logSink
                        Task {
                            await logSink.error(
                                component: "Recorder",
                                message: "Transform failed, pasted raw",
                                context: ["error": "\((error as NSError).domain) code=\((error as NSError).code)"]
                            )
                        }
                        self.lastTransformedTranscript = nil
                        self.lastTranscript = rawText
                        self.lastAudioRecording = recording
                        self.lastResult = result
                        self.noteSuccessfulDelivery(text: rawText)
                        self.state = .idle
                    }
                }
            } else {
                guard pipeline.stillActive(token) else { return }
                lastTransformedTranscript = nil
                lastTranscript = rawText
                lastAudioRecording = recording
                lastResult = result
                noteSuccessfulDelivery(text: rawText)
                state = .idle
            }
        } catch is CancellationError {
            return
        } catch VoiceInputPipeline.PipelineError.busy {
            state = .error("Another flow is running.")
        } catch VoiceInputPipeline.PipelineError.tokenStale {
            return
        } catch VoiceInputPipeline.PipelineError.micNotGranted {
            state = .error("Microphone permission is required.")
        } catch VoiceInputPipeline.PipelineError.engineStartTimeout {
            log.error("AudioCapture.start timed out — coreaudiod may be wedged")
            state = .error(AudioCaptureError.engineStartTimeoutMessage)
        } catch VoiceInputPipeline.PipelineError.engineStart(let error) {
            log.error("AudioCapture.start failed: \(String(describing: error))")
            state = .error("Could not start recording: \(error.localizedDescription)")
        } catch VoiceInputPipeline.PipelineError.modelMissing {
            state = .error("Transcription model is still loading — try again in a moment.")
        } catch VoiceInputPipeline.PipelineError.audioTooShort(let recording) {
            state = .error(shortRecordingMessage(for: recording))
        } catch VoiceInputPipeline.PipelineError.transcribeBusy {
            state = .error("Another transcription is already running.")
        } catch VoiceInputPipeline.PipelineError.transcribeFailed(let error) {
            log.error("Transcription failed: \(String(describing: error))")
            let logSink = self.logSink
            Task {
                await logSink.error(
                    component: "Recorder",
                    message: "Transcription failed",
                    context: ["error": "\((error as NSError).domain) code=\((error as NSError).code)"]
                )
            }
            state = .error(transcriptionFailureMessage(for: error))
        } catch {
            log.error("Transcription failed: \(String(describing: error))")
            let logSink = self.logSink
            Task {
                await logSink.error(
                    component: "Recorder",
                    message: "Transcription failed",
                    context: ["error": "\((error as NSError).domain) code=\((error as NSError).code)"]
                )
            }
            state = .error("Transcription failed: \(error.localizedDescription)")
        }
    }

    private func waitForStopSignal() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stopContinuation = continuation
        }
    }

    private func resumeStopContinuation() {
        takeStopContinuation()?.resume()
    }

    private func takeStopContinuation() -> CheckedContinuation<Void, Error>? {
        let continuation = stopContinuation
        stopContinuation = nil
        return continuation
    }

    private func transcriptionFailureMessage(for error: Error) -> String {
        if error.localizedDescription == "Transcription is taking too long — try again." {
            return error.localizedDescription
        }
        if error is AudioCaptureError {
            return "Recording stop failed: \(error.localizedDescription)"
        }
        return "Transcription failed: \(error.localizedDescription)"
    }
}
