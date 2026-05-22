import Foundation

/// Ollama `/api/tags` probe.
///
/// **Endpoint:** `GET <host>/api/tags`. The stored `baseURL` defaults
/// to `http://localhost:11434/v1` (LLMClient uses the OpenAI-compat
/// shim), but `/api/tags` lives at the root, not under `/v1`. We
/// strip a trailing `/v1` (with or without trailing slash) before
/// appending `/api/tags`.
/// **Auth:** none. Ollama is a local daemon.
/// **Response shape:**
///   `{ models: [{ name, model, modified_at, size, digest, details: { format, family, parameter_size, ... } }, ...] }`.
///
/// All locally-pulled models are chat-capable as far as Ollama is
/// concerned (embedding-only models are tagged as such in `details`
/// but still respond to chat completions). No filtering — show
/// everything the user has pulled.
struct OllamaProbe: AIProviderProbe {
    let provider: LLMProvider = .ollama
    let classifier: TierClassifier

    init() {
        // Ollama models follow no consistent version scheme across
        // families (llama3.1:8b, gemma2:27b, qwen2.5-coder:14b,
        // mixtral:8x7b). No latest-gen regex; the default-pick logic
        // returns the first id, and the user picks from the full
        // list. `tierFor` is also nil — without a version scheme,
        // small/medium/large can't be inferred from the id alone.
        self.classifier = TierClassifier(
            provider: .ollama,
            latestGenRegex: nil,
            tierFor: { _ in nil },
            isThinking: { _ in false }
        )
    }

    func probe(
        baseURL: String,
        apiKey _: String,
        session: URLSession
    ) async -> ProbeResult {
        let host = Self.stripOpenAICompatSuffix(from: baseURL)
        guard let url = URL(string: "\(host)/api/tags") else {
            return .unreachable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable
            }
            guard (200...299).contains(http.statusCode) else {
                return .unreachable
            }
            return .success(Self.parse(data: data))
        } catch {
            return .networkError(String(describing: error))
        }
    }

    static func parse(data: Data) -> [DiscoveredModel] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = root["models"] as? [[String: Any]]
        else {
            return []
        }
        return list.compactMap { entry -> DiscoveredModel? in
            guard let name = entry["name"] as? String else { return nil }
            return DiscoveredModel(
                id: name,
                displayName: nil,
                isThinking: false,
                tier: nil
            )
        }
        .sorted { lhs, rhs in lhs.id < rhs.id }
    }

    /// `http://localhost:11434/v1` → `http://localhost:11434`. Leaves
    /// a host without `/v1` untouched so a user pointing Jot at a
    /// custom Ollama proxy that doesn't expose the OpenAI shim still
    /// hits `/api/tags` at the right place.
    static func stripOpenAICompatSuffix(from baseURL: String) -> String {
        var s = baseURL
        while s.hasSuffix("/") {
            s.removeLast()
        }
        if s.hasSuffix("/v1") {
            s.removeLast("/v1".count)
        }
        return s
    }
}
