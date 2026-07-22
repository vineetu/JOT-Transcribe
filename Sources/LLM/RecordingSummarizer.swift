import Foundation

/// **Recording-detail AI summary service.** Owns its LLM dependencies by
/// constructor injection (the graph's own `urlSession` / `appleClient` /
/// `llmConfiguration` / log sink) instead of reaching a lazy `AppServices.live`
/// global — the pattern Phase 3 #29 / Phase 4 round 5 removed from every pane
/// because a fresh-install timing race could make an enabled-looking control
/// fail on click. Constructed and injected at the window root exactly like
/// `HelpChatStore` / `LLMConfiguration`.
///
/// All LLM-call construction lives here; the view calls `start(...)` and, on
/// success, persists the returned text onto its SwiftData model (persistence
/// deliberately stays out of this service). The capable-provider gate is
/// re-checked internally (defense in depth) — a summary is NEVER routed to
/// on-device Apple Intelligence.
@MainActor
final class RecordingSummarizer: ObservableObject {

    /// The produced summary, carried back so the caller can persist it.
    struct Output: Equatable {
        let text: String
        let kind: SummaryKind
    }

    enum Failure: Error, Equatable {
        /// The gate refused (Apple Intelligence / unconfigured) — carries the
        /// user-facing reason.
        case providerNotCapable(String)
        /// The model returned nothing usable.
        case emptyResult
        /// The request failed — carries a user-facing message.
        case requestFailed(String)
    }

    private let urlSession: URLSession
    private let appleClient: any AppleIntelligenceClienting
    private let llmConfiguration: LLMConfiguration
    private let logSink: any LogSink

    /// True while a summary request is in flight (drives the section spinner).
    @Published private(set) var isRunning = false

    private var task: Task<Void, Never>?

    init(
        urlSession: URLSession,
        appleClient: any AppleIntelligenceClienting,
        llmConfiguration: LLMConfiguration,
        logSink: any LogSink = ErrorLog.shared
    ) {
        self.urlSession = urlSession
        self.appleClient = appleClient
        self.llmConfiguration = llmConfiguration
        self.logSink = logSink
    }

    /// Whether summaries can run with the currently-selected provider: a capable
    /// provider (never Apple Intelligence) that's minimally configured. Reads the
    /// injected `llmConfiguration` — the same object Settings writes to.
    var isEnabled: Bool {
        SummaryAvailability.isEnabled(
            provider: llmConfiguration.provider,
            isMinimallyConfigured: llmConfiguration.isMinimallyConfigured)
    }

    /// The reason summaries are disabled (Apple Intelligence / unconfigured), or nil.
    var disabledReason: String? {
        SummaryAvailability.disabledReason(
            provider: llmConfiguration.provider,
            isMinimallyConfigured: llmConfiguration.isMinimallyConfigured)
    }

    /// Cancel any in-flight summary cleanly.
    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// Start a summary for `kind` over `transcriptInput`; delivers the result on
    /// the main actor via `completion`. The caller persists a `.success`. NEVER
    /// auto-runs (only an explicit caller invokes this) and NEVER routes to Apple
    /// Intelligence — the gate is re-checked here.
    func start(
        kind: SummaryKind,
        customInstruction: String?,
        transcriptInput: String,
        completion: @escaping (Result<Output, Failure>) -> Void
    ) {
        guard isEnabled else {
            completion(.failure(.providerNotCapable(
                disabledReason ?? "Summaries need a cloud or local AI provider — Settings → AI.")))
            return
        }
        task?.cancel()
        isRunning = true

        let system = SummaryPrompt.systemPrompt(for: kind, custom: customInstruction)
        let session = urlSession
        let apple = appleClient
        let sink = logSink
        let config = llmConfiguration
        task = Task { @MainActor in
            defer { isRunning = false }
            do {
                let client = LLMClient(
                    session: session, appleClient: apple, logSink: sink, llmConfiguration: config)
                let raw = try await client.complete(systemPrompt: system, userPrompt: transcriptInput)
                if Task.isCancelled { return }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    completion(.failure(.emptyResult))
                    return
                }
                completion(.success(Output(text: trimmed, kind: kind)))
            } catch is CancellationError {
                // Cancelled — no completion; the caller already reset its state.
            } catch {
                completion(.failure(.requestFailed(
                    "Couldn't generate a summary — \(error.localizedDescription)")))
            }
        }
    }
}
