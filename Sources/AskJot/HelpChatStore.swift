import Foundation
import Observation

#if canImport(FoundationModels)
// `FoundationModels` is imported only for the
// `LanguageModelSession.GenerationError` switch in
// `handleGenerationError(...)`. Session creation, prewarm, and
// streaming are routed through `AppleIntelligenceClient` and the
// dispatcher (Tier 2 unification) so the framework's surface stays
// localized to the LLM layer wherever possible.
import FoundationModels
#endif

/// Owner of the Ask Jot conversation state. Lives at `RootView` level
/// (spec §4, gotcha #6) so the conversation survives every sidebar
/// navigation — users can click Home → Library → Help and come back to
/// Ask Jot with their messages intact.
///
/// Scope:
///   * Creates and owns the `LanguageModelSession`.
///   * Builds the instructions block (static framing + user config +
///     grounding `help-content.md`).
///   * Runs `streamResponse(...)` and appends streaming partials to the
///     last assistant message.
///   * Runs the post-processing slug extraction + `ShowFeatureTool`
///     invocation (spec §7) after each turn completes.
///   * Handles clear, cancel, and context-full auto-recovery (§12).
///
/// Not in scope (teammate 2B):
///   * Voice input — the mic button in `AskJotView` is a no-op today.
///   * Real `help-content.md` grounding prose — today we use the stub
///     string below. When 2B lands `Resources/help-content.md` in the
///     bundle, the `Bundle.main.url(...)` load path picks it up with
///     no code change.
///
/// This type is `@Observable @MainActor` so SwiftUI tracks property
/// reads automatically and all state mutations happen on the main
/// actor. The session itself is main-actor-safe in 26.4.
@MainActor
@Observable
final class HelpChatStore {
    private static let allowCloudPreferenceKey = "jot.askjot.allowCloud"

    /// Conversation so far. `AskJotView` renders these as bubbles.
    var messages: [ChatMessage] = []

    /// Top-level mode — drives input enabled/disabled, streaming
    /// indicators, and the unavailable-reason empty state.
    var state: ChatState = .idle

    /// Pending prefill text — set by the sparkle icons and About row
    /// (via `HelpNavigator.pendingPrefill`). `AskJotView` observes
    /// this, populates its TextField, and clears it on consumption.
    var pendingPrefill: String?

    /// Cached user config snapshot. Rebuilt on every session create —
    /// never re-injected mid-session per spec §6.
    private(set) var userConfig: UserConfigSnapshot?

    /// The currently in-flight stream task. `cancel()` / `clear()` /
    /// availability change all cancel this and nil it out.
    private var lastStreamTask: Task<Void, Never>?

    /// FoundationModels session handle. Recreated on `clear()` and on
    /// context-full auto-recovery. Nil on macOS < 26 or when Apple
    /// Intelligence is unavailable — the store still functions as a
    /// state holder in that case. The handle is opaque
    /// (`AIChatSession` carries an `AnyObject` storage for the live
    /// `LanguageModelSession`); the on-device stream lifecycle stays
    /// consumer-owned per spec §12 (`clear()` mints fresh, context-full
    /// recovery mints fresh).
    private var chatSession: AIChatSession?

    /// Navigator for `ShowFeatureTool` invocations from the
    /// post-processing pass. Injected on init.
    private let navigator: HelpNavigator

    /// Network seam (Phase 0.5) — used to construct the cloud chat
    /// streams when the user's chosen provider isn't Apple
    /// Intelligence. Threaded through from
    /// `AppServices.urlSession` via `JotAppWindow`.
    private let urlSession: URLSession

    /// Phase 3 #29: per-graph `LLMConfiguration` replaces
    /// `LLMConfiguration.shared` reads. Threaded through from
    /// `AppServices.llmConfiguration` via `JotAppWindow`.
    private let llmConfiguration: LLMConfiguration

    /// Apple Intelligence seam — passed to `AIServices.current(...)`
    /// so the dispatcher can resolve the on-device path. Threaded
    /// through from `AppServices.appleIntelligence` via `JotAppWindow`.
    private let appleIntelligence: any AppleIntelligenceClienting

    /// Log sink — passed to `AIServices.current(...)` so the cloud
    /// `LLMClient` (used for the rare provider-mismatch fall-through
    /// inside the dispatcher) can log uniformly. Threaded through from
    /// `AppServices.logSink`.
    private let logSink: any LogSink

    /// Config-snapshot factory the store calls when building a new
    /// session. Injected so tests can override without touching
    /// UserDefaults / KeyboardShortcuts / VocabularyStore. Default
    /// implementation pulls live values; callers in app code use the
    /// default.
    private let snapshotBuilder: @MainActor () -> UserConfigSnapshot

    init(
        navigator: HelpNavigator,
        urlSession: URLSession,
        llmConfiguration: LLMConfiguration,
        appleIntelligence: any AppleIntelligenceClienting,
        logSink: any LogSink = ErrorLog.shared,
        snapshotBuilder: (@MainActor () -> UserConfigSnapshot)? = nil
    ) {
        self.navigator = navigator
        self.urlSession = urlSession
        self.llmConfiguration = llmConfiguration
        self.appleIntelligence = appleIntelligence
        self.logSink = logSink
        self.snapshotBuilder = snapshotBuilder ?? HelpChatStore.liveSnapshot
        self.state = Self.initialAvailabilityState(llmConfiguration: llmConfiguration)
    }

    // MARK: - Availability

    /// Compute an initial `ChatState` based on current Apple
    /// Intelligence availability. Called from `init` and re-evaluated
    /// by `refreshAvailability()` when something (e.g. a System
    /// Settings toggle) changes it at runtime.
    private static func initialAvailabilityState(llmConfiguration: LLMConfiguration) -> ChatState {
        if isCloudAskJotEnabled(llmConfiguration: llmConfiguration) {
            return .idle
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let reason = UnavailableReason.from(SystemLanguageModel.default.availability) {
                return .unavailable(reason)
            }
            return .idle
        } else {
            return .unavailable(.osTooOld)
        }
        #else
        return .unavailable(.osTooOld)
        #endif
    }

    /// Re-read `SystemLanguageModel.default.availability` and reconcile
    /// our state. Call from `AskJotView.onAppear` so a user who turned
    /// Apple Intelligence on/off in System Settings doesn't see stale
    /// state when they return to the pane.
    ///
    /// Mid-session availability changes cancel any in-flight stream
    /// and flip state to `.unavailable(...)`. Prior messages stay
    /// readable. When availability returns, state flips back to
    /// `.idle` but the existing conversation is preserved.
    func refreshAvailability() {
        if isCloudAskJotEnabled() {
            if case .unavailable = state {
                state = .idle
            }
            return
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let reason = UnavailableReason.from(SystemLanguageModel.default.availability)
            switch (reason, state) {
            case (nil, .unavailable):
                state = .idle
            case (let r?, _):
                lastStreamTask?.cancel()
                lastStreamTask = nil
                // If an assistant message was streaming, mark it stopped
                // so the user sees the partial with a visible boundary.
                if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                    messages[idx].isStreaming = false
                }
                state = .unavailable(r)
            default:
                break
            }
        } else {
            state = .unavailable(.osTooOld)
        }
        #else
        state = .unavailable(.osTooOld)
        #endif
    }

    /// True when sidebar label should render muted and the About row
    /// should be hidden. Kept as a computed property so callers don't
    /// have to pattern-match on `ChatState`.
    var isUnavailable: Bool {
        if case .unavailable = state { return true }
        return false
    }

    private static func isCloudAskJotEnabled(llmConfiguration: LLMConfiguration) -> Bool {
        let provider = llmConfiguration.provider
        return provider != .appleIntelligence &&
            UserDefaults.standard.bool(forKey: allowCloudPreferenceKey)
    }

    private func isCloudAskJotEnabled() -> Bool {
        Self.isCloudAskJotEnabled(llmConfiguration: llmConfiguration)
    }

    // MARK: - Prewarm

    /// Call from `AskJotView.onAppear` when the pane first becomes
    /// visible AND availability is `.available`. Spec §6 + gotcha #4:
    /// prewarm has latency cost, so we don't call it at app launch —
    /// users may never open Ask Jot.
    func prewarmIfNeeded() {
        guard !isCloudAskJotEnabled() else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .idle = state else { return }
            ensureChatSession()
            AppleIntelligenceClient.prewarmChatSession(chatSession)
        }
        #endif
    }

    /// Mint a fresh `AIChatSession` if we don't have one. Caches the
    /// snapshot used to build the instructions block so subsequent
    /// turns reuse the same instructions until `clear()` (spec §6:
    /// "never re-injected mid-session").
    private func ensureChatSession() {
        guard chatSession == nil else { return }
        let snapshot = snapshotBuilder()
        userConfig = snapshot
        let instructions = buildInstructions(userConfig: snapshot)
        chatSession = AppleIntelligenceClient.makeChatSession(
            instructions: instructions,
            navigator: navigator
        )
    }

    // MARK: - Send

    /// Submit a user message. Appends a user bubble + a streaming
    /// assistant bubble, kicks off the dispatcher's stream, and
    /// updates the assistant bubble's content as tokens arrive.
    ///
    /// No-op if `state != .idle` — the input bar gates Send on
    /// `state == .idle` but we re-check here as a double-safety
    /// against rapid double-clicks and Enter-key races.
    ///
    /// The dispatcher (`AIServices.current(...)`) owns provider routing.
    /// On Apple Intelligence the request includes the reusable
    /// `AIChatSession` so KV-cache stays warm across turns; on cloud
    /// the request includes the per-turn `showFeatureTool` callback so
    /// inline tool-calling works for OpenAI / Anthropic / Gemini /
    /// Ollama / Flavor-1 alike.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isCloudAskJotEnabled(), case .unavailable = state {
            state = .idle
        }
        guard case .idle = state else { return }

        // Effective provider for THIS turn — not necessarily the same
        // as `llmConfiguration.provider`. Ask Jot has its own provider
        // policy (CLAUDE.md "Ask Jot has its own provider policy"):
        // when the user's configured provider is non-Apple AND the
        // "Allow Ask Jot to use this provider" toggle is OFF, Ask Jot
        // stays on Apple Intelligence regardless of `provider`. This
        // gate is what `isCloudAskJotEnabled()` encodes.
        //
        // Pinning the value once here (and threading it as
        // `effectiveProvider`) also addresses the Settings-mid-Send
        // race: a user who flips Settings → AI between Send and the
        // stream's first byte should see the request still routed to
        // the provider that was active at Send time, not the one in
        // place when the stream's spawned task wakes up.
        let effectiveProvider: LLMProvider =
            isCloudAskJotEnabled() ? llmConfiguration.provider : .appleIntelligence

        // OS-level Apple Intelligence gate. Reached when
        // `effectiveProvider == .appleIntelligence` (fresh install on
        // macOS 26+, or the cloud opt-in is off) AND
        // `SystemLanguageModel.default.availability` is non-`.available`
        // — `initialAvailabilityState` already produced an `.unavailable`
        // pill in that case, so we mostly stop at the `guard idle` above.
        // The os-too-old branch survives here for callers on macOS < 26.
        if effectiveProvider == .appleIntelligence {
            #if !canImport(FoundationModels)
            state = .error("Ask Jot requires macOS 26.4 or later.")
            return
            #else
            if #unavailable(macOS 26.0) {
                state = .error("Ask Jot requires macOS 26.4 or later.")
                return
            }
            #endif
        }

        messages.append(ChatMessage(role: .user, content: trimmed))

        // Build the per-turn snapshot. For cloud the snapshot is fresh
        // every turn (matches pre-unification behavior); for Apple,
        // `ensureChatSession()` only mints a new session when we don't
        // have one, which preserves spec §6 ("never re-injected
        // mid-session") — the snapshot from session creation stays the
        // load-bearing one.
        if effectiveProvider == .appleIntelligence {
            ensureChatSession()
            // Apple Intelligence path requires a live session; if
            // session creation returned nil (FoundationModels missing
            // or unavailable), surface the error.
            guard chatSession != nil else {
                state = .error("Ask Jot couldn't start a session. Try again.")
                // Drop the user bubble so the input bar's resend works.
                if let last = messages.last, last.role == .user, last.content == trimmed {
                    messages.removeLast()
                }
                return
            }
        } else {
            // Cloud path — refresh the snapshot every turn (no session
            // reuse), matching the pre-unification cloud behavior.
            let snapshot = snapshotBuilder()
            userConfig = snapshot
        }

        let assistantId = beginStreamingAssistantMessage()

        // Snapshot per-provider config at Send time so a user toggling
        // Settings → AI mid-stream doesn't reroute the in-flight turn.
        // Cloud paths use this snapshot; Apple ignores apiKey/baseURL/
        // model.
        let perTurnAPIKey = llmConfiguration.apiKey(for: effectiveProvider)
        let perTurnBaseURL = llmConfiguration.effectiveBaseURL(for: effectiveProvider)
        let perTurnModel = llmConfiguration.effectiveModel(for: effectiveProvider)

        let request = AIChatRequest(
            messages: aiChatHistory(),
            systemInstructions: currentInstructions(),
            maxTokens: 300,
            showFeatureTool: { [weak self] featureId in
                await self?.runCloudShowFeatureTool(featureId: featureId) ?? "Feature not available"
            },
            session: chatSession,
            providerOverride: AIChatRequest.ProviderSnapshot(
                provider: effectiveProvider,
                apiKey: perTurnAPIKey,
                baseURL: perTurnBaseURL,
                model: perTurnModel
            )
        )

        let service = AIServices.serviceForRequest(
            request: request,
            urlSession: urlSession,
            appleClient: appleIntelligence,
            logSink: logSink,
            llmConfiguration: llmConfiguration
        )

        let stream = service.streamChat(request: request)

        lastStreamTask = Task { @MainActor [weak self] in
            await self?.runUnifiedStream(
                stream,
                prompt: trimmed,
                assistantId: assistantId,
                provider: effectiveProvider
            )
        }
    }

    private static let streamingFlushIntervalNs: UInt64 = 50_000_000

    /// Resolve the active system instructions block. For Apple, reuse
    /// the cached `userConfig` snapshot from session creation; for
    /// cloud, the just-rebuilt `userConfig` is already current.
    private func currentInstructions() -> String {
        let snapshot = userConfig ?? snapshotBuilder()
        return buildInstructions(userConfig: snapshot)
    }

    /// Convert `messages` into provider-neutral `AIChatMessage`s for
    /// the dispatcher. Drops the in-flight assistant placeholder
    /// (mirrors the pre-unification `cloudChatHistory()` filter).
    private func aiChatHistory() -> [AIChatMessage] {
        messages.compactMap { message in
            switch message.role {
            case .user:
                return AIChatMessage(role: .user, content: message.content)
            case .assistant:
                guard !message.isStreaming else { return nil }
                return AIChatMessage(role: .assistant, content: message.content)
            }
        }
    }

    private func beginStreamingAssistantMessage() -> UUID {
        let assistantId = UUID()
        messages.append(ChatMessage(id: assistantId, role: .assistant, content: "", isStreaming: true))
        state = .streaming
        return assistantId
    }

    private func streamingPostProcessedText(_ text: String) -> String {
        let corrected = correctBrokenSlugs(text: text)
        return injectMissingSlugs(text: corrected)
    }

    private func flushStreamingContent(assistantId: UUID, accumulated: String) {
        guard let idx = messages.firstIndex(where: { $0.id == assistantId }) else { return }
        messages[idx].content = streamingPostProcessedText(accumulated)
    }

    private func schedulePendingFlush(
        assistantId: UUID,
        accumulatedText: @escaping @MainActor () -> String,
        pendingFlush: inout Task<Void, Never>?
    ) {
        pendingFlush?.cancel()
        pendingFlush = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.streamingFlushIntervalNs)
            guard !Task.isCancelled else { return }
            flushStreamingContent(assistantId: assistantId, accumulated: accumulatedText())
        }
    }

    private func finalizeStream(prompt: String, assistantId: UUID, accumulated: String) async {
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[idx].isStreaming = false
            let withSlugs = streamingPostProcessedText(accumulated)
            let withForced = forceSharpFixCitationIfNeeded(text: withSlugs, userPrompt: prompt)
            let scrubbed = applyCommandScrub(text: withForced)
            messages[idx].content = scrubbed
        }

        if !Task.isCancelled {
            state = .idle
            let finalText = messages.first(where: { $0.id == assistantId })?.content ?? accumulated
            await runPostProcessingToolInvocation(text: finalText)
        }
    }

    private func handleCancelledStream(assistantId: UUID, accumulated: String) {
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[idx].isStreaming = false
            messages[idx].content = streamingPostProcessedText(accumulated)
            if !messages[idx].content.isEmpty {
                messages[idx].content += "\n\n_(stopped)_"
            }
        }
        state = .idle
    }

    private func handleCloudStreamError(
        provider: LLMProvider,
        assistantId: UUID,
        accumulated: String
    ) {
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[idx].isStreaming = false
            let body = streamingPostProcessedText(accumulated)
            let suffix = "(cloud error: \(provider.rawValue))"
            messages[idx].content = body.isEmpty ? suffix : body + "\n\n" + suffix
        }
        state = .idle
    }

    /// Drives the dispatcher's delta stream — same loop for cloud and
    /// Apple Intelligence. Branching on provider-specific concerns is
    /// kept narrow:
    ///
    ///   * **Repetition detection** runs on every turn (Apple's
    ///     small-model loops were the original motivator; it's a
    ///     no-op cost for cloud paths).
    ///   * **Apple-only `LanguageModelSession.GenerationError`
    ///     handling** is preserved — the dispatcher's Apple conformer
    ///     propagates the original error, this catch surfaces it on
    ///     the on-device path. On cloud, `GenerationError` never
    ///     fires; the catch is dead code there.
    ///   * **Cloud-only error pill** uses the provider name (matches
    ///     pre-unification "(cloud error: openai)" suffix).
    private func runUnifiedStream(
        _ stream: AsyncThrowingStream<String, Error>,
        prompt: String,
        assistantId: UUID,
        provider: LLMProvider
    ) async {
        var accumulated = ""
        var repetitionDetector = StreamRepetitionDetector()
        var stoppedForRepetition = false
        var pendingFlush: Task<Void, Never>?

        do {
            for try await delta in stream {
                if Task.isCancelled { break }
                // Stream-rewrite sentinel from the Apple conformer:
                // an empty yield followed by the next chunk means the
                // model rewrote its partial. Reset the accumulator so
                // the rewrite replaces the prior content.
                if delta.isEmpty {
                    accumulated = ""
                    continue
                }
                accumulated += delta

                repetitionDetector.observe(fullText: accumulated)
                if repetitionDetector.isLooping() {
                    pendingFlush?.cancel()
                    flushStreamingContent(assistantId: assistantId, accumulated: accumulated)
                    if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
                        lastStreamTask?.cancel()
                        messages[idx].isStreaming = false
                        messages[idx].content += "\n\n_(stopped: repetition detected)_"
                        state = .idle
                        stoppedForRepetition = true
                        break
                    }
                }

                schedulePendingFlush(
                    assistantId: assistantId,
                    accumulatedText: { accumulated },
                    pendingFlush: &pendingFlush
                )
            }

            if stoppedForRepetition {
                return
            }

            // `AsyncThrowingStream` cancellation is racy: when the
            // consumer task is cancelled, the iteration can complete
            // normally before the producer's `finish(throwing:
            // CancellationError())` propagates through the buffer. To
            // get deterministic "user pressed Esc → handleCancelledStream
            // path" behavior, explicitly check our own task's
            // cancellation flag after the loop and route to the
            // cancelled-stream handler.
            try Task.checkCancellation()

            pendingFlush?.cancel()
            await finalizeStream(prompt: prompt, assistantId: assistantId, accumulated: accumulated)
        } catch is CancellationError {
            pendingFlush?.cancel()
            handleCancelledStream(assistantId: assistantId, accumulated: accumulated)
        } catch {
            pendingFlush?.cancel()
            await handleStreamError(
                error,
                provider: provider,
                userPrompt: prompt,
                assistantId: assistantId,
                accumulated: accumulated
            )
        }
    }

    /// Resolve a stream-loop error into an assistant bubble update +
    /// `state` transition. Apple's `LanguageModelSession.GenerationError`
    /// cases drive AskJot-specific recovery; everything else collapses
    /// to a cloud-flavored or generic error.
    private func handleStreamError(
        _ error: Error,
        provider: LLMProvider,
        userPrompt: String,
        assistantId: UUID,
        accumulated: String
    ) async {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let generationError = error as? LanguageModelSession.GenerationError {
                await handleGenerationError(
                    generationError,
                    userPrompt: userPrompt,
                    assistantId: assistantId
                )
                return
            }
        }
        #endif

        if provider != .appleIntelligence {
            handleCloudStreamError(provider: provider, assistantId: assistantId, accumulated: accumulated)
            return
        }

        // Unknown Apple-path error — surface a generic message.
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[idx].isStreaming = false
            if messages[idx].content.count < 5 {
                messages[idx].content = "Something went wrong. Try again."
            }
        }
        state = .error(error.localizedDescription)
    }

    private func runCloudShowFeatureTool(featureId: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let tool = ShowFeatureTool(navigator: navigator)
            return (try? await tool.call(arguments: .init(featureId: featureId))) ?? "Feature not available"
        }
        #endif

        guard let feature = Feature.bySlug(featureId), feature.isDeepLinkable else {
            return "Feature not available"
        }
        _ = feature
        return "Shown"
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func handleGenerationError(
        _ error: LanguageModelSession.GenerationError,
        userPrompt: String,
        assistantId: UUID
    ) async {
        switch error {
        case .exceededContextWindowSize:
            // §12 auto-recovery: cancel, clear, prefill the last
            // question, surface a toast-style assistant message so
            // the user sees what happened.
            clear()
            pendingPrefill = userPrompt
            messages.append(
                ChatMessage(
                    role: .assistant,
                    content: "Chat was getting full — starting fresh. Your last question: \u{201C}\(userPrompt)\u{201D}"
                )
            )
            state = .idle
        case .guardrailViolation:
            if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
                messages[idx].isStreaming = false
                messages[idx].content = "I can't help with that. Ask me about Jot's features."
            }
            state = .idle
        case .unsupportedLanguageOrLocale:
            if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
                messages[idx].isStreaming = false
                messages[idx].content = "I can only help in English right now."
            }
            state = .idle
        default:
            if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
                messages[idx].isStreaming = false
                if messages[idx].content.count < 5 {
                    messages[idx].content = "Something went wrong. Try again."
                }
            }
            state = .error(String(describing: error))
        }
    }
    #endif

    // MARK: - Cancel / clear

    /// Esc handler — cancel an in-flight stream, preserving the
    /// partial. No-op when idle.
    func cancelStream() {
        guard case .streaming = state else { return }
        lastStreamTask?.cancel()
        lastStreamTask = nil
    }

    /// Spec §12: clear resets messages, recreates the session so no
    /// stale context survives, and prewarms the fresh session.
    func clear() {
        lastStreamTask?.cancel()
        lastStreamTask = nil
        messages.removeAll()
        // Drop the FoundationModels session so the next turn mints a
        // fresh one with no carry-over context. For cloud paths the
        // session is always nil, so this is a no-op there.
        chatSession = nil
        userConfig = nil
        state = .idle

        guard !isCloudAskJotEnabled() else {
            refreshAvailability()
            return
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .unavailable = initialAvailabilityFresh() {
                // Skip session recreate when unavailable — let the
                // unavailable-reason UI handle it.
            } else {
                ensureChatSession()
                AppleIntelligenceClient.prewarmChatSession(chatSession)
            }
        }
        #endif

        // Reconcile state once more in case availability changed
        // between the stream start and the clear.
        refreshAvailability()
    }

    /// Pure helper so `clear()` doesn't mutate `state` twice when
    /// reading current availability.
    private func initialAvailabilityFresh() -> ChatState {
        Self.initialAvailabilityState(llmConfiguration: llmConfiguration)
    }

    /// Assemble the instructions string per spec §6. The grounding doc
    /// is loaded lazily from the bundle; falls back to `stubHelpContent`
    /// if the file is missing (pre-2B landing, tests, etc).
    private func buildInstructions(userConfig: UserConfigSnapshot) -> String {
        return """
        You are Jot's in-app help assistant. Jot is a Mac dictation app that transcribes speech to text system-wide, entirely on-device, with optional LLM cleanup and a voice-driven text rewrite feature called Articulate.

        STYLE: write like a tight editorial service column, not a support article.
        ALWAYS cite a feature's slug in square brackets on first mention, like [toggle-recording]. DO NOT skip the brackets.
        ALWAYS ground every answer in the DOCUMENTATION below. DO NOT invent facts.
        ALWAYS write in prose. Default to ONE compact paragraph for simple questions and at most TWO compact paragraphs when a second paragraph adds a caveat or next move.
        ALWAYS keep simple answers to 2–4 sentences and usually under 90 words; longer answers should stay under 140 words unless the user explicitly asks for detail.
        ALWAYS keep the tone compressed, sentence-led, and confident. Use semicolons and run-in phrasing when a sequence matters.
        DO NOT use markdown headers, checklists, FAQ labels, or stacked mini-sections.
        Lists are allowed when they genuinely clarify the answer; keep them short, sentence-led, and usually no more than 2–4 items.
        You MAY use one short bold run-in label when it genuinely sharpens the answer, for example: **Why it happens** the shortcut must use modifiers.
        Avoid filler openings like "Here's how", "In summary", or "You can do this by".
        ALWAYS use exact UI names: "Settings → AI", "Home", "Library". DO NOT invent menu items.
        NEVER include shell commands in answers. For recording-wont-start and hotkey-stopped-working, cite the slug only.
        NEVER answer non-Jot questions. If the user asks about non-Jot topics, respond with ONE sentence redirecting them. DO NOT attempt the task.

        USER'S CURRENT SETUP:
        \(userConfig.formatted)

        DOCUMENTATION:
        \(Self.helpContent)
        """
    }

    // MARK: - Post-processing: slug extraction + ShowFeatureTool

    /// Regex-extract `[slug]` patterns from the final assistant text,
    /// filter to deep-linkable slugs, and invoke `ShowFeatureTool` for
    /// up to 2 unique matches. Spec §7.
    ///
    /// Runs only when an assistant turn completes cleanly (not on
    /// cancel / error). The tool now validates cited slugs without
    /// mutating the navigator; Ask Jot itself owns navigation and only
    /// writes it on explicit slug-link clicks.
    private func runPostProcessingToolInvocation(text: String) async {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let slugs = extractDeepLinkableSlugs(from: text)
            guard !slugs.isEmpty else { return }

            let tool = ShowFeatureTool(navigator: navigator)
            for slug in slugs.prefix(2) {
                _ = try? await tool.call(arguments: .init(featureId: slug))
            }
        }
        #endif
    }

    /// Extract `[slug]` style markers, filter to unique deep-linkable
    /// feature slugs. Visible for testing.
    func extractDeepLinkableSlugs(from text: String) -> [String] {
        // Slugs are lowercase alphanumerics + dashes per Feature.swift.
        let pattern = "\\[([a-z0-9][a-z0-9-]*)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        var seen = Set<String>()
        var ordered: [String] = []
        for match in matches {
            guard let slugRange = Range(match.range(at: 1), in: text) else { continue }
            let slug = String(text[slugRange])
            if seen.contains(slug) { continue }
            guard let feature = Feature.bySlug(slug), feature.isDeepLinkable else { continue }
            seen.insert(slug)
            ordered.append(slug)
        }
        return ordered
    }

    // MARK: - Slug post-processing

    /// Extra term → slug candidates injected alongside `Feature.all` titles.
    /// These are natural-language phrasings the model emits instead of the
    /// exact feature title. Curated from v1.5 slug-post-processing research
    /// (see docs/research/slug-post-processing-notes.md).
    ///
    /// Critical entries: "recording won't start" / "hotkey stopped working"
    /// variants drive sharp-fix slug citation which gates the shell-command
    /// scrub downstream.
    static let slugAliasMap: [(term: String, slug: String)] = [
        // AI provider phrasings
        ("on-device LLM", "ai-apple-intelligence"),
        ("on-device AI", "ai-apple-intelligence"),
        ("Apple Intelligence", "ai-apple-intelligence"),
        // Permissions
        ("microphone permission", "permissions"),
        ("input monitoring", "permissions"),
        ("accessibility permission", "permissions"),
        // Custom vocabulary
        ("vocabulary list", "custom-vocabulary"),
        ("vocabulary entries", "custom-vocabulary"),
        // Articulate
        ("rewrite selection", "articulate-custom"),
        // Push-to-talk spacing variants (title is "Push to talk" without hyphens)
        ("push-to-talk", "push-to-talk"),
        // Sharp-fix natural phrasings — load-bearing for the shell scrub.
        // The model frequently describes the symptom without using the
        // card's exact title, leaving the scrub with no slug to trigger on.
        ("recording won't start", "recording-wont-start"),
        ("recording doesn't start", "recording-wont-start"),
        ("doesn't start recording", "recording-wont-start"),
        ("won't record", "recording-wont-start"),
        ("hotkey stopped working", "hotkey-stopped-working"),
        ("hotkey produces a weird character", "hotkey-stopped-working"),
        ("weird character", "hotkey-stopped-working"),
        ("unicode character", "hotkey-stopped-working"),
    ]

    /// Map from plausible-but-wrong bracketed slugs the model sometimes
    /// emits to the canonical deep-linkable slug. Covers deleted slugs
    /// (`articulate-shared-prompt`, `auto-transcribe`, `re-transcribe`) so
    /// the user still gets deep-linked to something sensible, and trims
    /// common abbreviations / lowercase variants.
    static let slugCorrectionMap: [String: String] = [
        "toggle": "toggle-recording",
        "recording": "toggle-recording",
        "cleanup-auto": "cleanup",
        "articulate-shared-prompt": "articulate",
        "auto-transcribe": "dictation",
        "re-transcribe": "dictation",
        "custom-vocab": "custom-vocabulary",
        "vocabulary": "custom-vocabulary",
        "apple-intelligence": "ai-apple-intelligence",
        "ollama": "ai-ollama",
        "permissions-card": "permissions",
        "mic-permissions": "permissions",
        "mic": "permissions",
        "articulate-custom-prompt": "articulate-custom",
    ]

    /// Rewrite `[broken-slug]` occurrences whose token isn't a deep-linkable
    /// feature to their canonical slug via `slugCorrectionMap`. Runs before
    /// injection so downstream extraction can resolve them.
    ///
    /// Visible for testing.
    func correctBrokenSlugs(text: String) -> String {
        let pattern = "\\[([a-z0-9][a-z0-9-]*)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // Walk back-to-front so replacements don't invalidate earlier ranges.
        var result = ns
        for m in matches.reversed() {
            let slug = ns.substring(with: m.range(at: 1))
            if let feature = Feature.bySlug(slug), feature.isDeepLinkable { continue }
            if let corrected = Self.slugCorrectionMap[slug],
               let target = Feature.bySlug(corrected), target.isDeepLinkable {
                result = result.replacingCharacters(in: m.range, with: "[\(corrected)]") as NSString
            }
        }
        return result as String
    }

    /// Scan the assistant's final text for feature names (titles, slugs,
    /// and curated aliases) and append `[slug]` brackets after the first
    /// un-bracketed occurrence of each match. Capped at 3 injections per
    /// turn so prose stays readable.
    ///
    /// Load-bearing: v2 research showed compressed grounding docs drop
    /// model-emitted slug-citation to ~6%. v1.5 slug-pp research raised it
    /// further by adding alias-aware injection (prose phrasings like "on-
    /// device AI" map to `ai-apple-intelligence`). Measured +33pp on the
    /// research battery (28% → 61%).
    ///
    /// Visible for testing.
    func injectMissingSlugs(text: String) -> String {
        var result = text
        var injected = 0
        let cap = 3

        // (term, slug, kind) candidates. Longest terms first so
        // "Custom vocabulary" matches before "vocabulary". `kind` drives
        // the replacement format below: canonical matches (the feature's
        // own title or slug) are REPLACED with `[slug]`, because the
        // renderer expands `[slug]` back to the canonical title — keeping
        // the original word in place would produce "Cleanup Cleanup" in
        // the final render. Alias matches (natural-language phrasings like
        // "on-device AI") preserve the matched text and append `[slug]`
        // so the user still sees the alias, followed by a link to the
        // canonical feature.
        enum CandidateKind { case canonical, alias }
        var candidates: [(term: String, slug: String, kind: CandidateKind)] = []
        for f in Feature.all where f.isDeepLinkable {
            candidates.append((f.title, f.slug, .canonical))
            // The slug text itself — the doc uses bare `toggle-recording:`
            // labels which the model sometimes echoes verbatim.
            if f.title.lowercased() != f.slug.lowercased() {
                candidates.append((f.slug, f.slug, .canonical))
            }
        }
        // Curated aliases — natural-language phrasings the model emits
        // instead of the exact feature title.
        for a in Self.slugAliasMap {
            candidates.append((a.term, a.slug, .alias))
        }
        candidates.sort { $0.term.count > $1.term.count }

        for (term, slug, kind) in candidates {
            if injected >= cap { break }
            // Already bracketed somewhere? Skip.
            if result.contains("[\(slug)]") { continue }
            let escaped = NSRegularExpression.escapedPattern(for: term)
            // Word-boundary match, case-insensitive, not already followed
            // by `[` (so we don't double-inject).
            let pattern = "(?i)(?<![A-Za-z0-9-])(\(escaped))(?![A-Za-z0-9-])(?!\\s*\\[)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            if let match = regex.firstMatch(in: result, range: range),
               let r = Range(match.range(at: 1), in: result) {
                let matched = String(result[r])
                switch kind {
                case .canonical:
                    result.replaceSubrange(r, with: "[\(slug)]")
                case .alias:
                    result.replaceSubrange(r, with: "\(matched) [\(slug)]")
                }
                injected += 1
            }
        }
        return result
    }

    /// When the user's question matches a sharp-fix pattern
    /// (`recording-wont-start` / `hotkey-stopped-working`), ensure the
    /// corresponding slug is cited in the answer. If the model and the
    /// injection pass both missed it, prepend a short pointer sentence so
    /// the downstream `applyCommandScrub` has a hook to fire on.
    ///
    /// Critical safety lever: without the slug present, the scrub doesn't
    /// run, and hallucinated `sudo` / numbered-step commands in the
    /// model's output reach the user. Research q4r1 measured a baseline
    /// `sudo dpkg-reconfigure` leak that this path catches.
    ///
    /// Visible for testing.
    func forceSharpFixCitationIfNeeded(text: String, userPrompt: String) -> String {
        guard let forced = Self.sharpFixSlugForQuestion(userPrompt) else { return text }
        if text.contains("[\(forced)]") { return text }
        let headline: String
        switch forced {
        case "recording-wont-start":
            headline = "See Recording won't start [\(forced)]."
        case "hotkey-stopped-working":
            headline = "See Hotkey stopped working [\(forced)]."
        default:
            headline = "[\(forced)]"
        }
        return headline + "\n\n" + text
    }

    /// Question-shape classifier for sharp-fix force-injection. Keyword
    /// heuristic — the production battery is small enough that a curated
    /// pattern set beats a fuzzy matcher here. Kept static so the
    /// post-processors can call it without instance state.
    static func sharpFixSlugForQuestion(_ question: String) -> String? {
        let q = question.lowercased()
        if q.contains("weird character") || q.contains("unicode char") ||
           q.contains("hotkey stopped") || q.contains("hotkey produces") ||
           q.contains("≤") || q.contains("÷") {
            return "hotkey-stopped-working"
        }
        if (q.contains("recording") && (q.contains("won't") || q.contains("doesn't") ||
            q.contains("not start") || q.contains("not working") ||
            q.contains("nothing happens"))) ||
           q.contains("hotkey does nothing") || q.contains("recording wont") {
            return "recording-wont-start"
        }
        return nil
    }

    // MARK: - Sharp-fix command scrub

    /// Spec §7: for slugs flagged `commandOnCard == true`, strip
    /// command-like content from the assistant's answer before it
    /// reaches the user. The card is the single source of truth for
    /// the actual command — letting the model's answer render raw
    /// risks the user copying a miswritten `sudo` line.
    ///
    /// Detection is heuristic (pattern-based). When any pattern hits,
    /// we replace the matched span with a short pointer to the card.
    /// Visible for testing.
    func applyCommandScrub(text: String) -> String {
        guard citesSharpFixSlug(text: text) else { return text }

        let commandPatterns: [String] = [
            // `sudo <anything up to end-of-line>`
            "sudo[^\\n]+",
            // `killall <process>`
            "killall[^\\n]+",
            // Numbered step sequences: "1. foo ... 2. bar ..."
            "(?m)^\\s*[0-9]+\\.\\s[^\\n]+(\\n\\s*[0-9]+\\.\\s[^\\n]+)+",
            // Triple-backtick code blocks of any content.
            "(?s)```[^`]*```"
        ]

        var scrubbed = text
        var didScrub = false
        for pattern in commandPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(scrubbed.startIndex..., in: scrubbed)
                if regex.firstMatch(in: scrubbed, range: range) != nil {
                    didScrub = true
                    scrubbed = regex.stringByReplacingMatches(
                        in: scrubbed,
                        range: NSRange(scrubbed.startIndex..., in: scrubbed),
                        withTemplate: "See the card for the exact command."
                    )
                }
            }
        }
        return didScrub ? scrubbed : text
    }

    private func citesSharpFixSlug(text: String) -> Bool {
        text.contains("[recording-wont-start]") || text.contains("[hotkey-stopped-working]")
    }

    // MARK: - Grounding content

    /// Bundled grounding doc, loaded lazily. Teammate 2B will land
    /// `Resources/help-content.md` with the real prose; until then
    /// the stub below is enough to instantiate a session and let the
    /// bot answer high-level questions.
    ///
    /// Static / lazy so the first `HelpChatStore` init pays the
    /// filesystem read cost once, and every subsequent session reuses
    /// it in-memory.
    static let helpContent: String = {
        if let url = Bundle.main.url(forResource: "help-content", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return stubHelpContent
    }()

    /// Minimal placeholder covering the 3 heroes so the session has
    /// enough context to produce answers during development. Drop this
    /// the moment real grounding lands — the Bundle URL lookup above
    /// will supersede it automatically.
    static let stubHelpContent: String = """
    # Jot

    On-device Mac dictation. Hotkey → speak → transcript pastes at cursor.
    Entirely local by default; cloud providers optional for Cleanup and
    Articulate.

    ## Dictation

    Toggle [toggle-recording]: press hotkey (default ⌥Space) to start, press
    again to stop and transcribe.

    Push-to-talk [push-to-talk]: hold hotkey to record, release to stop.
    Unbound by default.

    Cancel [cancel-recording]: Esc discards without transcribing.

    Any-length recordings [any-length]: no hard limit.

    Transcription [on-device-transcription] runs on-device via Parakeet.
    Audio never leaves the Mac.

    Multilingual [multilingual]: 25 European languages, auto-detected.

    Custom vocabulary [custom-vocabulary]: a short list of names Jot should
    prefer.

    ## Cleanup (optional)

    Off by default. An LLM removes fillers, fixes grammar, preserves voice.

    Providers [cleanup-providers]: Apple Intelligence (on-device, free).
    Cloud (OpenAI, Anthropic, Gemini) with your API key. Ollama local.

    Editable prompt [cleanup-prompt]: customize in Settings → AI.

    ## Articulate (optional)

    Rewrite selected text via a global shortcut.

    Articulate Custom [articulate-custom]: select → hotkey → speak an
    instruction → result replaces selection.

    Articulate Fixed [articulate-fixed]: select → hotkey → fixed
    "Articulate this" instruction, no voice step.

    Intent classifier [articulate-intent-classifier]: routes instructions
    into voice-preserving, structural, translation, or code branches.

    ## Shortcuts

    macOS requires global hotkeys to include a modifier. Single-key
    bindings are impossible [modifier-required]. If a hotkey produces a
    Unicode character, another app grabbed it while Jot was off — see
    [hotkey-stopped-working].

    ## Troubleshooting

    - Permissions [permissions]: Mic, Input Monitoring, Accessibility.
    - Recording won't start [recording-wont-start]: coreaudiod fix on card.
    - Hotkey stopped working [hotkey-stopped-working]: re-register steps on
      card.
    - AI unavailable [ai-unavailable] or connection failed
      [ai-connection-failed]: see Troubleshooting.
    - Articulate giving bad results [articulate-bad-results]: reset prompt
      to default first.

    ## Privacy

    Local-only by default. No telemetry. Cloud providers only receive text
    if you enable Cleanup or Articulate with a cloud provider configured.
    """

    // MARK: - Live snapshot factory

    /// Default snapshot builder used in app code. Pulls from the same
    /// UserDefaults / KeyboardShortcuts / VocabularyStore sources the
    /// rest of the app reads. Kept as a static so tests can inject a
    /// deterministic alternative via `init(snapshotBuilder:)`.
    private static func liveSnapshot() -> UserConfigSnapshot {
        let cleanupEnabled = UserDefaults.standard.bool(forKey: "jot.transformEnabled")
        let retention = (UserDefaults.standard.object(forKey: "jot.retentionDays") as? Int) ?? 7
        let providerRaw = UserDefaults.standard.string(forKey: "jot.llm.provider")
        let providerDisplay: String? = {
            guard let raw = providerRaw, let provider = LLMProvider(rawValue: raw) else {
                return nil
            }
            return provider.displayName
        }()
        let vocabularyCount = VocabularyStore.shared.terms.count

        return UserConfigSnapshot.current(
            // Model-downloaded is a per-launch cache that lives on
            // AppDelegate; we don't have a sync accessor at this layer
            // without plumbing more state. Defaulting to true matches
            // the steady-state experience — the model is downloaded on
            // first launch and stays resident. False would only show
            // for a brand-new install during the setup wizard, when
            // Ask Jot isn't reachable yet anyway.
            modelDownloaded: true,
            vocabularyEntryCount: vocabularyCount,
            aiProviderDisplay: providerDisplay,
            cleanupEnabled: cleanupEnabled,
            launchAtLogin: false, // See above — SMAppService check requires a non-async call; leaving false keeps the snapshot deterministic.
            retentionDays: retention
        )
    }
}
