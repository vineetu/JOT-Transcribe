import Foundation
import Observation
import SwiftData

/// Owner of the transcript-Q&A "Ask Jot" conversation state.
///
/// This is the clean RAG surface that replaces the help-bot lane: it answers
/// questions over the user's own dictated TRANSCRIPTS (with `[cite: N]`
/// citations resolved back to recordings) and about the APP itself (from the
/// bundled `help-content.md`, plain prose, no citations), using
/// `TranscriptRetriever` for retrieval and the user's configured provider for
/// generation.
///
/// Deliberately lean compared to `HelpChatStore`:
///   * NO slug correction / injection / sharp-fix forcing / command scrub.
///   * NO `showFeature` tool-calling.
///   * NO migration-banner logic.
/// It keeps only the streaming loop shape (50 ms debounced flush, cooperative
/// cancellation) and the citation-resolution plumbing.
///
/// `@MainActor @Observable` so SwiftUI tracks property reads automatically and
/// every mutation lands on the main actor; the heavy retrieval + streaming
/// hops off-actor and back.
@MainActor
@Observable
final class AskRecordingsStore {
    /// Top-level conversation mode.
    enum State: Equatable {
        case idle
        case streaming
        case error(String)
        /// Cannot answer right now — retrieval not ready. Carries a user-facing
        /// reason string.
        case unavailable(String)
    }

    /// Conversation so far. `AskRecordingsView` renders these as bubbles.
    var messages: [ChatMessage] = []

    /// Drives the input/streaming UI and the unavailable empty state.
    var state: State = .idle

    /// Per-assistant-message citation sources, keyed by message id. Populated
    /// at Send time (in retrieval order) so the parser can resolve `[cite: N]`
    /// markers to recordings as the answer streams in. We keep this parallel
    /// to `messages` rather than extend `ChatMessage`.
    private(set) var sourcesByMessage: [UUID: [AskCitationSource]] = [:]

    /// Parsed renderable segments, keyed by assistant message id. Filled on
    /// stream finalize; the view can also parse on the fly from `content` +
    /// `sourcesByMessage`.
    private(set) var segmentsByMessage: [UUID: [AskAnswerSegment]] = [:]

    /// The currently in-flight stream task. `cancel()` / `newChat()` cancel it.
    private var lastStreamTask: Task<Void, Never>?

    // MARK: - Injected dependencies (mirror HelpChatStore)

    private let urlSession: URLSession
    private let appleClient: any AppleIntelligenceClienting
    private let logSink: any LogSink
    private let llmConfiguration: LLMConfiguration
    private let modelContainer: ModelContainer

    init(
        urlSession: URLSession,
        appleClient: any AppleIntelligenceClienting,
        logSink: any LogSink = ErrorLog.shared,
        llmConfiguration: LLMConfiguration,
        modelContainer: ModelContainer
    ) {
        self.urlSession = urlSession
        self.appleClient = appleClient
        self.logSink = logSink
        self.llmConfiguration = llmConfiguration
        self.modelContainer = modelContainer
    }

    // MARK: - Provider sizing

    /// Retrieval `k` + total user-turn character budget, scaled to the
    /// provider's context headroom. Small on-device models get a tight budget;
    /// local servers more; cloud the most.
    private struct Sizing {
        let k: Int
        let charBudget: Int
        let maxTokens: Int
    }

    private static func sizing(for provider: LLMProvider) -> Sizing {
        switch provider {
        case .appleIntelligence:
            return Sizing(k: 15, charBudget: 12_000, maxTokens: 1200)
        case .lmStudio, .ollama:
            return Sizing(k: 40, charBudget: 30_000, maxTokens: 1200)
        case .openai, .anthropic, .gemini:
            return Sizing(k: 60, charBudget: 40_000, maxTokens: 1200)
        #if JOT_FLAVOR_1
        case .flavor1:
            return Sizing(k: 60, charBudget: 40_000, maxTokens: 1200)
        #endif
        }
    }

    // MARK: - Ask

    /// Submit a question. Appends a user bubble + a streaming assistant bubble,
    /// retrieves transcript chunks, and streams the grounded answer.
    ///
    /// No-op while a turn is already in flight.
    func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Ignore re-entrancy while a turn is in flight (the composer gates Send,
        // but this guards rapid double-submit / Enter races).
        if case .streaming = state { return }
        startAsk(trimmed)
    }

    private func startAsk(_ question: String) {
        let provider = llmConfiguration.provider

        // Uses whatever provider the user configured in Settings — the same one
        // Transform/Rewrite use. Choosing the provider IS the consent; there is
        // no separate Ask-Jot opt-in.
        messages.append(ChatMessage(role: .user, content: question))
        let assistantId = beginStreamingAssistantMessage()

        let sizing = Self.sizing(for: provider)
        let container = modelContainer
        // Deterministic, model-free date scope — drives the hard createdAt
        // window filter below (keeps relative-date math out of the LLM).
        let dateScope = AskDateScope.parseDateScope(from: question, now: Date())

        lastStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Readiness — embedding model downloaded, feature enabled, chunks
            // indexed. Runs off-actor inside `isAvailable`.
            let ready = await TranscriptRetriever.isAvailable(container: container)
            if Task.isCancelled { return }
            guard ready else {
                self.failTurn(
                    assistantId: assistantId,
                    reason: "Search isn't ready yet — turn it on in Settings, wait for the search model to finish downloading, or record a few notes to index first.",
                    unavailable: true
                )
                return
            }

            // Date-scoped queries (deterministic parser → hard createdAt window):
            //   (a) date + topic → semantic rank WITHIN the window (fall back to
            //       chronological if nothing in-window matched the topic);
            //   (b) pure date  → chronological (oldest→newest);
            //   (c) no date    → semantic over the whole library.
            let chunks: [RetrievedChunk]
            if let scope = dateScope {
                if AskDateScope.queryHasTopicBeyondDate(question) {
                    let ranked = await TranscriptRetriever.retrieve(
                        query: question,
                        k: sizing.k,
                        dateInterval: scope.interval,
                        container: container
                    )
                    chunks = ranked.isEmpty
                        ? await TranscriptRetriever.retrieveByDate(interval: scope.interval, k: sizing.k, container: container)
                        : ranked
                } else {
                    chunks = await TranscriptRetriever.retrieveByDate(interval: scope.interval, k: sizing.k, container: container)
                }
            } else {
                chunks = await TranscriptRetriever.retrieve(
                    query: question,
                    k: sizing.k,
                    container: container
                )
            }
            if Task.isCancelled { return }

            // A date query that matches nothing is a clean, informative result —
            // answer locally with NO model call (and don't trip a "be specific").
            if let scope = dateScope, chunks.isEmpty {
                self.completeWithLocalAnswer(
                    assistantId: assistantId,
                    text: "You don't have any notes from \(scope.label)."
                )
                return
            }

            // Resolve each chunk → (citation source, prompt snippet) in
            // retrieval order, with a 1-based citation index.
            let (sources, snippets) = self.buildSourcesAndSnippets(from: chunks)
            self.sourcesByMessage[assistantId] = sources

            let systemInstructions = AskPrompts.unifiedSystemPrompt(helpDoc: Self.helpContent)
            let userTurn = AskPrompts.buildUserTurn(
                question: question,
                snippets: snippets,
                charBudget: sizing.charBudget
            )

            let request = AIChatRequest(
                messages: [AIChatMessage(role: .user, content: userTurn)],
                systemInstructions: systemInstructions,
                maxTokens: sizing.maxTokens,
                showFeatureTool: nil,
                session: nil,
                providerOverride: nil
            )

            let service = AIServices.serviceForRequest(
                request: request,
                urlSession: self.urlSession,
                appleClient: self.appleClient,
                logSink: self.logSink,
                llmConfiguration: self.llmConfiguration
            )

            let stream = service.streamChat(request: request)
            await self.runStream(stream, assistantId: assistantId, sources: sources, provider: provider)
        }
    }

    // MARK: - Streaming loop (mirrors HelpChatStore, sans post-processing)

    private static let streamingFlushIntervalNs: UInt64 = 50_000_000

    private func runStream(
        _ stream: AsyncThrowingStream<String, Error>,
        assistantId: UUID,
        sources: [AskCitationSource],
        provider: LLMProvider
    ) async {
        var accumulated = ""
        var pendingFlush: Task<Void, Never>?

        do {
            for try await delta in stream {
                if Task.isCancelled { break }
                // Apple conformer's rewrite sentinel: an empty yield means the
                // model replaced its partial — reset the accumulator.
                if delta.isEmpty {
                    accumulated = ""
                    continue
                }
                accumulated += delta
                schedulePendingFlush(
                    assistantId: assistantId,
                    accumulatedText: { accumulated },
                    pendingFlush: &pendingFlush
                )
            }

            try Task.checkCancellation()
            pendingFlush?.cancel()
            finalizeStream(assistantId: assistantId, accumulated: accumulated, sources: sources)
        } catch is CancellationError {
            pendingFlush?.cancel()
            handleCancelledStream(assistantId: assistantId, accumulated: accumulated)
        } catch {
            pendingFlush?.cancel()
            handleStreamError(error, provider: provider, assistantId: assistantId, accumulated: accumulated)
        }
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
            self.flushStreamingContent(assistantId: assistantId, accumulated: accumulatedText())
        }
    }

    private func flushStreamingContent(assistantId: UUID, accumulated: String) {
        guard let idx = messages.firstIndex(where: { $0.id == assistantId }) else { return }
        messages[idx].content = accumulated
    }

    private func finalizeStream(assistantId: UUID, accumulated: String, sources: [AskCitationSource]) {
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[idx].isStreaming = false
            messages[idx].content = accumulated
        }
        segmentsByMessage[assistantId] = AskCitationParser.finalize(cumulative: accumulated, sources: sources)
        state = .idle
    }

    /// Finish a turn with a locally-produced answer (no model call) — e.g. an
    /// empty date window ("You don't have any notes from last week."). Sets the
    /// assistant bubble's text and ends the turn cleanly.
    private func completeWithLocalAnswer(assistantId: UUID, text: String) {
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[idx].isStreaming = false
            messages[idx].content = text
        }
        segmentsByMessage[assistantId] = [.text(text)]
        state = .idle
    }

    private func handleCancelledStream(assistantId: UUID, accumulated: String) {
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[idx].isStreaming = false
            messages[idx].content = accumulated
            if !messages[idx].content.isEmpty {
                messages[idx].content += "\n\n_(stopped)_"
            }
        }
        state = .idle
    }

    private func handleStreamError(
        _ error: Error,
        provider: LLMProvider,
        assistantId: UUID,
        accumulated: String
    ) {
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[idx].isStreaming = false
            if accumulated.isEmpty {
                messages[idx].content = "Something went wrong. Try again."
            }
        }
        state = .error(error.localizedDescription)
    }

    // MARK: - Turn helpers

    private func beginStreamingAssistantMessage() -> UUID {
        let assistantId = UUID()
        messages.append(ChatMessage(id: assistantId, role: .assistant, content: "", isStreaming: true))
        state = .streaming
        return assistantId
    }

    /// Mark a turn failed before any token streamed: clears the placeholder
    /// assistant bubble and surfaces the reason as `state`.
    private func failTurn(assistantId: UUID, reason: String, unavailable: Bool) {
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            messages.remove(at: idx)
        }
        sourcesByMessage[assistantId] = nil
        state = unavailable ? .unavailable(reason) : .error(reason)
    }

    /// Project retrieved chunks into citation sources + prompt snippets, in
    /// retrieval order with a shared 1-based index. The chip label and the
    /// snippet header both use a short "MMM d" date drawn from the chunk's
    /// `createdAt`.
    private func buildSourcesAndSnippets(
        from chunks: [RetrievedChunk]
    ) -> (sources: [AskCitationSource], snippets: [AskPrompts.Snippet]) {
        var sources: [AskCitationSource] = []
        var snippets: [AskPrompts.Snippet] = []
        for (offset, chunk) in chunks.enumerated() {
            let index = offset + 1
            let label = Self.chipDateFormatter.string(from: chunk.createdAt)
            sources.append(AskCitationSource(recordingID: chunk.recordingID, label: label))
            snippets.append(AskPrompts.Snippet(index: index, date: label, text: chunk.text))
        }
        return (sources, snippets)
    }

    private static let chipDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    // MARK: - Cancel / new chat

    /// Esc handler — cancel an in-flight stream, preserving the partial.
    func cancel() {
        lastStreamTask?.cancel()
        lastStreamTask = nil
    }

    /// Reset the conversation. Cancels any in-flight stream.
    func newChat() {
        lastStreamTask?.cancel()
        lastStreamTask = nil
        messages.removeAll()
        sourcesByMessage.removeAll()
        segmentsByMessage.removeAll()
        state = .idle
    }

    // MARK: - Grounding content

    /// Bundled help doc, loaded lazily once. Mirrors `HelpChatStore.helpContent`
    /// (Bundle "help-content".md, small fallback) so app/feature questions are
    /// grounded on the real product documentation.
    static let helpContent: String = {
        if let url = Bundle.main.url(forResource: "help-content", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return fallbackHelpContent
    }()

    private static let fallbackHelpContent = """
    # Jot

    On-device Mac dictation. Press a hotkey, speak, and the transcript is
    pasted at the cursor. Transcription runs entirely on-device; audio never
    leaves the Mac. Optional LLM Cleanup and Rewrite can use Apple
    Intelligence (on-device), a local model, or a configured cloud provider.
    """
}
