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

    /// Default guidance shown on the capture pill for the plain
    /// `.rewriteWithVoice` hotkey when no Prompt-Picker hint is supplied.
    /// Without this the capture pill was visually identical to ordinary
    /// dictation, so users froze ("what's happening?"). It both states what
    /// to say and surfaces the empty-input escape hatch (say nothing → the
    /// selection is just cleaned up).
    static let defaultRewriteVoiceHint =
        "Say a change — e.g. “make it formal” — or nothing to just clean it up."

    /// What the typed panel's field asks for on the plain `.rewriteWithVoice`
    /// path. Mirrors `defaultRewriteVoiceHint` in surfacing the empty-input
    /// escape hatch. An augment run overrides this with the picked prompt's own
    /// hint, since only that prompt knows which detail it is missing.
    static let defaultPanelPlaceholder =
        "Describe the change — or just press ⏎ to clean it up"

    /// Upper bound on how long the mic stays open waiting for the user to
    /// finish the spoken instruction before we auto-stop and transcribe.
    /// Replaces the previous INDEFINITE wait, which left a frozen user staring
    /// at a pill that never resolved. On timeout we stop and transcribe
    /// whatever was captured: non-empty speech becomes the instruction (this
    /// alone fixes the "spoke but never pressed stop again" failure mode),
    /// silence runs with no detail (a clean-up on the plain path, or the picked
    /// prompt applied as-is when one supplied the system prompt). A second hotkey
    /// press, Esc, or a mic disconnect still resolves earlier; a user with
    /// long-form instructions can still press the hotkey to finish before the
    /// window elapses. Named so it is trivial to tune / make a setting later.
    static let secondToggleTimeout: Duration = .seconds(10)

    /// Longer idle bound that replaces the 10 s mic timer once the user starts
    /// TYPING (which cancels the mic timer). Without it, a user who types one
    /// character then walks away would park the continuation — and leave the
    /// panel on screen — forever. On this timeout the flow auto-finishes: the
    /// typed text (if any) becomes the detail, otherwise the run proceeds
    /// without one.
    static let typedPanelIdleTimeout: Duration = .seconds(30)

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
    /// Per-use voice-augment hint for the CURRENT Rewrite-with-Voice run, when
    /// it was started from the Prompt Picker on a prompt that carries a
    /// `voiceAugmentHint` (e.g. Translate → 'Say the target language…'). The
    /// status pill reads this while `state == .recording` so the user knows
    /// what detail to speak. `nil` for the plain `.rewriteWithVoice` hotkey
    /// path (no override, no hint) — behaves exactly as before. Set when the
    /// run enters `.recording`, cleared when it leaves.
    @Published private(set) var augmentHint: String?
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
    /// Fires `resumeSecondToggle()` after `secondToggleTimeout` so the mic
    /// wait is bounded. Cancelled the instant the continuation is taken by any
    /// path (user toggle, Esc/cancel, disconnect) so it never resumes twice.
    private var secondToggleTimeoutTask: Task<Void, Never>?
    // Kept through the rewrite tail so Esc can still invalidate generation
    // and suppress a late paste after the voice phase has finished.
    private var pipelineToken: VoiceInputPipeline.Token?
    private var fixedGenerationCounter: UInt64 = 0

    /// Typed instruction panel. Optional so test seams can build a controller
    /// without an AppKit panel (they pass `nil` and get the pure voice flow).
    /// Presented on both Rewrite-with-Voice paths — the plain hotkey and a
    /// picked prompt that needs a detail — when `RewriteTypedPanelSettings.isEnabled`.
    private let instructionPanel: (any RewriteInstructionPresenting)?

    /// How the current typed-panel run resolved, set by a panel callback just
    /// before it resumes the parked second-toggle continuation. `nil` means the
    /// wait resolved WITHOUT a typed decision (timeout, a second hotkey press, a
    /// mic disconnect, or an empty ⏎ while nothing was typed) — i.e. the classic
    /// voice/transcribe path. Consumed once per run in `runCustom`.
    private enum TypedPanelResolution {
        /// Non-empty typed text or a chip: skip transcription, rewrite with this.
        case typed(String)
        /// The user pressed ⏎ with an empty field AFTER having typed (so the mic
        /// is paused): run with no detail rather than falling back to voice.
        case noDetail
    }
    private var typedResolution: TypedPanelResolution?
    /// Set when the first keystroke lands in the panel: cancels the auto-finish
    /// timer and stops the mic so it doesn't keep capturing while the user types.
    private var micStoppedByTyping = false
    /// Live mirror of the panel field's text (via the panel's `onTextChange`).
    /// Lets a resolve that arrives WITHOUT a submit — a second hotkey press, or
    /// the idle timeout while typed — still salvage the typed instruction
    /// instead of throwing it away and doing a bare clean-up.
    private var currentPanelText = ""

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
        instructionPanel: (any RewriteInstructionPresenting)? = nil,
        logSink: any LogSink = ErrorLog.shared
    ) {
        self.pipeline = pipeline
        self.instructionPanel = instructionPanel
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

    /// Picker entry — Rewrite WITH VOICE on a hand-picked prompt that carries a
    /// `voiceAugmentHint`. Runs the same voice flow as `toggle()`, but the
    /// picked prompt's body becomes the LLM system-prompt override (skipping
    /// the classifier) and the spoken text becomes the `<instruction>`. The
    /// `augmentHint` is surfaced on the status pill during the voice capture so
    /// the user knows what detail to speak (e.g. the target language). The
    /// persisted row's instruction column uses the picked title. This is the
    /// implemented counterpart to the silent picker path
    /// (`rewrite(systemPromptOverride:pickedTitle:)`).
    func rewriteWithVoice(
        systemPromptOverride: String,
        pickedTitle: String,
        augmentHint: String?
    ) async {
        switch state {
        case .idle, .error:
            activeFlowTask = Task { @MainActor [weak self] in
                await self?.runCustom(
                    systemPromptOverride: systemPromptOverride,
                    pickedTitle: pickedTitle,
                    augmentHint: augmentHint
                )
            }
        case .recording:
            resumeSecondToggle()
        case .capturing, .transcribing, .rewriting:
            log.info("rewriteWithVoice(picker) ignored — rewrite in progress (\(String(describing: self.state)))")
        }
    }

    func cancel() async {
        // Focus discipline: order the typed panel out FIRST so key focus
        // returns to the target app. No paste follows a cancel, but dismissing
        // here also covers the global-Esc-hotkey cancel path (which doesn't go
        // through the panel's own Esc handler).
        instructionPanel?.dismiss()
        typedResolution = nil
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
    /// Prompts that carry a `voiceAugmentHint` take a separate voice path
    /// instead — see `rewriteWithVoice(systemPromptOverride:pickedTitle:augmentHint:)`.
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

    /// The Rewrite-with-Voice flow. When `systemPromptOverride` is nil (the
    /// plain `.rewriteWithVoice` hotkey path) the spoken or typed text is the
    /// instruction and the classifier-driven system prompt governs. When a
    /// picked prompt supplies an override + title + hint (the Prompt Picker
    /// augment path), the override becomes the LLM system prompt verbatim, the
    /// detail rides in as the `<instruction>`, the picked title labels the
    /// persisted row, and the hint is surfaced on the pill + the typed panel.
    ///
    /// Supplying no detail is valid on BOTH paths and never errors: the plain
    /// path cleans the selection up, and a picked prompt is simply applied as-is
    /// — the same result as picking a prompt that carries no hint at all.
    private func runCustom(
        systemPromptOverride: String? = nil,
        pickedTitle: String? = nil,
        augmentHint: String? = nil
    ) async {
        // Reset typed-panel state at run START (not only in the defer) so a
        // stray late callback from a prior run can never bleed a stale
        // resolution / text into this one.
        typedResolution = nil
        micStoppedByTyping = false
        currentPanelText = ""

        defer {
            activeFlowTask = nil
            pipelineToken = nil
            secondToggleTimeoutTask?.cancel()
            secondToggleTimeoutTask = nil
            secondToggleContinuation = nil
            self.augmentHint = nil
            // Belt-and-suspenders: any exit path (error, cancel) tears the panel
            // down. The success paths already dismissed it BEFORE pasting; this
            // is idempotent.
            instructionPanel?.dismiss()
            typedResolution = nil
            micStoppedByTyping = false
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
            // Surface the per-use augment hint (if any) BEFORE flipping to
            // `.recording` so the pill can show it the instant the mic opens.
            // On the plain `.rewriteWithVoice` hotkey path (no picker override,
            // no supplied hint) a default instructional hint stands in, because
            // an otherwise-bare capture pill is indistinguishable from ordinary
            // dictation and never says it wants an instruction. Empty input
            // still just cleans the selection up (see the empty-instruction
            // branch below), so the hint mentions that escape hatch too.
            let trimmedHint = augmentHint?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmedHint, !trimmedHint.isEmpty {
                self.augmentHint = trimmedHint
            } else if systemPromptOverride == nil {
                self.augmentHint = Self.defaultRewriteVoiceHint
            } else {
                self.augmentHint = nil
            }
            state = .recording(startedAt: Date())

            // The typed panel, on both paths, when enabled. The mic stays hot
            // (voice still works); the panel is an ADDITIVE way to type / tap a
            // chip. Presented AFTER `captureSelection()` has run, so the target
            // app's selection is already safely captured before the panel takes
            // key (focus discipline §3 item 1). If the panel can't become key
            // (rare WindowServer states), we dismiss it and fall through to the
            // pure voice+timeout flow — the timer is armed just below.
            presentTypedPanelIfEnabled(
                systemPromptOverride: systemPromptOverride,
                pickedTitle: pickedTitle,
                augmentHint: trimmedHint
            )

            try await waitForSecondToggle()

            // Focus discipline §3 item 3: order the panel out FIRST — key focus
            // returns to the target app — BEFORE any synthetic ⌘V fires below.
            instructionPanel?.dismiss()

            // Did the panel resolve this run with a typed instruction (or an
            // explicit empty-⏎-after-typing default)? If so, the mic was
            // already stopped on the first keystroke; skip transcription.
            if let resolution = typedResolution {
                typedResolution = nil
                if pipeline.stillActive(token) {
                    await pipeline.cancel(token: token)
                }
                try Task.checkCancellation()
                // The override and title ride along on both branches: the picked
                // prompt's body is the system prompt, and the typed text (if
                // any) is only its parameter ("Japanese"), which alone would
                // read as a generic rewrite. With them threaded through,
                // `instruction: nil` is already right for either path — a plain
                // run has no override so it cleans up, a picked run applies the
                // prompt as picked.
                switch resolution {
                case .typed(let typedText):
                    try await runResolvedRewriteTail(
                        selectedText: selectedText,
                        instruction: typedText,
                        createdAt: createdAt,
                        systemPromptOverride: systemPromptOverride,
                        pickedTitle: pickedTitle
                    )
                case .noDetail:
                    logNoDetailRun(source: "typed")
                    try await runResolvedRewriteTail(
                        selectedText: selectedText,
                        instruction: nil,
                        createdAt: createdAt,
                        systemPromptOverride: systemPromptOverride,
                        pickedTitle: pickedTitle
                    )
                }
                return
            }

            // Voice path (empty ⏎ without typing, timeout, second hotkey, or
            // mic disconnect). Typing supersedes speaking, so if a keystroke
            // stopped the mic there is by definition nothing worth
            // transcribing: salvage whatever is in the field instead.
            //
            // This is checked BEFORE `stillActive` deliberately.
            // `handlePanelFirstEdit` cancels the mic from a detached Task, and
            // the pipeline only invalidates the token AFTER the engine finishes
            // tearing down — so a resume landing inside that window would see
            // `stillActive == true`, transcribe a dead mic, and throw the typed
            // text away.
            if micStoppedByTyping {
                try Task.checkCancellation()
                let salvaged = currentPanelText.trimmingCharacters(in: .whitespacesAndNewlines)
                if salvaged.isEmpty { logNoDetailRun(source: "typed-salvage") }
                try await runResolvedRewriteTail(
                    selectedText: selectedText,
                    instruction: salvaged.isEmpty ? nil : salvaged,
                    createdAt: createdAt,
                    systemPromptOverride: systemPromptOverride,
                    pickedTitle: pickedTitle
                )
                return
            }
            guard pipeline.stillActive(token) else { return }
            state = .transcribing

            let instruction: String
            do {
                instruction = try await pipeline.stopAndTranscribe(token).text
            } catch VoiceInputPipeline.PipelineError.audioTooShort(let recording)
                where !shortRecordingLooksLikeMicRedirect(for: recording) {
                // Sub-second audio means the user gave no spoken instruction —
                // exactly what the pill and the panel's ⏎ placeholder invite.
                // Erroring would punish the gesture we documented, so it lands
                // on the same no-detail handling as an empty transcript.
                //
                // The `where` clause keeps the mic-redirect signature (wall
                // clock says they spoke, but no audio arrived) on the error
                // path below, where surfacing the diagnostic is the whole point.
                //
                // The pipeline sets `phase = .idle` here WITHOUT bumping its
                // generation, so this token is still live — same as the
                // empty-transcript route below, and it needs the same guard.
                logNoDetailRun(source: "audio-too-short")
                try await runResolvedRewriteTail(
                    selectedText: selectedText,
                    instruction: nil,
                    createdAt: createdAt,
                    systemPromptOverride: systemPromptOverride,
                    pickedTitle: pickedTitle,
                    activeToken: token
                )
                return
            }

            guard pipeline.stillActive(token) else { return }
            // Empty instruction is NOT a dead end. Saying nothing means "just
            // apply what I picked": on the plain path that's the no-instruction
            // clean-up the pill advertises, and on a picker run it applies the
            // picked prompt with no detail — identical to picking a prompt that
            // carries no hint at all, which has always worked. Erroring here
            // would strand the user for taking the escape hatch we offered.
            if instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logNoDetailRun(source: "transcription")
                try await runResolvedRewriteTail(
                    selectedText: selectedText,
                    instruction: nil,
                    createdAt: createdAt,
                    systemPromptOverride: systemPromptOverride,
                    pickedTitle: pickedTitle,
                    activeToken: token
                )
                return
            }

            try await runResolvedRewriteTail(
                selectedText: selectedText,
                instruction: instruction,
                createdAt: createdAt,
                systemPromptOverride: systemPromptOverride,
                pickedTitle: pickedTitle,
                activeToken: token
            )
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

    // MARK: - Typed panel

    /// Present the typed-instruction panel when enabled, and wire its callbacks
    /// back into this run. A `false` (couldn't-become-key) return dismisses the
    /// panel so we degrade cleanly to voice+timeout.
    ///
    /// Serves both paths, which want different things from the field:
    ///   * plain — a free-form instruction, plus the canned chips.
    ///   * augment — the pane wears the picked prompt's name, poses its hint as
    ///     a question above the field, seeds the field with just the example,
    ///     and suppresses the chips (which would fight the prompt's own body).
    private func presentTypedPanelIfEnabled(
        systemPromptOverride: String?,
        pickedTitle: String?,
        augmentHint: String?
    ) {
        guard RewriteTypedPanelSettings.isEnabled, let instructionPanel else { return }

        let isAugmentRun = systemPromptOverride != nil
        let hint = augmentHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A hintless picked prompt is applied silently by the picker (it never
        // reaches this flow at all), so this should be unreachable — but a panel
        // that can't say what it wants is worse than no panel, so if a caller
        // ever does route one here, fall back to the pure voice path.
        guard !isAugmentRun || !hint.isEmpty else {
            log.warning("Typed panel suppressed — augment run with no hint")
            return
        }

        // Split the augment hint into the question line + field placeholder so
        // "Say the target language (e.g. "to Japanese")" reads as a prompt
        // above an "e.g. to Japanese" field, not as text to delete.
        let parts = isAugmentRun ? RewriteHintFormatter.split(hint) : nil
        let becameKey = instructionPanel.present(
            title: isAugmentRun ? pickedTitle : nil,
            chips: isAugmentRun ? [] : Self.defaultChips(),
            questionLine: parts?.question,
            placeholder: isAugmentRun
                ? RewriteHintFormatter.fieldPlaceholder(for: hint)
                : Self.defaultPanelPlaceholder,
            onFirstEdit: { [weak self] in self?.handlePanelFirstEdit() },
            onTextChange: { [weak self] text in self?.currentPanelText = text },
            onSubmit: { [weak self] text in self?.handlePanelSubmit(text) },
            onCancel: { [weak self] in
                Task { @MainActor [weak self] in await self?.cancel() }
            }
        )
        if !becameKey {
            instructionPanel.dismiss()
        }
    }

    /// Canned chips shown in the panel. Translate targets the last-used
    /// language (defaults to Spanish) — kept deliberately simple for v1.
    private static func defaultChips() -> [RewriteInstructionChip] {
        let language = RewriteTypedPanelSettings.lastTranslateLanguage
        return [
            RewriteInstructionChip(label: "Formal", instruction: "Make it more formal"),
            RewriteInstructionChip(label: "Shorter", instruction: "Make it shorter"),
            RewriteInstructionChip(
                label: "Translate to \(language)",
                instruction: "Translate to \(language)"
            ),
        ]
    }

    /// First keystroke in the panel: cancel the 10 s mic timer (so it can't fire
    /// mid-type), stop the mic (typing supersedes speaking), stop the pill
    /// claiming to be listening, and re-arm a LONGER idle timer so an abandoned
    /// panel auto-finishes rather than parking the continuation forever. The
    /// parked continuation otherwise stays parked until the user submits/cancels.
    private func handlePanelFirstEdit() {
        guard !micStoppedByTyping else { return }
        micStoppedByTyping = true
        // The mic is being paused — don't keep advertising "listening".
        if augmentHint != nil { augmentHint = "Typing…" }
        if let token = pipelineToken {
            Task { @MainActor [weak self] in
                await self?.pipeline.cancel(token: token)
            }
        }
        // Replace the (now-cancelled) 10 s mic timer with a longer idle
        // bound. Reuses the `secondToggleTimeoutTask` slot, so
        // `takeSecondToggleContinuation()` cancels it on any resolve. On this
        // resume the mic is dead → the voice-fallback branch salvages
        // `currentPanelText` (or cleans up if empty).
        secondToggleTimeoutTask?.cancel()
        secondToggleTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.typedPanelIdleTimeout)
            guard !Task.isCancelled else { return }
            self?.resumeSecondToggle()
        }
    }

    /// Panel submit (⏎ or a chip). Records how the run resolved, then resumes
    /// the parked continuation so `runCustom` proceeds to the rewrite tail.
    private func handlePanelSubmit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            typedResolution = .typed(trimmed)
            // Persist the last translate language when the user submits a
            // "Translate to <lang>" style instruction so the chip stays useful.
            noteTranslateLanguageIfPresent(trimmed)
        } else if micStoppedByTyping {
            // Typed then cleared → explicitly run with no detail (mic is paused).
            typedResolution = .noDetail
        } else {
            // Empty ⏎ with the mic still hot: fall through to the voice path so
            // anything spoken becomes the detail; silence runs with none.
            typedResolution = nil
        }
        resumeSecondToggle()
    }

    /// Best-effort capture of a translate target from a typed instruction like
    /// "translate to French" so the chip reflects the user's last choice.
    private func noteTranslateLanguageIfPresent(_ instruction: String) {
        // Search the ORIGINAL string case-insensitively so the captured
        // language keeps the user's casing (e.g. "French"), and so we never
        // rely on lowercasing preserving character offsets (it doesn't for all
        // Unicode). Everything after "translate to " is the target language.
        guard let range = instruction.range(of: "translate to ", options: .caseInsensitive) else { return }
        let language = instruction[range.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!,;:"))
        guard !language.isEmpty, language.count <= 40 else { return }
        UserDefaults.standard.set(language, forKey: RewriteTypedPanelSettings.lastTranslateLanguageKey)
    }

    /// Trace a run that resolved with NO detail — the four routes that reach the
    /// tail with `instruction: nil`. These are the runs a user is most likely to
    /// report as "it didn't do what I asked", and after the fact the log is the
    /// only way to tell which route produced one; `source` names it.
    private func logNoDetailRun(source: String) {
        Task { [source] in
            await self.logSink.info(
                component: "Rewrite",
                message: "No detail supplied — applying without one",
                context: ["flow": "custom", "source": source]
            )
        }
    }

    /// The single LLM rewrite + persist + paste tail for EVERY Rewrite-with-Voice
    /// route — typed, chip, salvaged, spoken, and no-detail-at-all. It is one
    /// function on purpose: when the routes had their own copies, one of them
    /// hardcoded `systemPromptOverride: nil` and silently discarded the prompt
    /// the user had picked.
    ///
    /// `instruction == nil` is the no-detail case, and needs no special-casing
    /// by path: with no override it runs the shared prompt's no-instruction
    /// clean-up, and with one it applies the picked prompt exactly as the silent
    /// picker path (`runFixed`) does.
    ///
    /// `systemPromptOverride` / `pickedTitle` carry a picked prompt through from
    /// `runCustom`: the override IS the system prompt (verbatim) and the resolved
    /// text is only its `<instruction>` parameter.
    ///
    /// Cancellation: `cancel()` cancels `activeFlowTask`, so `checkCancellation`
    /// covers every route. `activeToken` additionally guards the routes that
    /// arrive with a LIVE pipeline token — the pipeline goes `.idle` once
    /// transcription lands, so another owner can claim it during the LLM call
    /// and that stale run must not paste. Panel-resolved routes pass nil: their
    /// token is already torn down, so it would be a meaningless guard.
    private func runResolvedRewriteTail(
        selectedText: String,
        instruction: String?,
        createdAt: Date,
        systemPromptOverride: String? = nil,
        pickedTitle: String? = nil,
        activeToken: VoiceInputPipeline.Token? = nil
    ) async throws {
        state = .rewriting
        let service = rewriteService()
        let modelLabel = snapshotModelLabel()
        let rewritten = try await service.rewrite(
            selectedText: selectedText,
            instruction: instruction,
            systemPromptOverride: systemPromptOverride
        )
        try Task.checkCancellation()
        if let activeToken, !pipeline.stillActive(activeToken) { return }

        let detail = instruction?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDetail = !(detail?.isEmpty ?? true)
        let title = pickedTitle.flatMap { $0.isEmpty ? nil : $0 }
        // Home has to say which prompt ran and with what. A no-detail picked run
        // labels by title alone — matching what `runFixed` persists for the
        // silent picker path — never "Rewrite this", which would erase the fact
        // that the user picked Translate.
        let instructionLabel: String = {
            guard hasDetail, let instruction else { return title ?? Self.fixedInstruction }
            guard let title else { return instruction }
            return "\(title) — \(instruction)"
        }()
        // Persist BEFORE paste so a paste failure doesn't lose the row — Home
        // becomes the recovery affordance for the rare paste-failure case
        // (plan §6). A no-detail run is a `fixed`-flavored row for the same
        // reason `runFixed` calls it that: no spoken/typed instruction shaped it.
        persistSession(
            flavor: hasDetail ? "voice" : "fixed",
            selection: selectedText,
            instruction: instructionLabel,
            output: rewritten,
            modelUsed: modelLabel,
            createdAt: createdAt
        )
        try Task.checkCancellation()
        guard pasteReplacement(rewritten) else { return }
        if let activeToken, !pipeline.stillActive(activeToken) { return }
        lastRewrite = rewritten
        lastRewriteAt = .now
        state = .idle
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
            // Bound the wait. Auto-finish is identical to the user pressing the
            // hotkey again — `resumeSecondToggle` funnels through
            // `takeSecondToggleContinuation`, which atomically nils the
            // continuation, so whichever of {timeout, toggle, disconnect,
            // cancel} lands first wins and the rest are no-ops. Everything runs
            // on the MainActor, so there is no interleaving between the
            // isCancelled check and the nil-out.
            secondToggleTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.secondToggleTimeout)
                guard !Task.isCancelled else { return }
                self?.resumeSecondToggle()
            }
        }
    }

    private func resumeSecondToggle() {
        takeSecondToggleContinuation()?.resume()
    }

    private func takeSecondToggleContinuation() -> CheckedContinuation<Void, Error>? {
        secondToggleTimeoutTask?.cancel()
        secondToggleTimeoutTask = nil
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
