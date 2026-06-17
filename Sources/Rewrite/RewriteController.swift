import AppKit
import Combine
import Foundation
import SwiftData
import os.log

/// Controller for Jot's selection-rewrite pipeline. Two public entry points:
///
///   * `toggle()` — the "Rewrite with Voice" flow: capture selection via
///     synthetic ⌘C, record a voice instruction, transcribe it through the
///     shared `VoiceInputPipeline`, hand the selection + instruction to the
///     LLM, paste the result back.
///
///   * `rewrite()` — the fixed-prompt flow: capture selection via
///     synthetic ⌘C, hand it to the LLM with the literal instruction
///     `"Rewrite this"`, paste the result back. No voice step, no pipeline.
@MainActor
final class RewriteController: ObservableObject {
    /// Published state for both rewrite flows. Shared with the status pill.
    ///
    /// - `capturing`: synthetic ⌘C pending / selection being resolved.
    /// - `recording`: (Rewrite with Voice only) mic is live for the voice instruction.
    /// - `transcribing`: (Rewrite with Voice only) Parakeet is turning the voice into text.
    /// - `rewriting`: LLM call in flight.
    enum RewriteState: Equatable, Sendable {
        case idle
        case capturing
        case recording(startedAt: Date)
        case transcribing
        case rewriting
        case error(String)

        static func == (lhs: RewriteState, rhs: RewriteState) -> Bool {
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

    /// Display label for the fixed-prompt Rewrite flow's Library row.
    /// **Not** sent to the LLM — the fixed path now calls
    /// `service.rewrite(... instruction: nil)`; the system prompt
    /// (`RewritePrompt.default`) governs no-instruction behavior. This
    /// constant exists solely so persisted rows in the Library / Home
    /// have a stable human-readable instruction column.
    static let fixedInstruction = "Rewrite this"

    /// Resolver for the user-selected default Rewrite prompt. Read on every
    /// TAP (`rewrite()`) so a default chosen in Settings → Prompts (or the
    /// hold-picker's "Set as default") takes effect on the next tap without
    /// restarting the graph. Returns `nil` when no default is selected OR
    /// the selection no longer resolves — in which case the tap falls back
    /// to today's behavior (the editable shared Rewrite prompt's
    /// no-instruction fallback). Wired by composition after `PromptStore`
    /// is built; `nil` (unwired test seams) means "always fall back".
    var defaultRewriteResolver: (@MainActor () -> (body: String, title: String)?)?

    @Published private(set) var state: RewriteState = .idle {
        didSet { scheduleAutoRecoveryIfNeeded() }
    }
    @Published private(set) var lastRewrite: String?
    /// Timestamp paired with `lastRewrite`. Updated on every write so
    /// `DeliveryService.pasteLast()` can compare against
    /// `RecorderController.lastTranscriptAt` and replay whichever
    /// output is more recent. Nil until the first rewrite completes.
    @Published private(set) var lastRewriteAt: Date?

    private let log = Logger(subsystem: "com.jot.Jot", category: "Rewrite")
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
    /// callers go through `AIServices.current(...).rewrite(...)`.
    private let llm: LLMClient?
    private let urlSession: URLSession
    private let appleIntelligence: any AppleIntelligenceClienting
    private let llmConfiguration: LLMConfiguration
    private let permissions: any PermissionsObserving
    private let pasteboard: any Pasteboarding
    private let logSink: any LogSink
    /// SwiftData context for persisting `RewriteSession` rows. Same
    /// `mainContext` instance as `RecordingPersister` and
    /// `RetentionService`. Optional so existing test seams that build
    /// a `RewriteController` without a context can keep compiling —
    /// when `nil`, persistence is skipped (the rewrite paste-back
    /// path is unaffected).
    private let modelContext: ModelContext?

    init(
        pipeline: VoiceInputPipeline,
        urlSession: URLSession,
        appleIntelligence: any AppleIntelligenceClienting,
        pasteboard: any Pasteboarding,
        llmConfiguration: LLMConfiguration,
        modelContext: ModelContext? = nil,
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
        self.modelContext = modelContext
        self.permissions = permissions ?? PermissionsService.shared
        self.logSink = logSink
    }

    /// Resolve the AI service for the current turn. When tests inject a
    /// custom `LLMClient` via `init(llm:)`, route through that instance
    /// directly so the seam stays addressable; otherwise fall through
    /// to the live dispatcher.
    private func rewriteService() -> any AIService {
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

    /// Snapshot the human-readable model label at the moment the
    /// service is resolved. Apple Intelligence stores just the
    /// provider's `displayName` (no SKU surface for FoundationModels);
    /// every other provider stores `"<displayName> · <effectiveModel>"`.
    /// Falls back to `displayName` alone when `effectiveModel(for:)`
    /// is empty — never produces a trailing dot.
    ///
    /// Composition uses `effectiveModel(for:)` (with `provider.defaultModel`
    /// fallback) rather than the raw `model(for:)` so the label reflects
    /// the SKU that will actually answer. See plan §3 for the full rule.
    private func snapshotModelLabel() -> String {
        let provider = llmConfiguration.provider
        let display = provider.displayName
        if provider == .appleIntelligence {
            return display
        }
        let effective = llmConfiguration.effectiveModel(for: provider)
        if effective.isEmpty {
            return display
        }
        return "\(display) · \(effective)"
    }

    // MARK: - Rewrite with Voice — voice-driven flow

    /// Rewrite with Voice. Capture selection, then record a voice instruction;
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
            log.info("toggle() ignored — rewrite in progress (\(String(describing: self.state)))")
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

    // MARK: - Rewrite — fixed-prompt flow

    /// Rewrite (fixed). One-shot: grab the selection, send it to the
    /// configured LLM with the literal instruction `"Rewrite this"` — no
    /// voice capture, no classifier step — and paste the result back.
    func rewrite() async {
        switch state {
        case .capturing, .recording, .transcribing, .rewriting:
            log.info("rewrite() ignored — rewrite in progress (\(String(describing: self.state)))")
            return
        case .idle, .error:
            break
        }

        // Resolve the user-selected default prompt, if any. When set, the
        // tap fires that prompt's body as a system-prompt override through
        // the same path the hold-picker uses — so "tap = my default prompt"
        // and "hold = pick a prompt" share one pipeline. When unset (or the
        // selection no longer resolves) we fall through to today's behavior:
        // no override, the editable shared Rewrite prompt governs.
        let resolvedDefault = defaultRewriteResolver?()

        let generation = nextFixedGeneration()
        activeFixedFlowTask = Task { @MainActor [weak self] in
            await self?.runFixed(
                generation: generation,
                systemPromptOverride: resolvedDefault?.body,
                instructionLabel: resolvedDefault?.title
            )
        }
    }

    /// Picker entry — Rewrite (fixed) with a hand-picked system-prompt
    /// override. Mirrors `rewrite()` exactly, except the LLM call uses
    /// the override as its system prompt (skipping the classifier). The
    /// `pickedTitle` is persisted as the row's instruction column so
    /// Home reads "Make formal" rather than the generic "Rewrite this".
    /// Voice-augment (⌘⏎ in the picker) is a separate entry point
    /// — see `rewriteWithVoice(systemPromptOverride:pickedTitle:)`.
    func rewrite(systemPromptOverride: String, pickedTitle: String) async {
        switch state {
        case .capturing, .recording, .transcribing, .rewriting:
            log.info("rewrite(picker) ignored — rewrite in progress (\(String(describing: self.state)))")
            return
        case .idle, .error:
            break
        }

        let generation = nextFixedGeneration()
        activeFixedFlowTask = Task { @MainActor [weak self] in
            await self?.runFixed(
                generation: generation,
                systemPromptOverride: systemPromptOverride,
                instructionLabel: pickedTitle
            )
        }
    }

    // MARK: - Rewrite with Voice internals

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
                    component: "Rewrite",
                    message: "Accessibility not granted (custom)",
                    context: ["flow": "custom"]
                )
            }
            state = .error("Grant Accessibility in System Settings for Rewrite.")
            return
        }

        // Snapshot the run's start timestamp so the persisted row's
        // `createdAt` reflects when the user invoked Rewrite, not when
        // the LLM happened to return.
        let createdAt = Date()

        do {
            try Task.checkCancellation()
            state = .capturing
            let selectedText = try await captureSelection()

            // Register an `onDisconnect` closure so a mid-recording mic
            // disconnect immediately resumes the parked second-toggle
            // continuation. Without this the user would be stuck
            // listening to silence until they tap again.
            // `stopAndTranscribe` then sees `didDisconnect(token) ==
            // true` and (because owner is `.rewrite`) throws
            // `disconnectedMidVoiceCommand`. The closure throws into the
            // continuation so the inner `do` flow handles it as cancel.
            let onDisconnect: @MainActor @Sendable () -> Void = { [weak self] in
                self?.takeSecondToggleContinuation()?.resume()
            }
            let token = try await pipeline.startRecording(
                owner: .rewrite,
                onDisconnect: onDisconnect
            )
            pipelineToken = token

            guard pipeline.stillActive(token) else { return }
            state = .recording(startedAt: Date())

            try await waitForSecondToggle()

            guard pipeline.stillActive(token) else { return }
            state = .transcribing

            let stopResult = try await pipeline.stopAndTranscribe(token)
            let instruction = stopResult.text

            guard pipeline.stillActive(token) else { return }
            guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Task {
                    await self.logSink.warn(
                        component: "Rewrite",
                        message: "Empty instruction after transcription",
                        context: ["flow": "custom"]
                    )
                }
                state = .error("Could not understand the instruction.")
                return
            }

            state = .rewriting
            let service = rewriteService()
            let modelLabel = snapshotModelLabel()
            let rewritten = try await service.rewrite(
                selectedText: selectedText,
                instruction: instruction
            )

            guard pipeline.stillActive(token) else { return }
            // Persist BEFORE paste so a paste failure doesn't lose the
            // row — Home becomes the recovery affordance for the rare
            // paste-failure case (plan §6).
            persistSession(
                flavor: "voice",
                selection: selectedText,
                instruction: instruction,
                output: rewritten,
                modelUsed: modelLabel,
                createdAt: createdAt
            )
            guard pasteReplacement(rewritten) else { return }

            guard pipeline.stillActive(token) else { return }
            lastRewrite = rewritten
            lastRewriteAt = .now
            state = .idle
        } catch is CancellationError {
            return
        } catch let error as RewriteError {
            Task {
                await self.logSink.error(
                    component: "Rewrite",
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
                    component: "Rewrite",
                    message: "Microphone not granted (custom)",
                    context: ["flow": "custom"]
                )
            }
            state = .error("Microphone permission is required.")
        } catch VoiceInputPipeline.PipelineError.engineStartTimeout {
            log.error("AudioCapture.start timed out — coreaudiod may be wedged")
            Task {
                await self.logSink.error(
                    component: "Rewrite",
                    message: "Audio engine setup timed out (>5s) — coreaudiod may be stuck; see Help → Troubleshooting"
                )
            }
            state = .error(AudioCaptureError.engineStartTimeoutMessage)
        } catch VoiceInputPipeline.PipelineError.engineStart(let error) {
            log.error("AudioCapture.start failed: \(String(describing: error))")
            Task {
                await self.logSink.error(
                    component: "Rewrite",
                    message: "AudioCapture.start failed (custom)",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
            }
            state = .error("Could not start recording: \(error.localizedDescription)")
        } catch VoiceInputPipeline.PipelineError.modelMissing {
            state = .error("Transcription model is still loading — try again in a moment.")
        } catch VoiceInputPipeline.PipelineError.disconnectedMidVoiceCommand {
            Task {
                await self.logSink.warn(
                    component: "Rewrite",
                    message: "Mic disconnected during voice instruction (custom)",
                    context: ["flow": "custom"]
                )
            }
            state = .error("Mic disconnected — try again.")
        } catch VoiceInputPipeline.PipelineError.audioTooShort(let recording) {
            Task {
                await self.logSink.warn(
                    component: "Rewrite",
                    message: "Instruction audio too short",
                    context: ["flow": "custom"]
                )
            }
            state = .error(shortRecordingMessage(for: recording))
        } catch VoiceInputPipeline.PipelineError.transcribeBusy {
            Task {
                await self.logSink.warn(
                    component: "Rewrite",
                    message: "Transcriber busy",
                    context: ["flow": "custom"]
                )
            }
            state = .error("Another transcription is already running.")
        } catch VoiceInputPipeline.PipelineError.transcribeFailed(let error) {
            log.error("Transcription failed: \(String(describing: error))")
            Task {
                await self.logSink.error(
                    component: "Rewrite",
                    message: "Instruction transcription failed",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
            }
            state = .error(transcriptionFailureMessage(for: error))
        } catch {
            log.error("LLM rewrite failed: \(String(describing: error))")
            Task {
                await self.logSink.error(
                    component: "Rewrite",
                    message: "LLM rewrite failed (custom)",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
            }
            state = .error("Rewrite failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Fixed flow internals

    private func runFixed(
        generation: UInt64,
        systemPromptOverride: String? = nil,
        instructionLabel: String? = nil
    ) async {
        defer { activeFixedFlowTask = nil }

        permissions.refreshAll()
        guard permissions.statuses[.accessibilityPostEvents] == .granted else {
            Task {
                await self.logSink.error(
                    component: "Rewrite",
                    message: "Accessibility not granted (fixed)",
                    context: ["flow": "fixed"]
                )
            }
            if stillFixedActive(generation) {
                state = .error("Grant Accessibility in System Settings for Rewrite.")
            }
            return
        }

        // Snapshot the run's start timestamp so the persisted row's
        // `createdAt` reflects when the user invoked Rewrite, not when
        // the LLM happened to return.
        let createdAt = Date()

        do {
            try Task.checkCancellation()
            guard stillFixedActive(generation) else { return }
            state = .capturing

            let selectedText = try await captureSelection()

            guard stillFixedActive(generation) else { return }
            state = .rewriting

            let service = rewriteService()
            let modelLabel = snapshotModelLabel()
            // `instruction: nil` signals the no-voice path. With no
            // override the system prompt's no-instruction fallback runs;
            // with an override (Prompt Picker path) the picked prompt
            // body is used verbatim.
            let rewritten = try await service.rewrite(
                selectedText: selectedText,
                instruction: nil,
                systemPromptOverride: systemPromptOverride
            )

            guard stillFixedActive(generation) else { return }
            // Persist BEFORE paste so a paste failure doesn't lose the
            // row — Home becomes the recovery affordance for the rare
            // paste-failure case (plan §6). Picker runs persist with the
            // picked prompt's title as the instruction column so the
            // library row reads e.g. "Make formal" rather than the
            // generic "Rewrite this".
            persistSession(
                flavor: "fixed",
                selection: selectedText,
                instruction: instructionLabel ?? Self.fixedInstruction,
                output: rewritten,
                modelUsed: modelLabel,
                createdAt: createdAt
            )
            guard pasteReplacement(rewritten) else { return }

            guard stillFixedActive(generation) else { return }
            lastRewrite = rewritten
            lastRewriteAt = .now
            state = .idle
        } catch is CancellationError {
            return
        } catch let error as RewriteError {
            guard stillFixedActive(generation) else { return }
            Task {
                await self.logSink.error(
                    component: "Rewrite",
                    message: "Selection capture failed (fixed)",
                    context: ["reason": String(error.message.prefix(80))]
                )
            }
            state = .error(error.message)
        } catch {
            guard stillFixedActive(generation) else { return }
            log.error("LLM rewrite (fixed) failed: \(String(describing: error))")
            Task {
                await self.logSink.error(
                    component: "Rewrite",
                    message: "LLM rewrite failed (fixed)",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
            }
            state = .error("Rewrite failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Shared selection-capture + paste-back

    /// Small typed error so both flows can translate capture failures into
    /// user-facing pill messages without leaking sandwich internals.
    private struct RewriteError: Error { let message: String }

    /// Synthetic ⌘C → read selection → restore clipboard. Shared by both
    /// rewrite flows. Throws a human-readable `RewriteError.message`
    /// that callers drop straight into `state = .error(...)`.
    ///
    /// Empty-selection detection: we CLEAR the pasteboard before the
    /// synthetic ⌘C so a no-selection state is detectable as "pasteboard
    /// still empty after the copy." Without the pre-clear, a previous
    /// ⌘C still on the clipboard would let an empty-selection ⌘C "pass
    /// the test" (the changeCount-only check is unreliable — some apps
    /// re-write the same content on every ⌘C, others do nothing, and we
    /// can't tell the cases apart). The deferred restore puts the
    /// user's original clipboard back regardless of which branch fires.
    private func captureSelection() async throws -> String {
        let snapshot = pasteboard.snapshot()
        var restored = false

        defer {
            if !restored {
                pasteboard.restore(snapshot)
            }
        }

        // Pre-clear so a no-op ⌘C leaves the pasteboard empty.
        _ = pasteboard.write("")
        let countAfterClear = pasteboard.changeCount

        do {
            try pasteboard.postCommandC()
        } catch {
            throw RewriteError(message: "Could not copy selection: \(error.localizedDescription)")
        }

        do {
            try await Task.sleep(for: .milliseconds(200))

            // Two-part empty-selection check, both treated the same so
            // the user sees a single clear message.
            // 1) No write happened → host app didn't respond to ⌘C
            //    (or there was nothing to copy).
            // 2) Write happened but resulting string is empty/whitespace.
            let countChanged = pasteboard.changeCount != countAfterClear
            let text = pasteboard.readString() ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard countChanged, !trimmed.isEmpty else {
                throw RewriteError(message: "No text selected. Select some text and try again.")
            }

            pasteboard.restore(snapshot)
            restored = true
            return text
        } catch {
            pasteboard.restore(snapshot)
            restored = true
            throw error
        }
    }

    /// Insert a `RewriteSession` row into the SwiftData store for a
    /// successful Rewrite run. Called on the LLM-success path of both
    /// `runCustom()` and `runFixed()`, *before* `pasteReplacement(...)` —
    /// so a paste failure doesn't lose the row (plan §6 resolution).
    /// Skipped silently when no `ModelContext` was injected (test seam
    /// path) or when the SwiftData save throws — persistence is a
    /// best-effort write and never blocks the rewrite UX.
    private func persistSession(
        flavor: String,
        selection: String,
        instruction: String,
        output: String,
        modelUsed: String?,
        createdAt: Date
    ) {
        guard let context = modelContext else { return }
        let session = RewriteSession(
            createdAt: createdAt,
            flavor: flavor,
            selectionText: selection,
            instructionText: instruction,
            output: output,
            modelUsed: modelUsed,
            title: RewriteSession.defaultTitle(from: output)
        )
        context.insert(session)
        do {
            try context.save()
        } catch {
            log.error("Failed to save RewriteSession: \(String(describing: error))")
            Task {
                await self.logSink.error(
                    component: "Rewrite",
                    message: "SwiftData save failed",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
            }
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
            Task { await self.logSink.error(component: "Rewrite", message: "Clipboard write failed") }
            state = .error("Clipboard write failed.")
            return false
        }

        do {
            try pasteboard.postCommandV()
        } catch {
            pasteboard.restore(snapshot)
            Task {
                await self.logSink.error(
                    component: "Rewrite",
                    message: "Synthetic paste failed",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
            }
            state = .error("Could not paste rewritten text: \(error.localizedDescription)")
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
