import AppKit
import Combine
import Foundation
import os.log

/// Controller for Jot's selection-rewrite pipeline. Two public entry points:
///
///   * `toggle()` — the "Articulate (Custom)" flow: capture selection via
///     synthetic ⌘C, record a voice instruction, transcribe it through the
///     shared `VoiceInputPipeline`, hand the selection + instruction to the
///     LLM, paste the result back.
///
///   * `articulate()` — the fixed-prompt flow: capture selection via
///     synthetic ⌘C, hand it to the LLM with the literal instruction
///     `"Articulate this"`, paste the result back. No voice step, no pipeline.
@MainActor
final class ArticulateController: ObservableObject {
    /// Published state for both articulate flows. Shared with the status pill.
    ///
    /// - `capturing`: synthetic ⌘C pending / selection being resolved.
    /// - `recording`: (Articulate Custom only) mic is live for the voice instruction.
    /// - `transcribing`: (Articulate Custom only) Parakeet is turning the voice into text.
    /// - `rewriting`: LLM call in flight.
    enum ArticulateState: Equatable, Sendable {
        case idle
        case capturing
        case recording(startedAt: Date)
        case transcribing
        case rewriting
        case error(String)

        static func == (lhs: ArticulateState, rhs: ArticulateState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.capturing, .capturing),
                 (.transcribing, .transcribing), (.rewriting, .rewriting):
                true
            case (.recording(let a), .recording(let b)):
                a == b
            case (.error(let a), .error(let b)):
                a == b
            default:
                false
            }
        }
    }

    /// Hardcoded instruction for the fixed-prompt Articulate flow. Intentional
    /// verbatim wording per product choice — do not paraphrase.
    static let fixedInstruction = "Articulate this"

    @Published private(set) var state: ArticulateState = .idle {
        didSet { scheduleAutoRecoveryIfNeeded() }
    }
    @Published private(set) var lastArticulation: String?

    private let log = Logger(subsystem: "com.jot.Jot", category: "Articulate")
    private var autoRecoveryTask: Task<Void, Never>?
    private var activeFlowTask: Task<Void, Never>?
    private var activeFixedFlowTask: Task<Void, Never>?
    private var secondToggleContinuation: CheckedContinuation<Void, Error>?
    // Kept through the rewrite tail so Esc can still invalidate generation
    // and suppress a late paste after the voice phase has finished.
    private var pipelineToken: VoiceInputPipeline.Token?
    private var fixedGenerationCounter: UInt64 = 0

    private let pipeline: VoiceInputPipeline
    /// Direct `LLMClient` retained alongside the dispatcher path so
    /// the existing `init(llm:)` test seam keeps working — the
    /// regression-test surface in `Phase4PatchRegressionTests` injects
    /// a custom client via this parameter to force-route Apple
    /// Intelligence and verify the seam wiring. Tier 3 production
    /// callers go through `AIServices.current(...).articulate(...)`.
    private let llm: LLMClient?
    private let urlSession: URLSession
    private let appleIntelligence: any AppleIntelligenceClienting
    private let llmConfiguration: LLMConfiguration
    private let permissions: any PermissionsObserving
    private let pasteboard: any Pasteboarding
    private let logSink: any LogSink

    init(
        pipeline: VoiceInputPipeline,
        urlSession: URLSession,
        appleIntelligence: any AppleIntelligenceClienting,
        pasteboard: any Pasteboarding,
        llmConfiguration: LLMConfiguration,
        llm: LLMClient? = nil,
        permissions: (any PermissionsObserving)? = nil,
        logSink: any LogSink = ErrorLog.shared
    ) {
        self.pipeline = pipeline
        self.pasteboard = pasteboard
        self.llm = llm
        self.urlSession = urlSession
        self.appleIntelligence = appleIntelligence
        self.llmConfiguration = llmConfiguration
        self.permissions = permissions ?? PermissionsService.shared
        self.logSink = logSink
    }

    /// Resolve the AI service for the current turn. When tests inject a
    /// custom `LLMClient` via `init(llm:)`, route through that instance
    /// directly so the seam stays addressable; otherwise fall through
    /// to the live dispatcher.
    private func articulateService() -> any AIService {
        if let llm {
            return DirectLLMClientAIService(client: llm)
        }
        return AIServices.current(
            configuration: llmConfiguration,
            urlSession: urlSession,
            appleClient: appleIntelligence,
            logSink: logSink
        )
    }

    // MARK: - Articulate (Custom) — voice-driven flow

    /// Articulate (Custom). Capture selection, then record a voice instruction;
    /// on the second toggle press, stop + transcribe + LLM + paste.
    func toggle() async {
        switch state {
        case .idle, .error:
            activeFlowTask = Task { @MainActor [weak self] in
                await self?.runCustom()
            }
        case .recording:
            resumeSecondToggle()
        case .capturing, .transcribing, .rewriting:
            log.info("toggle() ignored — articulate in progress (\(String(describing: self.state)))")
        }
    }

    func cancel() async {
        activeFlowTask?.cancel()
        activeFlowTask = nil
        takeSecondToggleContinuation()?.resume(throwing: CancellationError())

        let token = pipelineToken
        pipelineToken = nil

        let hadFixedFlow = activeFixedFlowTask != nil
        activeFixedFlowTask?.cancel()
        activeFixedFlowTask = nil
        if hadFixedFlow {
            fixedGenerationCounter += 1
        }

        switch state {
        case .capturing, .recording, .transcribing, .rewriting:
            state = .idle
        case .idle, .error:
            break
        }

        if let token {
            await pipeline.cancel(token: token)
        }
    }

    // MARK: - Articulate — fixed-prompt flow

    /// Articulate (fixed). One-shot: grab the selection, send it to the
    /// configured LLM with the literal instruction `"Articulate this"` — no
    /// voice capture, no classifier step — and paste the result back.
    func articulate() async {
        switch state {
        case .capturing, .recording, .transcribing, .rewriting:
            log.info("articulate() ignored — articulate in progress (\(String(describing: self.state)))")
            return
        case .idle, .error:
            break
        }

        let generation = nextFixedGeneration()
        activeFixedFlowTask = Task { @MainActor [weak self] in
            await self?.runFixed(generation: generation)
        }
    }

    // MARK: - Articulate (Custom) internals

    private func runCustom() async {
        defer {
            activeFlowTask = nil
            pipelineToken = nil
            secondToggleContinuation = nil
        }

        permissions.refreshAll()
        guard permissions.statuses[.accessibilityPostEvents] == .granted else {
            Task {
                await self.logSink.error(
                    component: "Articulate",
                    message: "Accessibility not granted (custom)",
                    context: ["flow": "custom"]
                )
            }
            state = .error("Grant Accessibility in System Settings for Articulate.")
            return
        }

        do {
            try Task.checkCancellation()
            state = .capturing
            let selectedText = try await captureSelection()

            let token = try await pipeline.startRecording(owner: .articulate)
            pipelineToken = token

            guard pipeline.stillActive(token) else { return }
            state = .recording(startedAt: Date())

            try await waitForSecondToggle()

            guard pipeline.stillActive(token) else { return }
            state = .transcribing

            let (instruction, _) = try await pipeline.stopAndTranscribe(token)

            guard pipeline.stillActive(token) else { return }
            guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Task {
                    await self.logSink.warn(
                        component: "Articulate",
                        message: "Empty instruction after transcription",
                        context: ["flow": "custom"]
                    )
                }
                state = .error("Could not understand the instruction.")
                return
            }

            state = .rewriting
            let service = articulateService()
            let rewritten = try await service.articulate(
                selectedText: selectedText,
                instruction: instruction
            )

            guard pipeline.stillActive(token) else { return }
            guard pasteReplacement(rewritten) else { return }

            guard pipeline.stillActive(token) else { return }
            lastArticulation = rewritten
            state = .idle
        } catch is CancellationError {
            return
        } catch let error as ArticulateError {
            Task {
                await self.logSink.error(
                    component: "Articulate",
                    message: "Selection capture failed (custom)",
                    context: ["reason": String(error.message.prefix(80))]
                )
            }
            state = .error(error.message)
        } catch VoiceInputPipeline.PipelineError.busy {
            state = .error("Another flow is running.")
        } catch VoiceInputPipeline.PipelineError.tokenStale {
            return
        } catch VoiceInputPipeline.PipelineError.micNotGranted {
            Task {
                await self.logSink.error(
                    component: "Articulate",
                    message: "Microphone not granted (custom)",
                    context: ["flow": "custom"]
                )
            }
            state = .error("Microphone permission is required.")
        } catch VoiceInputPipeline.PipelineError.engineStartTimeout {
            log.error("AudioCapture.start timed out — coreaudiod may be wedged")
            Task {
                await self.logSink.error(
                    component: "Articulate",
                    message: "Audio engine setup timed out (>5s) — coreaudiod may be stuck; see Help → Troubleshooting"
                )
            }
            state = .error(AudioCaptureError.engineStartTimeoutMessage)
        } catch VoiceInputPipeline.PipelineError.engineStart(let error) {
            log.error("AudioCapture.start failed: \(String(describing: error))")
            Task {
                await self.logSink.error(
                    component: "Articulate",
                    message: "AudioCapture.start failed (custom)",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
            }
            state = .error("Could not start recording: \(error.localizedDescription)")
        } catch VoiceInputPipeline.PipelineError.modelMissing {
            state = .error("Transcription model is still loading — try again in a moment.")
        } catch VoiceInputPipeline.PipelineError.audioTooShort(let recording) {
            Task {
                await self.logSink.warn(
                    component: "Articulate",
                    message: "Instruction audio too short",
                    context: ["flow": "custom"]
                )
            }
            state = .error(shortRecordingMessage(for: recording))
        } catch VoiceInputPipeline.PipelineError.transcribeBusy {
            Task {
                await self.logSink.warn(
                    component: "Articulate",
                    message: "Transcriber busy",
                    context: ["flow": "custom"]
                )
            }
            state = .error("Another transcription is already running.")
        } catch VoiceInputPipeline.PipelineError.transcribeFailed(let error) {
            log.error("Transcription failed: \(String(describing: error))")
            Task {
                await self.logSink.error(
                    component: "Articulate",
                    message: "Instruction transcription failed",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
            }
            state = .error(transcriptionFailureMessage(for: error))
        } catch {
            log.error("LLM articulate failed: \(String(describing: error))")
            Task {
                await self.logSink.error(
                    component: "Articulate",
                    message: "LLM articulate failed (custom)",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
            }
            state = .error("Articulate failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Fixed flow internals

    private func runFixed(generation: UInt64) async {
        defer { activeFixedFlowTask = nil }

        permissions.refreshAll()
        guard permissions.statuses[.accessibilityPostEvents] == .granted else {
            Task {
                await self.logSink.error(
                    component: "Articulate",
                    message: "Accessibility not granted (fixed)",
                    context: ["flow": "fixed"]
                )
            }
            if stillFixedActive(generation) {
                state = .error("Grant Accessibility in System Settings for Articulate.")
            }
            return
        }

        do {
            try Task.checkCancellation()
            guard stillFixedActive(generation) else { return }
            state = .capturing

            let selectedText = try await captureSelection()

            guard stillFixedActive(generation) else { return }
            state = .rewriting

            let service = articulateService()
            let rewritten = try await service.articulate(
                selectedText: selectedText,
                instruction: Self.fixedInstruction
            )

            guard stillFixedActive(generation) else { return }
            guard pasteReplacement(rewritten) else { return }

            guard stillFixedActive(generation) else { return }
            lastArticulation = rewritten
            state = .idle
        } catch is CancellationError {
            return
        } catch let error as ArticulateError {
            guard stillFixedActive(generation) else { return }
            Task {
                await self.logSink.error(
                    component: "Articulate",
                    message: "Selection capture failed (fixed)",
                    context: ["reason": String(error.message.prefix(80))]
                )
            }
            state = .error(error.message)
        } catch {
            guard stillFixedActive(generation) else { return }
            log.error("LLM articulate (fixed) failed: \(String(describing: error))")
            Task {
                await self.logSink.error(
                    component: "Articulate",
                    message: "LLM articulate failed (fixed)",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
            }
            state = .error("Articulate failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Shared selection-capture + paste-back

    /// Small typed error so both flows can translate capture failures into
    /// user-facing pill messages without leaking sandwich internals.
    private struct ArticulateError: Error { let message: String }

    /// Synthetic ⌘C → read selection → restore clipboard. Shared by both
    /// articulate flows. Throws a human-readable `ArticulateError.message`
    /// that callers drop straight into `state = .error(...)`.
    private func captureSelection() async throws -> String {
        let snapshot = pasteboard.snapshot()
        let changeCountBefore = pasteboard.changeCount
        var restored = false

        defer {
            if !restored {
                pasteboard.restore(snapshot)
            }
        }

        do {
            try pasteboard.postCommandC()
        } catch {
            throw ArticulateError(message: "Could not copy selection: \(error.localizedDescription)")
        }

        do {
            try await Task.sleep(for: .milliseconds(200))

            guard pasteboard.changeCount != changeCountBefore else {
                throw ArticulateError(message: "No text was copied. Make sure text is selected.")
            }

            guard let selectedText = pasteboard.readString(),
                  !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ArticulateError(message: "No text selected.")
            }

            pasteboard.restore(snapshot)
            restored = true
            return selectedText
        } catch {
            pasteboard.restore(snapshot)
            restored = true
            throw error
        }
    }

    /// Write `rewritten` to the clipboard, synthesize a ⌘V to paste-replace
    /// the live selection, then restore the clipboard after the target app
    /// has had a chance to consume the paste. Returns false and sets
    /// `state = .error(...)` on failure; caller returns immediately.
    @discardableResult
    private func pasteReplacement(_ rewritten: String) -> Bool {
        let snapshot = pasteboard.snapshot()
        guard pasteboard.write(rewritten) else {
            pasteboard.restore(snapshot)
            Task { await self.logSink.error(component: "Articulate", message: "Clipboard write failed") }
            state = .error("Clipboard write failed.")
            return false
        }

        do {
            try pasteboard.postCommandV()
        } catch {
            pasteboard.restore(snapshot)
            Task {
                await self.logSink.error(
                    component: "Articulate",
                    message: "Synthetic paste failed",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
            }
            state = .error("Could not paste articulated text: \(error.localizedDescription)")
            return false
        }

        // Restore clipboard after the target app has time to consume the paste.
        let pasteboard = self.pasteboard
        Task { @MainActor [snapshot, pasteboard] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            pasteboard.restore(snapshot)
        }
        return true
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

    private func waitForSecondToggle() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            secondToggleContinuation = continuation
        }
    }

    private func resumeSecondToggle() {
        takeSecondToggleContinuation()?.resume()
    }

    private func takeSecondToggleContinuation() -> CheckedContinuation<Void, Error>? {
        let continuation = secondToggleContinuation
        secondToggleContinuation = nil
        return continuation
    }

    private func nextFixedGeneration() -> UInt64 {
        fixedGenerationCounter += 1
        return fixedGenerationCounter
    }

    private func stillFixedActive(_ generation: UInt64) -> Bool {
        fixedGenerationCounter == generation
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
