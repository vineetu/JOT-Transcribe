import Foundation

/// Provider-neutral abstraction over Jot's two LLM call stacks: the
/// on-device `AppleIntelligenceClient` (FoundationModels) and the
/// HTTP-backed `LLMClient` (OpenAI / Anthropic / Gemini / Ollama, plus
/// the optional Flavor-1 endpoint).
///
/// Three operations cover every shipping call site:
///
///   * `transform(...)` — Cleanup tail. Used by `RecorderController` to
///     post-process raw dictation transcripts.
///   * `articulate(...)` — Selection rewrite. Used by
///     `ArticulateController` for both Custom (voice instruction) and
///     Fixed (`"Articulate this"`) flows.
///   * `streamChat(...)` — Ask Jot conversational streaming. Used by
///     `HelpChatStore.send`. Returns an `AsyncThrowingStream<String, Error>`
///     of token deltas; provider-specific errors (e.g.
///     `LanguageModelSession.GenerationError`) propagate verbatim
///     through the stream's error channel so consumers can switch on
///     the original type without relying on a translated enum.
///
/// All operations are async and may run off the main actor; conformers
/// are `Sendable`. Cancellation propagates through `Task.cancel()` —
/// dropping the consumer task aborts the underlying request (HTTP
/// streaming is task-cancellation-aware via `AsyncThrowingStream`'s
/// `onTermination`; the FoundationModels session work is bounded by
/// the caller's task lifetime).
protocol AIService: Sendable {
    /// Clean up a raw dictation transcript. Mirrors
    /// `LLMClient.transform(transcript:)` — provider selection and
    /// prompt composition happen *inside* the conformer.
    func transform(transcript: String) async throws -> String

    /// Articulate a selection according to the user's instruction.
    /// Mirrors `LLMClient.articulate(selectedText:instruction:)` —
    /// shared invariants + classifier branch composition happen inside
    /// the conformer.
    func articulate(selectedText: String, instruction: String) async throws -> String

    /// Stream an Ask Jot turn. Returns a delta-token stream; consumers
    /// accumulate into the assistant bubble. Provider-specific errors
    /// are propagated verbatim through the stream.
    ///
    /// On Apple Intelligence the conformer honors `request.session` —
    /// `nil` mints a fresh `LanguageModelSession`; non-`nil` reuses the
    /// existing one (preserves AskJot's per-turn KV-cache reuse and
    /// `clear()` reset semantics). On cloud the field is ignored
    /// (every cloud turn is stateless from the model's perspective);
    /// `request.showFeatureTool` is wired into the per-provider
    /// `CloudChatStream` for inline tool-calling.
    func streamChat(request: AIChatRequest) -> AsyncThrowingStream<String, Error>
}

/// Per-turn input to `AIService.streamChat`. The dispatcher already
/// resolved the provider; the optional `providerOverride` snapshot
/// pins per-provider config to the values that were active at Send
/// time, so a user flipping Settings → AI mid-stream doesn't reroute
/// the in-flight turn.
struct AIChatRequest: Sendable {
    /// Conversation so far. The conformer composes this into the
    /// provider-native message format.
    let messages: [AIChatMessage]

    /// System prompt. For Apple becomes the
    /// `LanguageModelSession.instructions` block; for cloud becomes
    /// the per-provider `system` field on the request payload.
    let systemInstructions: String

    /// Soft cap on assistant output tokens.
    let maxTokens: Int

    /// Cloud tool-calling callback for `showFeature`. Cloud conformers
    /// thread this into `CloudChatStream.streamChat`. The Apple
    /// conformer ignores this hook — `HelpChatStore`'s post-processing
    /// pass handles slug extraction for the on-device path.
    let showFeatureTool: @Sendable (String) async -> String

    /// Reusable on-device session handle. `HelpChatStore` mints once
    /// and feeds the same instance back across turns to keep the
    /// FoundationModels KV-cache warm; `clear()` drops the handle and
    /// the next request gets `nil`, which the Apple conformer resolves
    /// to a fresh session. Cloud conformers ignore the field.
    let session: AIChatSession?

    /// Per-turn provider snapshot. Captured at Send time so the
    /// in-flight stream is immune to mid-stream Settings changes.
    /// `nil` means "read live config off `LLMConfiguration`" — the
    /// transform / articulate paths (which run as one-shot async
    /// calls, not streams) tolerate the simpler live read because
    /// they capture config inside `LLMClient.transform/articulate`'s
    /// `MainActor.run` block before any await crosses the
    /// Settings-toggle window.
    let providerOverride: ProviderSnapshot?

    /// Pinned per-provider configuration for one streaming turn.
    /// Cloud conformers prefer this over the live `LLMConfiguration`
    /// reads when present.
    struct ProviderSnapshot: Sendable {
        let provider: LLMProvider
        let apiKey: String
        let baseURL: String
        let model: String
    }

    init(
        messages: [AIChatMessage],
        systemInstructions: String,
        maxTokens: Int,
        showFeatureTool: @escaping @Sendable (String) async -> String,
        session: AIChatSession?,
        providerOverride: ProviderSnapshot? = nil
    ) {
        self.messages = messages
        self.systemInstructions = systemInstructions
        self.maxTokens = maxTokens
        self.showFeatureTool = showFeatureTool
        self.session = session
        self.providerOverride = providerOverride
    }
}

/// Opaque carrier for an Apple `LanguageModelSession`. Cloud conformers
/// disregard the value. `Sendable` so the request can cross actor
/// boundaries; the underlying `LanguageModelSession` is `@MainActor` in
/// Apple's API and is read back on the main actor by the conformer.
final class AIChatSession: @unchecked Sendable {
    /// Backing storage. The Apple conformer downcasts to
    /// `LanguageModelSession`. Held strongly because once
    /// `HelpChatStore` drops the handle nothing else owns the session;
    /// a strong ref is required to keep the KV-cache alive between
    /// turns.
    let storage: AnyObject

    init(storage: AnyObject) {
        self.storage = storage
    }
}

struct AIChatMessage: Sendable, Equatable {
    enum Role: Sendable, Equatable {
        case user
        case assistant
    }

    let role: Role
    let content: String

    init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Dispatcher. Reads the configured provider off the injected
/// `LLMConfiguration` and returns the matching live conformer. The
/// dispatcher itself is stateless — every call resolves the provider
/// fresh, so a runtime provider switch (e.g. user changes Settings →
/// AI mid-app-session) takes effect on the next call site without
/// restarting the graph.
///
/// Per-graph configuration is required because Phase 3 retired
/// `LLMConfiguration.shared`; callers receive the configuration via
/// `JotComposition.build` and pass it through.
@MainActor
enum AIServices {
    /// Resolve the live `AIService` for the configured provider. Reads
    /// `configuration.provider` synchronously on the main actor (the
    /// `@MainActor` annotation on `LLMConfiguration`'s storage requires
    /// it). The returned conformer captures everything it needs —
    /// callers can hand the value to a `nonisolated` actor without
    /// re-entering main isolation per call.
    static func current(
        configuration: LLMConfiguration,
        urlSession: URLSession,
        appleClient: any AppleIntelligenceClienting,
        logSink: any LogSink
    ) -> any AIService {
        let provider = configuration.provider
        return service(
            for: provider,
            configuration: configuration,
            urlSession: urlSession,
            appleClient: appleClient,
            logSink: logSink
        )
    }

    /// Resolve the live `AIService` for an `AIChatRequest`. Honors the
    /// request's `providerOverride.provider` so a streaming turn pinned
    /// to a per-Send-time provider snapshot routes to the same conformer
    /// the snapshot describes (e.g. Ask Jot's "Allow Ask Jot to use this
    /// provider" toggle is OFF → effective provider is Apple
    /// Intelligence even if `LLMConfiguration.provider` is `.openai`).
    static func serviceForRequest(
        request: AIChatRequest,
        urlSession: URLSession,
        appleClient: any AppleIntelligenceClienting,
        logSink: any LogSink,
        llmConfiguration: LLMConfiguration
    ) -> any AIService {
        let resolved = request.providerOverride?.provider ?? llmConfiguration.provider
        return service(
            for: resolved,
            configuration: llmConfiguration,
            urlSession: urlSession,
            appleClient: appleClient,
            logSink: logSink
        )
    }

    private static func service(
        for provider: LLMProvider,
        configuration: LLMConfiguration,
        urlSession: URLSession,
        appleClient: any AppleIntelligenceClienting,
        logSink: any LogSink
    ) -> any AIService {
        switch provider {
        case .appleIntelligence:
            return AppleAIService(
                appleClient: appleClient,
                llmConfiguration: configuration,
                urlSession: urlSession,
                logSink: logSink
            )
        case .openai, .anthropic, .gemini, .ollama:
            return CloudAIService(
                urlSession: urlSession,
                appleClient: appleClient,
                llmConfiguration: configuration,
                logSink: logSink
            )
        #if JOT_FLAVOR_1
        case .flavor1:
            return CloudAIService(
                urlSession: urlSession,
                appleClient: appleClient,
                llmConfiguration: configuration,
                logSink: logSink
            )
        #endif
        }
    }
}

// MARK: - Apple Intelligence conformer

/// Routes `transform` / `articulate` through the same `LLMClient` the
/// cloud path uses (LLMClient already short-circuits Apple Intelligence
/// internally) — call-site convergence without duplicating prompt
/// composition. `streamChat` reaches the Apple Intelligence client
/// directly because there's no HTTP path on Apple.
struct AppleAIService: AIService {
    let appleClient: any AppleIntelligenceClienting
    let llmConfiguration: LLMConfiguration
    let urlSession: URLSession
    let logSink: any LogSink

    func transform(transcript: String) async throws -> String {
        let client = LLMClient(
            session: urlSession,
            appleClient: appleClient,
            logSink: logSink,
            llmConfiguration: llmConfiguration
        )
        return try await client.transform(transcript: transcript)
    }

    func articulate(selectedText: String, instruction: String) async throws -> String {
        let client = LLMClient(
            session: urlSession,
            appleClient: appleClient,
            logSink: logSink,
            llmConfiguration: llmConfiguration
        )
        return try await client.articulate(selectedText: selectedText, instruction: instruction)
    }

    func streamChat(request: AIChatRequest) -> AsyncThrowingStream<String, Error> {
        appleClient.streamChat(request: request)
    }
}

// MARK: - Cloud conformer

/// Routes `transform` / `articulate` through `LLMClient` (the same
/// per-provider HTTP code path that already shipped); routes
/// `streamChat` through the per-provider `CloudChatStream` (preserving
/// inline tool-calling for OpenAI / Anthropic / Gemini / Ollama /
/// Flavor-1).
struct CloudAIService: AIService {
    let urlSession: URLSession
    let appleClient: any AppleIntelligenceClienting
    let llmConfiguration: LLMConfiguration
    let logSink: any LogSink

    func transform(transcript: String) async throws -> String {
        let client = LLMClient(
            session: urlSession,
            appleClient: appleClient,
            logSink: logSink,
            llmConfiguration: llmConfiguration
        )
        return try await client.transform(transcript: transcript)
    }

    func articulate(selectedText: String, instruction: String) async throws -> String {
        let client = LLMClient(
            session: urlSession,
            appleClient: appleClient,
            logSink: logSink,
            llmConfiguration: llmConfiguration
        )
        return try await client.articulate(selectedText: selectedText, instruction: instruction)
    }

    func streamChat(request: AIChatRequest) -> AsyncThrowingStream<String, Error> {
        // Prefer the request's `providerOverride` snapshot — it pins
        // the per-provider config that was active at Send time, so a
        // user changing Settings → AI mid-stream doesn't reroute the
        // turn. Fall back to a live `LLMConfiguration` read otherwise
        // (callers that don't pin: today none in production; reserved
        // for future call sites).
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                let snapshot: (provider: LLMProvider, apiKey: String, baseURL: String, model: String)
                if let pinned = request.providerOverride {
                    snapshot = (
                        provider: pinned.provider,
                        apiKey: pinned.apiKey,
                        baseURL: pinned.baseURL,
                        model: pinned.model
                    )
                } else {
                    snapshot = await MainActor.run { [llmConfiguration] in
                        let provider = llmConfiguration.provider
                        return (
                            provider: provider,
                            apiKey: llmConfiguration.apiKey(for: provider),
                            baseURL: llmConfiguration.effectiveBaseURL(for: provider),
                            model: llmConfiguration.effectiveModel(for: provider)
                        )
                    }
                }

                guard snapshot.provider != .appleIntelligence else {
                    continuation.finish(throwing: LLMError.appleIntelligenceUnavailable)
                    return
                }

                let cloudMessages: [CloudChatMessage] = request.messages.map { message in
                    switch message.role {
                    case .user:
                        return CloudChatMessage(role: .user, content: message.content)
                    case .assistant:
                        return CloudChatMessage(role: .assistant, content: message.content)
                    }
                }

                let cloud: any CloudChatStream
                switch snapshot.provider {
                case .openai:
                    cloud = OpenAIChatStream(session: urlSession)
                case .anthropic:
                    cloud = AnthropicChatStream(session: urlSession)
                case .gemini:
                    cloud = GeminiChatStream(session: urlSession)
                case .ollama:
                    cloud = OllamaChatStream(session: urlSession)
                #if JOT_FLAVOR_1
                case .flavor1:
                    cloud = Flavor1ChatStream(session: urlSession)
                #endif
                case .appleIntelligence:
                    continuation.finish(throwing: LLMError.appleIntelligenceUnavailable)
                    return
                }

                let inner = cloud.streamChat(
                    messages: cloudMessages,
                    systemInstructions: request.systemInstructions,
                    showFeatureTool: request.showFeatureTool,
                    apiKey: snapshot.apiKey,
                    baseURL: snapshot.baseURL,
                    model: snapshot.model,
                    maxTokens: request.maxTokens
                )

                do {
                    for try await delta in inner {
                        try Task.checkCancellation()
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    // Propagate cancellation through the outer stream
                    // so `HelpChatStore.runUnifiedStream`'s
                    // `catch is CancellationError` branch fires —
                    // otherwise we hit `finalizeStream` instead of
                    // `handleCancelledStream` and lose the `(stopped)`
                    // suffix + idle reset.
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        return stream
    }
}

// MARK: - Test-injectable adapter

/// Thin `AIService` that forwards `transform` / `articulate` to a
/// pre-built `LLMClient`. Production code goes through the dispatcher;
/// this adapter only exists so existing test seams that inject a
/// custom `LLMClient` (e.g. `ArticulateController(llm:)`, regression
/// suite in `Phase4PatchRegressionTests`) keep working without
/// re-plumbing through `LLMConfiguration`. `streamChat` is
/// unimplemented because the affected test seams never call it.
struct DirectLLMClientAIService: AIService {
    let client: LLMClient

    func transform(transcript: String) async throws -> String {
        try await client.transform(transcript: transcript)
    }

    func articulate(selectedText: String, instruction: String) async throws -> String {
        try await client.articulate(selectedText: selectedText, instruction: instruction)
    }

    func streamChat(request: AIChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // The injected-client seam (ArticulateController test
            // surface) doesn't reach `streamChat`. If a future caller
            // does, surface a typed error rather than trapping.
            continuation.finish(throwing: LLMError.appleIntelligenceUnavailable)
        }
    }
}
