import Foundation
import os.log

@MainActor
final class VoiceInputPipeline {
    enum Owner: Sendable {
        case recorder
        case rewrite
    }

    struct Token: Equatable, Sendable {
        let owner: Owner
        let generation: UInt64
    }

    enum PipelineError: Error {
        case busy
        case tokenStale
        case micNotGranted
        case engineStartTimeout
        case engineStart(Error)
        case modelMissing
        case audioTooShort(AudioRecording)
        case transcribeBusy
        case transcribeFailed(Error)
        /// The bound mic dropped off mid-recording during a Rewrite or
        /// Ask Jot voice-command session. Voice commands need to be heard
        /// in full, so we discard partial audio and surface this so the
        /// owning controller can show a clear pill error. Recorder-owned
        /// sessions don't see this — they get success-with-metadata via
        /// `StopAndTranscribeResult.partialDueToDisconnect`.
        case disconnectedMidVoiceCommand
    }

    /// Result tuple returned by `stopAndTranscribe(_:)`. Adds
    /// `partialDueToDisconnect` so the recorder can surface a "Mic
    /// disconnected — kept Ns of audio." notice while still treating the
    /// transcript as a successful delivery. See
    /// `docs/plans/mic-disconnect-handling.md`.
    struct StopAndTranscribeResult: Sendable {
        let text: String
        let recording: AudioRecording
        let partialDueToDisconnect: Bool
    }

    private enum Phase {
        case idle
        case recording(Token, startedAt: Date)
        case transcribing(Token)
    }

    private struct TranscribeTimeoutError: LocalizedError, Sendable {
        var errorDescription: String? {
            "Transcription is taking too long — try again."
        }
    }

    private let log = Logger(subsystem: "com.jot.Jot", category: "VoiceInputPipeline")
    private let capture: any AudioCapturing
    /// Phase 3 F4: holder is the single source of truth for the active
    /// `Transcribing` instance. Reading `transcriber` always returns
    /// the live one, so a model swap mid-session propagates without
    /// re-wiring the pipeline.
    private let holder: TranscriberHolder
    var transcriber: any Transcribing { holder.transcriber }
    private let permissions: any PermissionsObserving

    private var phase: Phase = .idle
    private var generationCounter: UInt64 = 0
    private var transcribeWatchdog: Task<Void, Never>?
    /// Per-token disconnect ledger. The pipeline records a token's
    /// generation here when a disconnect event lands; controllers
    /// inspect via `didDisconnect(_:)` so they survive the pre-
    /// continuation race documented in `docs/plans/mic-disconnect-handling.md`
    /// (fast Bluetooth glitch immediately after `startRecording` returns,
    /// before the controller has parked its stop continuation).
    private var disconnectedGenerations: Set<UInt64> = []
    /// On-disconnect closure registered by the controller at
    /// `startRecording(owner:onDisconnect:)`. Held strongly until the
    /// session ends; the closure itself captures `self` weakly.
    private var disconnectCallback: (@MainActor @Sendable () -> Void)?
    /// Live `Task` awaiting `capture.disconnectEvents()`. Cancelled via
    /// `clearPhase()` so a stuck listener can't outlive the session.
    private var disconnectListenerTask: Task<Void, Never>?
    /// Captured `DualPipelineTranscriber` for the active streaming
    /// session, set in `beginStreamingSession` and cleared in
    /// `endStreamingSession`. Storing the dual per session (rather
    /// than re-reading `holder.transcriber` on cleanup) protects
    /// against a mid-session `setPrimary` swap: the cleanup path
    /// always tears down the engine that was actually started, even
    /// when `holder.transcriber` has already moved on. (See plan
    /// §6.3 / §11 for the wider in-flight gate work; this is the
    /// minimum-viable defense.)
    private var activeStreamingDual: DualPipelineTranscriber?

    init(
        capture: any AudioCapturing = AudioCapture(),
        transcriberHolder: TranscriberHolder,
        permissions: (any PermissionsObserving)? = nil
    ) {
        self.capture = capture
        self.holder = transcriberHolder
        self.permissions = permissions ?? PermissionsService.shared
    }

    func setAmplitudePublisher(_ publisher: AmplitudePublisher) {
        let capture = self.capture
        Task {
            await capture.setAmplitudePublisher(publisher)
        }
    }

    func startRecording(owner: Owner) async throws -> Token {
        try await startRecording(owner: owner, onDisconnect: nil)
    }

    /// Start a recording session, optionally pre-registering a closure the
    /// pipeline invokes if the bound device drops off mid-recording (USB
    /// pull, AirPods drop). Recorder hands in a closure that resumes its
    /// stop-continuation so a partial transcript is salvaged.
    /// Rewrite / Ask Jot can register a closure that triggers
    /// `cancel()` directly.
    func startRecording(
        owner: Owner,
        onDisconnect: (@MainActor @Sendable () -> Void)?
    ) async throws -> Token {
        permissions.refreshAll()
        guard permissions.statuses[.microphone] == .granted else {
            throw PipelineError.micNotGranted
        }

        guard case .idle = phase else {
            throw PipelineError.busy
        }

        let token = issueToken(owner: owner)
        phase = .recording(token, startedAt: Date())
        disconnectCallback = onDisconnect

        // Streaming option: bring up the streaming session BEFORE
        // `capture.start()` so the audio sink is wired and the
        // streaming engine has a per-session AsyncStream continuation
        // ready when the very first audio chunk lands. The streaming
        // engine loads its model lazily via its consumer task; chunks
        // captured before the model warms accumulate in the unbounded
        // stream and drain as soon as the model is ready. So even the
        // first recording after app launch shows a live preview (just
        // with a few extra seconds before the first partial appears).
        // Non-streaming primaries (v3 / JA) skip entirely — the
        // downcast fails and `dual` stays nil.
        if let dual = transcriber as? DualPipelineTranscriber {
            await beginStreamingSession(token: token, dual: dual)
        }

        do {
            try await capture.start()
            do {
                try Task.checkCancellation()
            } catch is CancellationError {
                await capture.cancel()
                await endStreamingSession(graceful: false)
                invalidateIfMatching(token)
                throw CancellationError()
            }
            phase = .recording(token, startedAt: Date())
            // Fire and forget — the listener task resolves either when
            // the stream finishes (clean stop) or a disconnect event
            // lands. `clearPhase()` cancels it as defense-in-depth.
            startDisconnectListener(token: token)
            return token
        } catch is CancellationError {
            await capture.cancel()
            await endStreamingSession(graceful: false)
            invalidateIfMatching(token)
            throw CancellationError()
        } catch AudioCaptureError.engineStartTimeout {
            await endStreamingSession(graceful: false)
            clearIfMatching(token)
            throw PipelineError.engineStartTimeout
        } catch AudioCaptureError.engineStart(let error) {
            await endStreamingSession(graceful: false)
            clearIfMatching(token)
            throw PipelineError.engineStart(error)
        } catch {
            await endStreamingSession(graceful: false)
            clearIfMatching(token)
            throw PipelineError.engineStart(error)
        }
    }

    /// True iff a disconnect event landed during the session that
    /// produced `token`. Used by controllers to survive the pre-
    /// continuation race.
    func didDisconnect(_ token: Token) -> Bool {
        disconnectedGenerations.contains(token.generation)
    }

    private func startDisconnectListener(token: Token) {
        let capture = self.capture
        disconnectListenerTask?.cancel()
        disconnectListenerTask = Task { @MainActor [weak self] in
            let stream = await capture.disconnectEvents()
            for await _ in stream {
                guard let self else { return }
                // Race-safe: only flag the active token. If the session
                // already ended, the late event is dropped.
                guard self.stillActive(token) else { return }
                self.disconnectedGenerations.insert(token.generation)
                self.disconnectCallback?()
                // One disconnect per session — bail out of the loop.
                break
            }
        }
    }

    func stopAndTranscribe(_ token: Token) async throws -> StopAndTranscribeResult {
        guard case .recording(let current, _) = phase, current == token else {
            throw PipelineError.tokenStale
        }

        let recording: AudioRecording
        do {
            recording = try await capture.stop()
        } catch {
            await endStreamingSession(graceful: false)
            clearIfMatching(token)
            throw PipelineError.transcribeFailed(error)
        }

        // Order: stop audio first → flush streaming engine's tail
        // (ordering matters; finishing before stop would race with
        // late buffers from the writer queue) → clear the partial
        // store. The audio sink was set in `beginStreamingSession`;
        // it's idempotent to clear it here on every path.
        await endStreamingSession(graceful: true)

        // Voice-command owners (Rewrite with Voice, future Ask Jot
        // voice input) explicitly do NOT persist the captured WAV.
        // Voice instruction audio is intentionally dropped — only the
        // transcribed text feeds the LLM and lands in the persisted
        // `RewriteSession`. The capture layer always writes to disk;
        // clean it up here so success, disconnect, model-missing,
        // ASR-failure, and short-audio paths all drop the file.
        // Recorder owners keep their WAV (it's referenced by the
        // persisted `Recording` row).
        if token.owner != .recorder {
            try? FileManager.default.removeItem(at: recording.fileURL)
        }

        guard phaseMatches(token) else {
            throw PipelineError.tokenStale
        }

        let disconnected = didDisconnect(token)
        // Voice-command owners (Rewrite, Ask Jot) need the full
        // instruction or none — half a command produces nonsense
        // output. Recorder owners get success-with-metadata.
        if disconnected, token.owner == .rewrite {
            clearIfMatching(token)
            throw PipelineError.disconnectedMidVoiceCommand
        }

        phase = .transcribing(token)

        let ready = await transcriber.isReady
        guard phaseMatches(token) else {
            throw PipelineError.tokenStale
        }
        guard ready else {
            clearIfMatching(token)
            throw PipelineError.modelMissing
        }

        let text = try await transcribe(recording: recording, token: token)
        return StopAndTranscribeResult(
            text: text,
            recording: recording,
            partialDueToDisconnect: disconnected
        )
    }

    func cancel(token: Token) async {
        let isRecordingPhase: Bool
        switch phase {
        case .recording(let current, _) where current == token:
            isRecordingPhase = true
        case .transcribing(let current) where current == token:
            isRecordingPhase = false
        case .idle:
            guard stillActive(token) else { return }
            isRecordingPhase = false
        default:
            return
        }

        if isRecordingPhase {
            await capture.cancel()
        }
        // No graceful flush on cancel — user is aborting, partial
        // text doesn't matter.
        await endStreamingSession(graceful: false)

        invalidateGenerationIfCurrent(token)
    }

    // MARK: - Streaming option wiring

    /// Bring up the streaming pipeline alongside the batch capture.
    /// - Sets the partial store's session token so late callbacks
    ///   from a prior session can't bleed into this one.
    /// - Wires the audio capture's streaming sink so each converted
    ///   16 kHz mono Float32 chunk reaches the active streaming engine.
    /// - Starts the streaming transcriber with a closure that
    ///   forwards partials into the store with the same token.
    /// Best-effort — failures degrade silently to batch-only delivery
    /// (the pill simply doesn't show streaming text). Batch is the
    /// authoritative source.
    ///
    /// The sink calls `enqueue(samples:)` synchronously — it is
    /// `nonisolated` on the actor and yields straight into a per-session
    /// AsyncStream. Spawning a `Task { await actor.feed(...) }` per
    /// chunk would re-order audio at the actor entry point because Swift
    /// doesn't guarantee FIFO when multiple Tasks await the same actor;
    /// scrambled audio prevents the EOU encoder from making progress and
    /// was the root cause of the ~30 s first-partial delay observed in
    /// the previous build.
    private func beginStreamingSession(token: Token, dual: DualPipelineTranscriber) async {
        let store = StreamingPartialStore.shared

        store.beginSession(token: token.generation)
        activeStreamingDual = dual

        let publish: @Sendable (String, UInt64) -> Void = { text, generation in
            Task { @MainActor in
                StreamingPartialStore.shared.publish(text, token: generation)
            }
        }
        // Lazy-load consumer: returns immediately. The streaming engine
        // loads inside the consumer task; chunks yielded before load
        // completes accumulate in the unbounded AsyncStream and drain
        // once warm. No throwing path — load failures are logged and
        // the consumer task simply exits without firing partials.
        await dual.startStreaming(generation: token.generation, onPartial: publish)

        // Wire sink BEFORE the caller starts capture so the very first
        // audio chunk flows through. `setStreamingSink` writes the
        // property synchronously; `configureAUHALWithTimeout` reads it
        // when AUHAL comes up.
        let sink: @Sendable ([Float]) -> Void = { samples in
            dual.enqueueStreaming(samples: samples)
        }
        await capture.setStreamingSink(sink)
    }

    /// Tear down the streaming pipeline. `graceful: true` flushes the
    /// trailing buffered samples through the EOU engine (ordering
    /// after `capture.stop` so we don't race late writer-queue
    /// buffers); `graceful: false` abandons immediately for cancel
    /// paths. Idempotent — safe to call on the v3 / JA path where
    /// `activeStreamingDual` is `nil`.
    ///
    /// Critically uses the *captured* `activeStreamingDual` rather
    /// than re-reading `holder.transcriber`. A mid-session
    /// `setPrimary` swap would change the holder's transcriber under
    /// us; without the captured reference, the downcast on cleanup
    /// would fail and the streaming engine that was actually started
    /// would leak (still running, still feeding the audio sink that
    /// will then be cleared by an unrelated session's setStreamingSink
    /// call). Capturing per session bounds the leak to "until the
    /// pipeline is cleared".
    private func endStreamingSession(graceful: Bool) async {
        guard let dual = activeStreamingDual else { return }
        defer { activeStreamingDual = nil }
        await capture.setStreamingSink(nil)
        if graceful {
            _ = await dual.finishStreaming()
        } else {
            await dual.cancelStreaming()
        }
        StreamingPartialStore.shared.endSession()
    }

    func stillActive(_ token: Token) -> Bool {
        generationCounter == token.generation
    }

    var isTranscriberReady: Bool {
        get async {
            await transcriber.isReady
        }
    }

    func ensureTranscriberLoaded() async throws {
        try await transcriber.ensureLoaded()
    }

    private func transcribe(recording: AudioRecording, token: Token) async throws -> String {
        let transcriber = self.transcriber

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var hasResumed = false

            func resumeOnce(_ result: Result<String, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            transcribeWatchdog?.cancel()
            transcribeWatchdog = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                guard let self, self.phaseMatches(token) else { return }
                self.log.warning("Transcribing watchdog fired after 30 s — invalidating token")
                self.invalidateIfMatching(token)
                resumeOnce(.failure(PipelineError.transcribeFailed(TranscribeTimeoutError())))
            }

            Task {
                do {
                    let result = try await transcriber.transcribe(recording.samples)
                    await MainActor.run {
                        self.transcribeWatchdog?.cancel()
                        self.transcribeWatchdog = nil
                        guard self.phaseMatches(token) else {
                            resumeOnce(.failure(PipelineError.tokenStale))
                            return
                        }
                        self.phase = .idle
                        resumeOnce(.success(result.text))
                    }
                } catch TranscriberError.audioTooShort {
                    await MainActor.run {
                        self.transcribeWatchdog?.cancel()
                        self.transcribeWatchdog = nil
                        guard self.phaseMatches(token) else {
                            resumeOnce(.failure(PipelineError.tokenStale))
                            return
                        }
                        self.phase = .idle
                        resumeOnce(.failure(PipelineError.audioTooShort(recording)))
                    }
                } catch TranscriberError.busy {
                    await MainActor.run {
                        self.transcribeWatchdog?.cancel()
                        self.transcribeWatchdog = nil
                        guard self.phaseMatches(token) else {
                            resumeOnce(.failure(PipelineError.tokenStale))
                            return
                        }
                        self.phase = .idle
                        resumeOnce(.failure(PipelineError.transcribeBusy))
                    }
                } catch TranscriberError.modelMissing, TranscriberError.modelNotLoaded {
                    await MainActor.run {
                        self.transcribeWatchdog?.cancel()
                        self.transcribeWatchdog = nil
                        guard self.phaseMatches(token) else {
                            resumeOnce(.failure(PipelineError.tokenStale))
                            return
                        }
                        self.phase = .idle
                        resumeOnce(.failure(PipelineError.modelMissing))
                    }
                } catch {
                    await MainActor.run {
                        self.transcribeWatchdog?.cancel()
                        self.transcribeWatchdog = nil
                        guard self.phaseMatches(token) else {
                            resumeOnce(.failure(PipelineError.tokenStale))
                            return
                        }
                        self.phase = .idle
                        resumeOnce(.failure(PipelineError.transcribeFailed(error)))
                    }
                }
            }
        }
    }

    private func issueToken(owner: Owner) -> Token {
        generationCounter += 1
        return Token(owner: owner, generation: generationCounter)
    }

    private func phaseMatches(_ token: Token) -> Bool {
        switch phase {
        case .idle:
            false
        case .recording(let current, _):
            current == token
        case .transcribing(let current):
            current == token
        }
    }

    private func clearIfMatching(_ token: Token) {
        guard phaseMatches(token) else { return }
        clearPhase()
    }

    private func invalidateIfMatching(_ token: Token) {
        guard phaseMatches(token) else { return }
        generationCounter += 1
        clearPhase()
    }

    private func invalidateGenerationIfCurrent(_ token: Token) {
        guard stillActive(token) else { return }
        generationCounter += 1
        clearPhase()
    }

    private func clearPhase() {
        transcribeWatchdog?.cancel()
        transcribeWatchdog = nil
        disconnectListenerTask?.cancel()
        disconnectListenerTask = nil
        disconnectCallback = nil
        // Trim the disconnect ledger so it doesn't grow unboundedly. Keep
        // only the last 16 generations — enough for a controller still
        // racing to inspect a freshly-cancelled session.
        if disconnectedGenerations.count > 16 {
            disconnectedGenerations = Set(disconnectedGenerations.suffix(16))
        }
        phase = .idle
    }

    /// Async accessor for the active capture's fallback info — used by
    /// controllers after a successful delivery to decide whether to
    /// surface the "Recorded with system default" notice pill.
    func lastFallbackInfo() async -> AudioCaptureFallbackInfo? {
        await capture.lastFallbackInfo()
    }
}
