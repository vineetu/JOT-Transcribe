import Foundation
import os.log

@MainActor
final class VoiceInputPipeline {
    enum Owner: Sendable {
        case recorder
        case articulate
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
        permissions.refreshAll()
        guard permissions.statuses[.microphone] == .granted else {
            throw PipelineError.micNotGranted
        }

        guard case .idle = phase else {
            throw PipelineError.busy
        }

        let token = issueToken(owner: owner)
        phase = .recording(token, startedAt: Date())

        do {
            try await capture.start()
            do {
                try Task.checkCancellation()
            } catch is CancellationError {
                await capture.cancel()
                invalidateIfMatching(token)
                throw CancellationError()
            }
            phase = .recording(token, startedAt: Date())
            return token
        } catch is CancellationError {
            await capture.cancel()
            invalidateIfMatching(token)
            throw CancellationError()
        } catch AudioCaptureError.engineStartTimeout {
            clearIfMatching(token)
            throw PipelineError.engineStartTimeout
        } catch AudioCaptureError.engineStart(let error) {
            clearIfMatching(token)
            throw PipelineError.engineStart(error)
        } catch {
            clearIfMatching(token)
            throw PipelineError.engineStart(error)
        }
    }

    func stopAndTranscribe(_ token: Token) async throws -> (text: String, recording: AudioRecording) {
        guard case .recording(let current, _) = phase, current == token else {
            throw PipelineError.tokenStale
        }

        let recording: AudioRecording
        do {
            recording = try await capture.stop()
        } catch {
            clearIfMatching(token)
            throw PipelineError.transcribeFailed(error)
        }

        guard phaseMatches(token) else {
            throw PipelineError.tokenStale
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
        return (text, recording)
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

        invalidateGenerationIfCurrent(token)
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
        phase = .idle
    }
}
