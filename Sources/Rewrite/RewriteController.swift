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

    /// Upper bound on how long the mic stays open waiting for the user to
    /// finish the spoken instruction before we auto-stop and transcribe.
    /// Replaces the previous INDEFINITE wait, which left a frozen user staring
    /// at a pill that never resolved. On timeout we stop and transcribe
    /// whatever was captured: non-empty speech becomes the instruction (this
    /// alone fixes the "spoke but never pressed stop again" failure mode),
    /// silence falls through to the default clean-up rewrite. A second hotkey
    /// press, Esc, or a mic disconnect still resolves earlier; a user with
    /// long-form instructions can still press the hotkey to finish before the
    /// window elapses. Named so it is trivial to tune / make a setting later.
    static let secondToggleTimeout: Duration = .seconds(10)

    /// Longer idle bound that replaces the 10 s mic timer once the user starts
    /// TYPING (which cancels the mic timer). Without it, a user who types one
    /// character then walks away would park the continuation — and leave the
    /// panel on screen — forever. On this timeout the flow auto-finishes: the
    /// typed text (if any) becomes the instruction, otherwise a clean-up runs.
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
        /// is paused): route to the default clean-up rather than to voice.
        case defaultCleanup
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
    /// plain `.rewriteWithVoice` hotkey path) it behaves exactly as before:
    /// the spoken text is the instruction and the classifier-driven system
    /// prompt governs. When a picked prompt supplies an override + title +
    /// optional hint (the Prompt Picker augment path), the override becomes the
    /// LLM system prompt verbatim, the picked title is persisted as the row's
    /// instruction label, and the hint is surfaced on the pill during capture.
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

        // A picked prompt supplied the system prompt and is waiting on a detail
        // to parameterize it. The two paths disagree on what "the user gave no
        // instruction" means — see the empty-instruction branches below — so
        // every such branch keys off this.
        let isAugmentRun = systemPromptOverride != nil

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
            // no supplied hint) we now inject a default instructional hint so
            // the capture pill explains what to say — the Phase-0 fix for
            // "I pressed the key and froze because nothing told me it wanted an
            // instruction about my selection." Empty input still just cleans it
            // up (see the empty-instruction branch below), so the hint mentions
            // that escape hatch too.
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
                switch resolution {
                case .typed(let typedText):
                    // The override and title MUST ride along: on an augment run
                    // the picked prompt's body is the system prompt and the
                    // typed text is only its parameter ("Japanese"), which alone
                    // would read as a generic rewrite.
                    try await runResolvedRewriteTail(
                        selectedText: selectedText,
                        instruction: typedText,
                        createdAt: createdAt,
                        systemPromptOverride: systemPromptOverride,
                        pickedTitle: pickedTitle
                    )
                case .defaultCleanup:
                    // Only the plain path has a sensible no-instruction form. A
                    // picked prompt without its detail is the same genuine miss
                    // as saying nothing to it — never a silent clean-up.
                    guard !isAugmentRun else {
                        reportMissingAugmentDetail(source: "typed")
                        return
                    }
                    try await runResolvedRewriteTail(
                        selectedText: selectedText,
                        instruction: nil,
                        createdAt: createdAt
                    )
                }
                return
            }

            // Voice path (empty ⏎ without typing, timeout, second hotkey, or
            // mic disconnect). If typing already stopped the mic — the user
            // typed then pressed the hotkey again, or the idle timer fired —
            // there's nothing to transcribe. Salvage the typed text as the
            // instruction if the field has any; only fall to a bare clean-up
            // when it's empty.
            guard pipeline.stillActive(token) else {
                if micStoppedByTyping {
                    try Task.checkCancellation()
                    let salvaged = currentPanelText.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Same asymmetry as the ⏎ branch: an augment run that ends
                    // with an empty field has lost its parameter, so it errors
                    // rather than quietly cleaning the selection up.
                    guard !(salvaged.isEmpty && isAugmentRun) else {
                        reportMissingAugmentDetail(source: "typed-salvage")
                        return
                    }
                    try await runResolvedRewriteTail(
                        selectedText: selectedText,
                        instruction: salvaged.isEmpty ? nil : salvaged,
                        createdAt: createdAt,
                        systemPromptOverride: systemPromptOverride,
                        pickedTitle: pickedTitle
                    )
                }
                return
            }
            state = .transcribing

            let stopResult = try await pipeline.stopAndTranscribe(token)
            let instruction = stopResult.text

            guard pipeline.stillActive(token) else { return }
            // Empty instruction is NOT a dead end. If the user pressed the
            // hotkey and said nothing understandable, "just rewrite it" was
            // almost certainly the intent — so we fall back to the fixed-
            // prompt default rewrite (instruction: nil → the no-instruction
            // system-prompt fallback) instead of erroring. This is the
            // Phase-0 fix for the "I froze and got an error" complaint.
            // Only the plain hotkey path defaults; a Prompt-Picker augment run
            // (systemPromptOverride present) still needs its spoken detail, so
            // an empty instruction there remains a genuine miss.
            let instructionIsEmpty = instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if instructionIsEmpty && systemPromptOverride == nil {
                Task {
                    await self.logSink.info(
                        component: "Rewrite",
                        message: "Empty instruction — defaulting to fixed rewrite",
                        context: ["flow": "custom"]
                    )
                }
                state = .rewriting
                let service = rewriteService()
                let modelLabel = snapshotModelLabel()
                let rewritten = try await service.rewrite(
                    selectedText: selectedText,
                    instruction: nil,
                    systemPromptOverride: nil
                )
                guard pipeline.stillActive(token) else { return }
                persistSession(
                    flavor: "fixed",
                    selection: selectedText,
                    instruction: Self.fixedInstruction,
                    output: rewritten,
                    modelUsed: modelLabel,
                    createdAt: createdAt
                )
                guard pasteReplacement(rewritten) else { return }
                guard pipeline.stillActive(token) else { return }
                lastRewrite = rewritten
                lastRewriteAt = .now
                state = .idle
                return
            }
            guard !instructionIsEmpty else {
                Task {
                    await self.logSink.warn(
                        component: "Rewrite",
                        message: "Empty instruction after transcription (augment path)",
                        context: ["flow": "custom"]
                    )
                }
                state = .error("Could not understand the instruction.")
                return
            }

            state = .rewriting
            let service = rewriteService()
            let modelLabel = snapshotModelLabel()
            // When a picked prompt supplied an override its body IS the system
            // prompt (verbatim) and the spoken text rides in the `<instruction>`
            // block; when nil this is the classic classifier-driven path.
            let rewritten = try await service.rewrite(
                selectedText: selectedText,
                instruction: instruction,
                systemPromptOverride: systemPromptOverride
            )

            guard pipeline.stillActive(token) else { return }
            // Persist BEFORE paste so a paste failure doesn't lose the
            // row — Home becomes the recovery affordance for the rare
            // paste-failure case (plan §6). For a picker-augment run, label
            // the row with the picked title + the spoken detail (e.g.
            // "Translate — to Japanese") so Home reads meaningfully; the
            // plain hotkey path keeps persisting the raw spoken instruction.
            let instructionLabel: String = {
                guard let pickedTitle, !pickedTitle.isEmpty else { return instruction }
                return "\(pickedTitle) — \(instruction)"
            }()
            persistSession(
                flavor: "voice",
                selection: selectedText,
                instruction: instructionLabel,
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

    // MARK: - Typed panel (Phase 2)

    /// Present the typed-instruction panel for the plain path when enabled, and
    /// wire its callbacks back into this run. A `false` (couldn't-become-key)
    /// return dismisses the panel so we degrade cleanly to voice+timeout.
    private func presentTypedPanelIfEnabled(systemPromptOverride: String?) {
        guard systemPromptOverride == nil,
              RewriteTypedPanelSettings.isEnabled,
              let instructionPanel
        else { return }

        let becameKey = instructionPanel.present(
            chips: Self.defaultChips(),
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
        // NIT 4: the mic is being paused — don't keep advertising "listening".
        if augmentHint != nil { augmentHint = "Typing…" }
        if let token = pipelineToken {
            Task { @MainActor [weak self] in
                await self?.pipeline.cancel(token: token)
            }
        }
        // SHOULD-FIX 2: replace the (now-cancelled) 10 s mic timer with a longer
        // idle bound. Reuses the `secondToggleTimeoutTask` slot, so
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
            // Typed then cleared → explicit default clean-up (mic is paused).
            typedResolution = .defaultCleanup
        } else {
            // Empty ⏎ with the mic still hot: fall through to the voice path so
            // anything spoken becomes the instruction; silence → clean-up.
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

    /// LLM rewrite + persist + paste for a resolved instruction on the plain
    /// path, guarded by Task cancellation (the pipeline token has already been
    /// torn down for these branches, so `stillActive` isn't the guard here —
    /// `cancel()` cancels `activeFlowTask`, which trips `Task.checkCancellation`).
    /// `instruction == nil` runs the default clean-up (fixed system prompt).
    private func runResolvedRewriteTail(
        selectedText: String,
        instruction: String?,
        createdAt: Date
    ) async throws {
        state = .rewriting
        let service = rewriteService()
        let modelLabel = snapshotModelLabel()
        let rewritten = try await service.rewrite(
            selectedText: selectedText,
            instruction: instruction,
            systemPromptOverride: nil
        )
        try Task.checkCancellation()

        let isCleanup = (instruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        persistSession(
            flavor: isCleanup ? "fixed" : "voice",
            selection: selectedText,
            instruction: isCleanup ? Self.fixedInstruction : instruction!,
            output: rewritten,
            modelUsed: modelLabel,
            createdAt: createdAt
        )
        try Task.checkCancellation()
        guard pasteReplacement(rewritten) else { return }
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
