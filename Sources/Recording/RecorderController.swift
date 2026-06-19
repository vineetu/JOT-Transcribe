import Combine
import Foundation
import os.log

/// Tiny atomic-flag box shared between `RecorderController.runFlow`'s
/// disconnect closure and the catch path. Captured strongly by the
/// closure (so the closure outlives the do-block); the catch path reads
/// it after `stopAndTranscribe` has already thrown.
@MainActor
final class DisconnectFlag {
    private var flag: Bool = false
    var value: Bool { flag }
    func set() { flag = true }
}

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
    /// Timestamp paired with `lastTranscript`. Updated on every write so
    /// `DeliveryService.pasteLast()` can compare against the rewrite
    /// controller's last-output time and replay whichever fired more
    /// recently. Nil until the first transcript lands.
    @Published private(set) var lastTranscriptAt: Date?
    @Published private(set) var lastTransformedTranscript: String?
    @Published private(set) var lastResult: TranscriptionResult?

    /// One-shot informational notice for the next pill cycle. Set by
    /// `runFlow()` when the active session fell back to the system
    /// default mic (preferred UID was unresolvable) or recovered partial
    /// audio after a mid-recording disconnect. `PillViewModel` reads
    /// this and surfaces a `.notice(...)` after success dismisses, then
    /// clears it via `consumeFallbackNotice()`.
    @Published private(set) var lastFallbackNotice: String?

    /// The `AudioRecording` that produced `lastResult`, if any. Library's
    /// persister pairs this with `lastResult` to write a SwiftData row +
    /// reference the WAV on disk. Published so a Combine subscriber sees the
    /// pair land atomically — we set this immediately before `lastResult`.
    @Published private(set) var lastAudioRecording: AudioRecording?

    /// v1.14 recording-safety contract. When `true`, the delivery bridge
    /// in `AppDelegate` skips the paste step for the *next* successful
    /// transcript only; the recording still persists to Recents via
    /// `RecordingPersister`. Read-and-clear in the bridge — the flag is
    /// session-scoped, not sticky. Set by `stopWithoutPaste()` (called
    /// from the in-app Record pill) so clicking the pill again stops
    /// the recording without pasting at the user's cursor.
    @Published var skipNextPaste: Bool = false

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

    /// Read-and-clear accessor for the one-shot fallback notice.
    /// `PillViewModel` calls this after surfacing the notice so a stale
    /// message doesn't replay on the next session.
    func consumeFallbackNotice() -> String? {
        let notice = lastFallbackNotice
        if notice != nil { lastFallbackNotice = nil }
        return notice
    }

    /// v1.14: Stop the in-progress recording the same way the trigger
    /// hotkey would — but with the paste step suppressed for the
    /// resulting transcript. The recording still flows through
    /// transcription → persistence; only the synthetic ⌘V is skipped.
    ///
    /// Called from the in-app Record pill's "click to stop" path. The
    /// flag is read-and-cleared by `AppDelegate`'s delivery bridge so
    /// it never bleeds into the next session. No-op when not currently
    /// recording.
    func stopWithoutPaste() async {
        guard case .recording = state else { return }
        skipNextPaste = true
        await toggle()
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
                lastTranscriptAt = .now
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
    /// donation-reminder counter used by `DonationLogic` AND records the
    /// audio duration into `DictationStats` so the Donations page's
    /// "Jot has saved you about X" line has data to read.
    ///
    /// Deliberately **not** called on the error, cancel, or
    /// `VoiceInputPipeline.PipelineError.audioTooShort` paths — those don't
    /// hand text to the user, so counting them would inflate the milestone and
    /// ask after a failure.
    private func noteSuccessfulDelivery(text: String, durationSeconds: TimeInterval) {
        guard !text.isEmpty else { return }
        DonationStore.shared.incrementRecordingCount()
        DictationStats.record(durationSeconds: durationSeconds)
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

        // Tracks whether the active session saw a mid-recording
        // disconnect. The `onDisconnect` closure captures this box
        // strongly so the `audioTooShort` catch site can upgrade its
        // error copy when the salvaged audio dropped below the 1 s
        // transcriber floor.
        let disconnectFlag = DisconnectFlag()
        do {
            // Hand the pipeline a closure it invokes if the bound mic
            // drops off mid-recording. We unblock the parked stop
            // continuation as if the user had hit the hotkey to stop —
            // `stopAndTranscribe` will read `pipeline.didDisconnect` and
            // mark the result `partialDueToDisconnect`. Captures self
            // weakly to avoid a retain cycle.
            let onDisconnect: @MainActor @Sendable () -> Void = { [weak self, disconnectFlag] in
                disconnectFlag.set()
                self?.takeStopContinuation()?.resume()
            }
            let token = try await pipeline.startRecording(
                owner: .recorder,
                onDisconnect: onDisconnect
            )
            pipelineToken = token

            guard pipeline.stillActive(token) else { return }
            state = .recording(startedAt: Date())

            try await waitForStopSignal()

            guard pipeline.stillActive(token) else { return }
            state = .transcribing

            let stopResult = try await pipeline.stopAndTranscribe(token)
            let rawText = stopResult.text
            let recording = stopResult.recording
            let partialDueToDisconnect = stopResult.partialDueToDisconnect
            if pipelineToken == token {
                pipelineToken = nil
            }

            guard pipeline.stillActive(token) else { return }

            // Resolve the user-facing fallback notice once. Two surfaces
            // can produce a notice:
            //   * The session fell back to the system default because
            //     the saved UID was unresolvable (`fallbackInfo.didFallback`).
            //   * The mic dropped off mid-recording but we recovered
            //     enough audio to transcribe (`partialDueToDisconnect`).
            // Mid-record disconnect wins if both fired (it's the more
            // surprising signal).
            let fallbackInfo = await pipeline.lastFallbackInfo()
            // Phase 5: a transient-fallback notice ("Temporarily using <alt>
            // while <active> re-downloads") wins over the mic-fallback notice
            // — it's the more surprising signal and explains the (possibly
            // different) transcription quality the user just saw.
            let composedNotice: String? = pipeline.consumeTransientFallbackNotice()
                ?? Self.composeFallbackNotice(
                    partialDueToDisconnect: partialDueToDisconnect,
                    recordingDuration: recording.duration,
                    fallbackInfo: fallbackInfo
                )

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
                let service = AIServices.current(
                    configuration: llmConfiguration,
                    urlSession: urlSession,
                    appleClient: appleIntelligence,
                    logSink: logSink
                )
                transformTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer {
                        self.pendingTransform = nil
                        self.transformTask = nil
                    }
                    do {
                        let transformed = try await service.transform(transcript: rawText)
                        guard !Task.isCancelled else { return }
                        self.lastTransformedTranscript = transformed
                        self.lastTranscript = transformed
                        self.lastTranscriptAt = .now
                        // Per `docs/plans/mic-disconnect-handling.md`:
                        // publish metadata BEFORE `lastResult` so
                        // subscribers (RecordingPersister, SoundTriggers,
                        // PillViewModel) see a consistent pair.
                        self.lastAudioRecording = recording
                        self.lastFallbackNotice = composedNotice
                        self.lastResult = result
                        self.noteSuccessfulDelivery(text: transformed, durationSeconds: recording.duration)
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
                        self.lastTranscriptAt = .now
                        self.lastAudioRecording = recording
                        self.lastFallbackNotice = composedNotice
                        self.lastResult = result
                        self.noteSuccessfulDelivery(text: rawText, durationSeconds: recording.duration)
                        self.state = .idle
                    }
                }
            } else {
                guard pipeline.stillActive(token) else { return }
                lastTransformedTranscript = nil
                lastTranscript = rawText
                lastTranscriptAt = .now
                lastAudioRecording = recording
                lastFallbackNotice = composedNotice
                lastResult = result
                noteSuccessfulDelivery(text: rawText, durationSeconds: recording.duration)
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
        } catch VoiceInputPipeline.PipelineError.repairInProgress {
            // Phase 5: active model is re-downloading and no installed
            // alternate English model is available to dictate on. The
            // persistent repairing pill (driven off `repairState`) carries the
            // live progress; this transient error nudges the user to wait.
            state = .error("Repairing your transcription model — try again once the download finishes.")
        } catch VoiceInputPipeline.PipelineError.audioTooShort(let recording) {
            // If the recording was cut short by a mid-recording mic
            // disconnect AND fell below the 1 s transcriber floor, give
            // the user a more accurate explanation than the generic
            // short-recording warning.
            if disconnectFlag.value {
                state = .error("Mic disconnected mid-recording — too little audio to keep.")
            } else {
                state = .error(shortRecordingMessage(for: recording))
            }
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

    /// Build the one-line user-facing notice for the next pill cycle.
    /// Returns `nil` when nothing notable happened. Keeps copy in one
    /// place so the empty-savedName fallback stays consistent.
    static func composeFallbackNotice(
        partialDueToDisconnect: Bool,
        recordingDuration: TimeInterval,
        fallbackInfo: AudioCaptureFallbackInfo?
    ) -> String? {
        if partialDueToDisconnect {
            let seconds = max(1, Int(recordingDuration.rounded()))
            return "Mic disconnected — kept \(seconds)s of audio."
        }
        if let info = fallbackInfo, info.didFallback {
            if !info.savedName.isEmpty {
                return "Recorded with system default — \(info.savedName) was unavailable."
            }
            return "Recorded with system default — your saved mic was unavailable."
        }
        return nil
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
